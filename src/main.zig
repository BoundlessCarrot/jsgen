const std = @import("std");
const koino = @import("koino");
const zds = @import("zds.zig");

const Parser = koino.parser.Parser;
const Options = koino.Options;
const nodes = koino.nodes;
const html = koino.html;
const serve = zds.zds;
const ew = std.mem.endsWith;
const eql = std.mem.eql;
const ext = std.fs.path.extension;
// const basename = std.fs.path.basename;

const Settings = struct {
    allocator: std.mem.Allocator,
    templatePath: []const u8 = undefined,
    templateBuffer: std.ArrayList(u8),
    excludePaths: std.ArrayList([]const u8),
    insertMarker: ?usize = null,
    siteDirPath: []const u8 = undefined,
    mastersDirPath: []const u8 = undefined,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) Settings {
        return .{ .allocator = allocator, .templateBuffer = std.ArrayList(u8).init(allocator), .excludePaths = std.ArrayList([]const u8).init(allocator) };
    }

    fn deinit(self: Self) void {
        self.templateBuffer.deinit();
        self.excludePaths.deinit();
    }

    fn openAndLoadTemplate(self: *Self) !void {
        const templateFile = std.fs.cwd().openFile(self.templatePath, .{}) catch |err| {
            std.log.err("Failed to open template file: {s}", .{@errorName(err)});
            return;
        };
        defer templateFile.close();

        const stat = try templateFile.stat();

        // Create a separate variable to hold the allocated buffer
        const template_contents = try templateFile.readToEndAlloc(self.allocator, stat.size);
        defer self.allocator.free(template_contents); // Free the memory when we're done

        // Now write the contents to the template buffer
        try self.templateBuffer.writer().writeAll(template_contents);

        // find the file position in the template
        self.insertMarker = std.mem.indexOf(u8, self.templateBuffer.items, "<main>").? + "<main>".len;
    }
};

fn openAndConvertToHtml(settings: Settings, mdFilename: []const u8, output: *[]const u8) !void {
    const mdFile = std.fs.cwd().openFile(mdFilename, .{}) catch |err| {
        std.log.err("Failed to open file: {s}", .{@errorName(err)});
        return;
    };
    defer mdFile.close();

    const stat = try mdFile.stat();

    // var bw = std.io.bufferedReader(mdFile.reader());
    // const fileReader = bw.reader();

    // This might actually be worst practice
    const markdown = mdFile.readToEndAlloc(settings.allocator, stat.size) catch |err| {
        std.log.err("Failed to read file: {s}", .{@errorName(err)});
        return;
    };
    defer settings.allocator.free(markdown);

    const options: Options = .{};
    var parser = try Parser.init(settings.allocator, options);
    try parser.feed(markdown);

    const doc = try parser.finish();
    defer doc.deinit();

    output.* = blk: {
        var outBuf = std.ArrayList(u8).init(settings.allocator);
        errdefer outBuf.deinit();
        try html.print(outBuf.writer(), settings.allocator, options, doc);
        break :blk try outBuf.toOwnedSlice();
    };
    std.log.info("File {s} converted (Markdown --> HTML)", .{mdFilename});
}

fn writeHtmlToFile(htmlBuffer: []const u8, filename: []const u8) !void {
    const htmlFile = std.fs.cwd().createFile(filename, .{}) catch |err| {
        std.log.err("Failed to open/create file: {s}", .{@errorName(err)});
        return;
    };
    defer htmlFile.close();

    var bw = std.io.bufferedWriter(htmlFile.writer());
    const fw = bw.writer();

    fw.writeAll(htmlBuffer) catch |err| {
        std.log.err("Failed to write to file: {s}", .{@errorName(err)});
        return;
    };
    std.log.info("File {s} written", .{filename});
    try bw.flush();
}

