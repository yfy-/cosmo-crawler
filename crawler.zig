const std = @import("std");
const HTMLStripper = @import("html_strip.zig").HTMLStripper;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() == .leak) @panic("mem leak");
    }

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();
    const fname = args.next().?;

    const hfile = try std.fs.cwd().openFile(fname, .{});
    defer hfile.close();

    const html_text = try hfile.readToEndAlloc(allocator, 5 * 1024 * 1024);
    defer allocator.free(html_text);

    var stripper = HTMLStripper.init(allocator);
    defer stripper.deinit();

    const html_cont = try stripper.strip(html_text);
    defer allocator.free(html_cont);
    // for (stripper.links.items) |link| {
    //     std.debug.print("Link: {s}\n", .{link});
    // }

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(html_cont);
}
