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
    const url = args.next().?;

    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    var html_text = std.ArrayList(u8).init(allocator);
    defer html_text.deinit();

    const header: std.http.Header = .{
        .name = "User-Agent",
        .value = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) " ++
            "Gecko/20100101 Firefox/113.0",
    };
    const resp = try http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .max_append_size = 5 * 1024 * 1024,
        .response_storage = .{ .dynamic = &html_text },
        .extra_headers = (&header)[0..1],
    });

    if (resp.status != std.http.Status.ok) {
        std.log.err("HTTP Request failed with {}", .{resp.status});
    }

    var stripper = HTMLStripper.init(allocator);
    defer stripper.deinit();

    const html_cont = try stripper.strip(html_text.items);
    defer allocator.free(html_cont);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(html_cont);
}
