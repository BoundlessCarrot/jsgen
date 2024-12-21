const std = @import("std");

// const ew = std.mem.endsWith;
//
// fn treeloop(alloc: std.mem.Allocator, dir: std.fs.Dir, relative_path: []const u8) !void {
//     var dirIter = dir.iterate();
//     while (try dirIter.next()) |entry| {
//         const full_path = try std.fs.path.join(alloc, &.{ relative_path, entry.name });
//         defer alloc.free(full_path);
//         std.debug.print("{s}\n", .{full_path});
//
//         switch (entry.kind) {
//             .directory => {
//                 var dirItem = dir.openDir(entry.name, .{ .iterate = true }) catch |err| {
//                     std.log.err("There was an issue opening the {s} directory: {s}", .{ entry.name, @errorName(err) });
//                     return;
//                 };
//                 defer dirItem.close();
//
//                 try treeloop(alloc, dirItem, full_path);
//             },
//             else => {},
//         }
//     }
// }

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    // var dirItem = std.fs.cwd().openDir(".", .{ .iterate = true }) catch |err| {
    //     std.log.err("There was an issue opening the root directory: {s}", .{@errorName(err)});
    //     return;
    // };
    // defer dirItem.close();
    var cwd = std.fs.cwd().openDir(".", .{ .iterate = true }) catch |err| {
        std.log.err("There was an issue opening the root directory: {s}", .{@errorName(err)});
        return;
    };
    defer cwd.close();

    // try treeloop(gpa.allocator(), cwd, ".");
    var walker = try cwd.walk(gpa.allocator());
    while (try walker.next()) |entry| {
        std.debug.print("{s}\n", .{entry.path});
    }
}
