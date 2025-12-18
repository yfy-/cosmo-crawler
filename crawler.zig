const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const curl = @import("curl");

const ds = @import("ds.zig");
const Channel = ds.Channel;
const PageInfo = @import("PageInfo.zig");
const HTMLStripper = @import("html_strip.zig").HTMLStripper;

const http_header = [_][:0]const u8{
    "User-Agent: Mozilla/5.0 (compatible; Googlebot/2.1; " ++
        "+http://www.google.com/bot.html)",
};

const Page = struct {
    const Self = @This();

    url: [:0]const u8,
    depth: usize,
    allocator: Allocator,
    html: ?[]const u8 = null,
    content: ?[]const u8 = null,

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.url);
        if (self.html) |html| {
            self.allocator.free(html);
        }

        if (self.content) |content| {
            self.allocator.free(content);
        }
    }
};

const PageChannel = Channel(*Page, true);

fn printer(print_channel: *PageChannel, allocator: Allocator) !void {
    var stdout_buffer: [1024 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (true) {
        const page_msg = print_channel.receive(null);
        if (page_msg == .eos) {
            try stdout.flush();
            break;
        }

        const page_ctx = page_msg.message;
        defer {
            page_ctx.deinit();
            allocator.destroy(page_ctx);
        }
        if (page_ctx.content) |content| {
            stdout.print(
                "url={s}\n{s}\n",
                .{ page_ctx.url, content },
            ) catch |err| {
                std.log.err("PRINTER: err={}", .{err});
            };
        } else {
            std.log.err(
                "PRINTER: Page empty content, url={s}",
                .{page_ctx.url},
            );
        }
    }
}

fn parser(
    url_channel: *PageChannel,
    parse_channel: *PageChannel,
    print_channel: *PageChannel,
    max_depth: usize,
    allocator: Allocator,
) !void {
    var stripper = HTMLStripper.init(allocator);
    defer stripper.deinit();
    try url_channel.subscribe_as_sender();
    try print_channel.subscribe_as_sender();
    while (true) {
        const page_msg = parse_channel.receive(null);
        if (page_msg == .eos) {
            try url_channel.close();
            try print_channel.close();
            break;
        }

        var page_ctx = page_msg.message;
        if (page_ctx.html == null) {
            defer {
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err("PARSER: Received null html for url={s}", .{page_ctx.url});
            continue;
        }

        page_ctx.content = stripper.strip(page_ctx.html.?) catch |err| {
            defer {
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "PARSER: Parse err={}, url={s}",
                .{ err, page_ctx.url },
            );
            continue;
        };

        // Copy the url before sending it to print. As printer will
        // deallocate the pagectx it is not guaranteed we can get a
        // copy afterwards.
        var cp_url = std.ArrayList(u8).initBuffer(allocator.dupe(u8, page_ctx.url) catch |err| {
            std.log.err(
                "PARSER: Could not allocate url array, err={}, url={s}",
                .{ err, page_ctx.url },
            );
            continue;
        });
        defer cp_url.deinit(allocator);

        print_channel.send(&page_ctx) catch |err| {
            defer {
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err("PARSER: Could not send content, err={}", .{err});
        };

        const curr_depth = page_ctx.depth;
        if (curr_depth == max_depth) {
            continue;
        }

        const links = stripper.links.toOwnedSlice(allocator) catch |err| {
            std.log.err("PARSER: Could not own links, err={}", .{err});
            continue;
        };
        defer {
            for (links) |link| {
                allocator.free(link);
            }
            allocator.free(links);
        }

        for (links) |link| {
            if (link.len == 0 or link[0] == '#') continue;
            var new_link = std.ArrayList(u8){};
            defer new_link.deinit(allocator);

            // Relative link.
            if (link[0] == '/') {
                new_link.appendSlice(allocator, cp_url.items) catch |err| {
                    std.log.err(
                        "PARSER: Could not append to new link, err={}, url={s}",
                        .{ err, cp_url.items },
                    );
                    continue;
                };
            }

            new_link.appendSlice(allocator, link) catch |err| {
                std.log.err(
                    "PARSER: Could not append to new link, err={}, url={s}",
                    .{ err, cp_url.items },
                );
                continue;
            };

            const new_page_ctx = allocator.create(Page) catch |err| {
                std.log.err(
                    "PARSER: Could not create page ctx, err={}, url={s}, " ++
                        "link={s}",
                    .{ err, cp_url.items, new_link.items },
                );
                continue;
            };

            const link_msg = new_link.toOwnedSliceSentinel(allocator, 0) catch |err| {
                std.log.err(
                    "PARSER: Could own link msg, err={}, url={s}, link={s}",
                    .{ err, cp_url.items, new_link.items },
                );
                continue;
            };

            new_page_ctx.* = .{
                .url = link_msg,
                .depth = curr_depth + 1,
                .allocator = allocator,
            };

            url_channel.send(&new_page_ctx) catch |err| {
                defer {
                    new_page_ctx.deinit();
                    allocator.destroy(new_page_ctx);
                }
                std.log.err(
                    "PARSER: Could not send page ctx err={}, url={s}, link={s}",
                    .{ err, cp_url.items, new_link.items },
                );
            };
        }
    }
}

fn requestor(
    req_channel: *PageChannel,
    parse_channel: *PageChannel,
    allocator: Allocator,
) !void {
    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();

    const curl_easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer curl_easy.deinit();

    try parse_channel.subscribe_as_sender();
    while (true) {
        const page_msg = req_channel.receive(5_000_000_000);
        if (page_msg == .eos) {
            // Just fail if we cannot close.
            try parse_channel.close();
            break;
        }

        const page_ctx = page_msg.message;
        const txt_buffer = allocator.alloc(u8, 16 * 1024 * 1024) catch |err| {
            defer {
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: Allocation failed for, url={s}, err={}",
                .{ page_ctx.url, err },
            );
            continue;
        };
        var writer = std.Io.Writer.fixed(txt_buffer);

        std.log.info("REQUESTOR: Requesting url={s}...", .{page_ctx.url});
        const resp = curl_easy.fetch(
            page_ctx.url,
            .{ .headers = &http_header, .writer = &writer },
        ) catch |err| {
            defer {
                allocator.free(txt_buffer);
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: HTTP fetch failed, url={s}, err={}",
                .{ page_ctx.url, err },
            );
            continue;
        };

        if (@as(std.http.Status, @enumFromInt(resp.status_code)) != std.http.Status.ok) {
            defer {
                allocator.free(txt_buffer);
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: HTTP response not ok, url={s}, status={}",
                .{ page_ctx.url, resp.status_code },
            );
            continue;
        }

        page_ctx.html = txt_buffer;
        parse_channel.send(&page_ctx) catch |err| {
            defer {
                allocator.free(txt_buffer);
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: Could not send html, url={s}, err={}",
                .{ page_ctx.url, err },
            );
        };
    }
}

const Dummy = struct { x: i32, y: f64, z: []const u8 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() == .leak) @panic("mem leak");
    }

    const buf = try PageInfo.serialize(Dummy, allocator, &Dummy{ .x = 5, .y = 3.0, .z = "erman" });
    defer allocator.free(buf);

    std.debug.print("Buf : {s}\n", .{buf});
    // var args = try std.process.argsWithAllocator(allocator);
    // defer args.deinit();

    // _ = args.skip();
    // const url_arg = args.next().?;
    // const seed_url = try allocator.allocSentinel(u8, url_arg.len, 0);
    // std.mem.copyForwards(u8, seed_url, url_arg);

    // var req_chnl = PageChannel.init(allocator);
    // defer req_chnl.deinit();

    // var seed_page_ctx = allocator.create(Page) catch |err| {
    //     allocator.free(seed_url);
    //     return err;
    // };
    // seed_page_ctx.* = .{ .url = seed_url, .depth = 0, .allocator = allocator };

    // // Seed cannot be send.
    // req_chnl.send(&seed_page_ctx) catch |err| {
    //     seed_page_ctx.deinit();
    //     allocator.destroy(seed_page_ctx);
    //     return err;
    // };

    // var parse_chnl = PageChannel.init(allocator);
    // defer parse_chnl.deinit();

    // var print_chnl = PageChannel.init(allocator);
    // defer print_chnl.deinit();

    // var req_thread = try std.Thread.spawn(
    //     .{},
    //     requestor,
    //     .{ &req_chnl, &parse_chnl, allocator },
    // );
    // defer req_thread.join();

    // // var req2_thread = try std.Thread.spawn(
    // //     .{},
    // //     requestor,
    // //     .{ &req_chnl, &parse_chnl, allocator },
    // // );
    // // defer req2_thread.join();

    // var parse_thread = try std.Thread.spawn(.{}, parser, .{
    //     &req_chnl,
    //     &parse_chnl,
    //     &print_chnl,
    //     2,
    //     allocator,
    // });
    // defer parse_thread.join();

    // var print_thread = try std.Thread.spawn(.{}, printer, .{
    //     &print_chnl,
    //     allocator,
    // });
    // defer print_thread.join();
}