fn insertContent(settings: Settings, content: []const u8) ![]const u8 {
    if (settings.insertMarker == null) {
        return error.NoContentMarkerFound;
    }

    // Create a new buffer for the complete page
    // var result = try std.ArrayList(u8).initCapacity(settings.allocator, settings.templateBuffer.items.len + content.len);
    var result = try settings.templateBuffer.clone();
    errdefer result.deinit();

    try result.insertSlice(settings.insertMarker.?, content);

    return result.toOwnedSlice();
}

fn isExcludedFile(settings: Settings, filename: []const u8) bool {
    for (settings.excludePaths.items) |path| {
        if (eql(u8, path, filename)) {
            return true;
        }
    }
    return false;
    // return std.mem.containsAtLeast([]u8, settings.excludePaths.items, 1, filename);
}

fn processFileTree(dir: std.fs.Dir, settings: Settings) !void {
    var fileCount: usize = 0;
    var skipCount: usize = 0;
    var walker = try dir.walk(settings.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                // Make sure filename ends in `.md` and isn't on the exclude list
                if (!ew(u8, ext(entry.path), ".md") or isExcludedFile(settings, entry.basename)) {
                    std.log.info("{s} skipped", .{entry.basename});
                    skipCount += 1;
                    continue;
                }

                // Get path to save file
                // It's important to note that this isn't just the full path
                // We have the path to the root directory in settings.rootDirName
                // we want the path within this sub directory as that mirrors the path we want to save the file in
                // e.g. the file `source/masters/posts/post1.md` should be saved at `rootdir/posts/post1.html`
                // Get root directory path
                const pathToRoot = try std.fs.path.relative(settings.allocator, settings.mastersDirPath, entry.path);
                defer settings.allocator.free(pathToRoot);

                // Get html filename and combine with path
                const htmlFilename = try std.fmt.allocPrint(settings.allocator, "{s}{s}.html", .{ settings.siteDirPath, std.fs.path.stem(entry.basename) });
                defer settings.allocator.free(htmlFilename);
                std.debug.print("{s}\n", .{htmlFilename});

                var htmlBuffer: []const u8 = undefined;
                defer settings.allocator.free(htmlBuffer);

                try openAndConvertToHtml(settings, entry.basename, &htmlBuffer);

                var finishedFile: []const u8 = undefined;
                defer settings.allocator.free(finishedFile);

                finishedFile = try insertContent(settings, htmlBuffer);

                try writeHtmlToFile(finishedFile, htmlFilename);

                fileCount += 1;
            },
            // .directory => {
            //     var lowerDir = std.fs.cwd().openDir(entry.basename, .{ .iterate = true }) catch |err| {
            //         std.log.err("There was an issue opening the {s} directory: {s}", .{ entry.basename, @errorName(err) });
            //         continue;
            //     };
            //     var lowerIter = lowerDir.iterate();
            //
            //     try processFileTree(lowerIter, settings);
            // },
            else => {},
        }
    }
    std.log.info("Converted {d} file(s) to html, skipped {d} file(s)", .{ fileCount, skipCount });
}

pub fn main() !void {
    // Init allocator
    // TODO: Figure out which allocator is best for this task (opening documents)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    // Init settings struct
    var settings: Settings = Settings.init(gpa.allocator());
    defer settings.deinit();

    settings.templatePath = "template.html";
    settings.siteDirPath = "../../";
    settings.mastersDirPath = ".";
    try settings.excludePaths.append(settings.templatePath);
    try settings.excludePaths.append("README.md");

    // Open and save the template to a buffer in the settings struct
    try settings.openAndLoadTemplate();

    var inputRoot = std.fs.cwd().openDir(settings.mastersDirPath, .{ .iterate = true }) catch |err| {
        std.log.err("There was an issue opening the root directory: {s}", .{@errorName(err)});
        return;
    };
    defer inputRoot.close();

    try processFileTree(inputRoot, settings);

    // Serve the website locally to observe changes.
    try serve("127.0.0.1", 8080, 6);
}
