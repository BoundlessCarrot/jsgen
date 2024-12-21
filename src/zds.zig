const std = @import("std");
const builtin = @import("builtin");

const Atomic = std.atomic.Value;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const net = std.net;
const os = std.os;
const posix = std.posix;
const Thread = std.Thread;

var running = Atomic(bool).init(true);
var server_addr: net.Address = undefined;
var workers: u8 = undefined;

/// Runs a "just-enough-functionality" web server for
/// auto-generated Zig documentation. It will serve files
/// from the current working directory, so be sure to run it
/// from the generated docs directory.
pub fn zds(
    server_ip: []const u8,
    server_port: u16,
    comptime threads: u8,
) !void {
    workers = threads;

    // Handle OS signals
    try addSignalHandlers();

    // Setup thread pool
    var handles: [threads]Thread = undefined;
    defer for (&handles) |*h| h.join();
    for (0..threads) |i| handles[i] = try Thread.spawn(.{}, logError, .{ server_ip, server_port });

    const stdout = io.getStdOut().writer();
    try stdout.print("zds ready at http://{s}:{}. CTRL+C to shutdown.\n", .{ server_ip, server_port });
}

fn logError(server_ip: []const u8, server_port: u16) void {
    serve(server_ip, server_port) catch |err| {
        std.log.err("error handling client request: {s}", .{@errorName(err)});
        if (err == error.KernelTooOld) running.store(false, .release);
    };
}

fn serve(server_ip: []const u8, server_port: u16) !void {
    // Start listening.
    server_addr = try net.Address.parseIp(server_ip, server_port);
    const listener_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const listener = try posix.socket(server_addr.any.family, listener_flags, 0);
    defer posix.close(listener);

    if (builtin.os.tag == .windows) {
        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    } else {
        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &mem.toBytes(@as(c_int, 1)));
    }

    try posix.bind(listener, &server_addr.any, server_addr.getOsSockLen());
    try posix.listen(listener, 1);

    var buf: [1024]u8 = undefined;

    while (running.load(.monotonic)) {
        const client_socket = try posix.accept(listener, null, null, 0);
        defer posix.close(client_socket);
        const received = try posix.recv(client_socket, &buf, 0);
        if (received == 0) continue;
        try posix.shutdown(client_socket, .recv);
        try sendFile(client_socket, try getPath(buf[0..received]));
    }
}

fn getPath(bytes: []const u8) ![]const u8 {
    var space_iter = mem.splitScalar(u8, bytes, ' ');
    _ = space_iter.next() orelse return error.InvalidUri; // skip method
    return space_iter.next() orelse return error.InvalidUri;
}

fn sendFile(socket: posix.socket_t, path: []const u8) !void {
    var file: fs.File = undefined;
    var mime: []const u8 = undefined;
    var buf: [4096]u8 = undefined;

    const headers_tpl =
        \\HTTP/1.1 200 Ok
        \\Content-Type: {s}
        \\
        \\
    ;

    // Add debug logging
    std.debug.print("Requested path: '{s}'\n", .{path});

    if (mem.eql(u8, path, "/index.html")) {
        file = try fs.cwd().openFile("index.html", .{});
        mime = "text/html; charset=utf-8";
    } else if (mem.eql(u8, path, "/main.js")) {
        file = try fs.cwd().openFile("main.js", .{});
        mime = "application/javascript";
    } else if (mem.eql(u8, path, "/main.wasm")) {
        file = try fs.cwd().openFile("main.wasm", .{});
        mime = "application/wasm";
    } else if (mem.eql(u8, path, "/sources.tar")) {
        file = try fs.cwd().openFile("sources.tar", .{});
        mime = "application/x-tar";
    } else if (mem.eql(u8, path, "/")) {
        // Generate a simple directory listing
        mime = "text/html; charset=utf-8";

        // Send headers first
        const headers = try fmt.bufPrint(&buf, headers_tpl, .{mime});
        _ = try posix.send(socket, headers, 0);

        // Send directory listing directly
        var dir = try fs.cwd().openDir(".", .{ .iterate = true });
        defer dir.close();

        // Send HTML header
        const html_start =
            \\<html>
            \\<head><title>Directory listing</title></head>
            \\<body>
            \\<h1>Directory listing</h1>
            \\<ul>
            \\
        ;
        _ = try posix.send(socket, html_start, 0);

        // List directory entries
        var it = dir.iterate();
        while (try it.next()) |entry| {
            const line = try fmt.bufPrint(&buf, "<li><a href=\"/{s}\">{s}</a></li>\n", .{ entry.name, entry.name });
            _ = try posix.send(socket, line, 0);
        }

        // Send HTML footer
        const html_end =
            \\</ul>
            \\</body>
            \\</html>
            \\
        ;
        _ = try posix.send(socket, html_end, 0);

        try posix.shutdown(socket, .send);
        return;
    } else {
        file = try fs.cwd().openFile(mem.trimLeft(u8, path, "/"), .{});
        mime = "text/html; charset=utf-8";
    }

    defer file.close();

    // const stat = try file.stat();

    const headers = try fmt.bufPrint(&buf, headers_tpl, .{mime});
    _ = try posix.send(socket, headers, 0);

    while (true) {
        const n = try file.readAll(&buf);
        if (n == 0) break;
        _ = try posix.send(socket, buf[0..n], 0);
        if (n < buf.len) break;
    }

    try posix.shutdown(socket, .send);
}

fn addSignalHandlers() !void {
    {
        // Ignore broken pipes
        var act = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        try posix.sigaction(posix.SIG.PIPE, &act, null);
    }

    {
        // Catch SIGINT/SIGTERM for proper shutdown
        var act = posix.Sigaction{
            .handler = .{
                .handler = struct {
                    fn wrapper(sig: c_int) callconv(.C) void {
                        const stdout = io.getStdOut().writer();
                        stdout.print("Caught signal {d}; Shutting down...\n", .{sig}) catch unreachable;
                        running.store(false, .release);

                        for (0..workers) |_| {
                            const addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
                            const socket_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
                            const socket = posix.socket(addr.any.family, socket_flags, 0) catch unreachable;
                            defer posix.close(socket);
                            _ = posix.connect(socket, &server_addr.any, server_addr.getOsSockLen()) catch unreachable;
                        }
                    }
                }.wrapper,
            },
            .mask = posix.empty_sigset,
            .flags = 0,
        };

        try posix.sigaction(posix.SIG.TERM, &act, null);
        try posix.sigaction(posix.SIG.INT, &act, null);
    }
}
