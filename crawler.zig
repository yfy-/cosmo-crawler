const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const curl = @import("curl");

const ds = @import("ds.zig");
const Channel = ds.Channel;
const PageStorage = @import("PageStorage.zig");
const HTMLStripper = @import("html_strip.zig").HTMLStripper;
const default_crawl_period_min: i32 = 40320;

const http_header = [_][:0]const u8{
    "User-Agent: Mozilla/5.0 (compatible; Googlebot/2.1; " ++
        "+http://www.google.com/bot.html)",
};

const PageContext = struct {
    const Self = @This();
    depth: usize,
    page: *PageStorage.Page,
    html: ?[]const u8 = null,

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.page.deinit(allocator);
        allocator.destroy(self.page);
        if (self.html) |html| {
            allocator.free(html);
        }
    }
};

const PageChannel = Channel(*PageContext, true);

fn parser(
    url_channel: *PageChannel,
    parse_channel: *PageChannel,
    max_depth: usize,
    allocator: Allocator,
    page_db: *const PageStorage,
) !void {
    var stripper = HTMLStripper.init(allocator);
    defer stripper.deinit();
    try url_channel.subscribe_as_sender();
    while (true) {
        const page_msg = parse_channel.receive(null);
        if (page_msg == .eos) {
            try url_channel.close();
            break;
        }

        var page_ctx = page_msg.message;
        defer {
            page_ctx.deinit(allocator);
            allocator.destroy(page_ctx);
        }

        if (page_ctx.html == null) {
            std.log.err(
                "PARSER: Received null html for url={s}",
                .{page_ctx.page.url},
            );
            continue;
        }

        page_ctx.page.content = stripper.strip(page_ctx.html.?) catch |err| {
            std.log.err(
                "PARSER: Parse err={}, url={s}",
                .{ err, page_ctx.page.url },
            );
            continue;
        };

        _ = page_db.create_page(allocator, page_ctx.page) catch |err| {
            std.log.err(
                "PARSER: Could not save to db err={}, url={s}",
                .{ err, page_ctx.page.url },
            );
            continue;
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
                new_link.appendSlice(
                    allocator,
                    page_ctx.page.url,
                ) catch |err| {
                    std.log.err(
                        "PARSER: Could not append to new link, err={}, url={s}",
                        .{ err, page_ctx.page.url },
                    );
                    continue;
                };
            }

            new_link.appendSlice(allocator, link) catch |err| {
                std.log.err(
                    "PARSER: Could not append to new link, err={}, url={s}",
                    .{ err, page_ctx.page.url },
                );
                continue;
            };

            const link_msg = new_link.toOwnedSliceSentinel(
                allocator,
                0,
            ) catch |err| {
                std.log.err(
                    "PARSER: Could not own link msg, err={}, url={s}",
                    .{ err, new_link.items },
                );
                continue;
            };

            const new_page = try page_db.read_page_by_url(
                allocator,
                link_msg,
            ) catch |err| {
                defer allocator.free(link_msg);
                std.log.err(
                    "PARSER: Could not read db, err={}, url={s}",
                    .{ err, link_msg },
                );
                continue;
            };

            if (new_page) |np| {
                const next_crawl_time = np.last_crawled + np.crawl_period_min * 60;
                if (next_crawl_time >= std.time.timestamp()) {
                    defer allocator.free(link_msg);
                    continue;
                }
            }

            const new_page_hp = allocator.create(PageStorage.Page) catch |err| {
                defer allocator.free(link_msg);
                std.log.err(
                    "PARSER: Could not create page, err={}, url={s}.",
                    .{ err, link_msg },
                );
                continue;
            };

            new_page_hp.* = if (new_page) |np| np else .{
                .last_crawled_sec = 0,
                .etag_fp = 0,
                .crawl_period_min = default_crawl_period_min,
                .url = link_msg,
                .content = &{},
            };

            const new_page_ctx = allocator.create(PageContext) catch |err| {
                defer {
                    new_page_hp.deinit();
                    allocator.destroy(new_page_hp);
                }
                std.log.err(
                    "PARSER: Could not create page ctx, err={}, url={s}.",
                    .{ err, link_msg },
                );
                continue;
            };
            new_page_ctx.* = .{ .depth = curr_depth + 1, .page = new_page_hp };

            url_channel.send(&new_page_ctx) catch |err| {
                defer {
                    new_page_ctx.deinit();
                    allocator.destroy(new_page_ctx);
                }
                std.log.err(
                    "PARSER: Could not send page ctx err={}, url={s}",
                    .{ err, link_msg },
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
                page_ctx.deinit(allocator);
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: Allocation failed for, url={s}, err={}",
                .{ page_ctx.page.url, err },
            );
            continue;
        };
        var writer = std.Io.Writer.fixed(txt_buffer);

        std.log.info("REQUESTOR: Requesting url={s}...", .{page_ctx.page.url});
        const resp = curl_easy.fetch(
            page_ctx.page.url,
            .{ .headers = &http_header, .writer = &writer },
        ) catch |err| {
            defer {
                allocator.free(txt_buffer);
                page_ctx.deinit(allocator);
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: HTTP fetch failed, url={s}, err={}",
                .{ page_ctx.page.url, err },
            );
            continue;
        };

        if (@as(std.http.Status, @enumFromInt(resp.status_code)) !=
            std.http.Status.ok)
        {
            defer {
                allocator.free(txt_buffer);
                page_ctx.deinit(allocator);
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: HTTP response not ok, url={s}, status={}",
                .{ page_ctx.page.url, resp.status_code },
            );
            continue;
        }

        page_ctx.html = txt_buffer;
        page_ctx.page.last_crawled_sec = std.time.timestamp();
        parse_channel.send(&page_ctx) catch |err| {
            defer {
                allocator.free(txt_buffer);
                page_ctx.deinit(allocator);
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: Could not send html, url={s}, err={}",
                .{ page_ctx.page.url, err },
            );
        };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() == .leak) @panic("mem leak");
    }
    // var url: [3]u8 = .{ 'a', 'b', 'c' };
    // var content: [3]u8 = .{ 'd', 'e', 'f' };

    // const pm = PageStorage.PageMeta{
    //     .last_crawled = 12,
    //     .etag_fp = 24,
    //     .crawl_period = 36,
    //     .url = &url,
    //     .content = &content,
    // };

    // const ps = try PageStorage.init("test.rocksdb");
    // defer ps.deinit();
    // const page_id = try ps.create_page(allocator, &pm);
    // std.debug.print("Got page id: {}\n", .{page_id});

    // const read_pm = try ps.read_page(allocator, page_id);
    // defer read_pm.deinit(allocator);
    // std.debug.print("read page: {}", .{read_pm});

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();
    const url_arg = args.next().?;
    const seed_url = try allocator.allocSentinel(u8, url_arg.len, 0);
    std.mem.copyForwards(u8, seed_url, url_arg);

    var req_chnl = PageChannel.init(allocator);
    defer req_chnl.deinit();

    var seed_page = allocator.create(PageStorage.Page) catch |err| {
        allocator.free(seed_url);
        return err;
    };
    seed_page.* = .{
        .last_crawled_sec = 0,
        .etag_fp = 0,
        .crawl_period_min = default_crawl_period_min,
        .url = seed_url,
        .content = &.{},
    };

    var seed_page_ctx = allocator.create(PageContext) catch |err| {
        seed_page.deinit(allocator);
        allocator.destroy(seed_page);
        return err;
    };
    errdefer {
        seed_page_ctx.deinit(allocator);
        allocator.destroy(seed_page_ctx);
    }
    seed_page_ctx.* = .{ .page = seed_page, .depth = 0 };

    var parse_chnl = PageChannel.init(allocator);
    defer parse_chnl.deinit();

    var print_chnl = PageChannel.init(allocator);
    defer print_chnl.deinit();

    var req_thread = try std.Thread.spawn(
        .{},
        requestor,
        .{ &req_chnl, &parse_chnl, allocator },
    );
    defer req_thread.join();

    // var req2_thread = try std.Thread.spawn(
    //     .{},
    //     requestor,
    //     .{ &req_chnl, &parse_chnl, allocator },
    // );
    // defer req2_thread.join();

    const page_db = try PageStorage.init("test.rocksdb");
    var parse_thread = try std.Thread.spawn(.{}, parser, .{
        &req_chnl,
        &parse_chnl,
        2,
        allocator,
        &page_db,
    });
    defer parse_thread.join();

    try req_chnl.send(&seed_page_ctx);
}
