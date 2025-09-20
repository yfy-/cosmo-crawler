const std = @import("std");
const builtin = @import("builtin");
const HTMLStripper = @import("html_strip.zig").HTMLStripper;
const ds = @import("ds.zig");
const Channel = ds.Channel;
const Allocator = std.mem.Allocator;
const http_header: std.http.Header = .{
    .name = "User-Agent",
    .value = "Mozilla/5.0 (compatible; Googlebot/2.1; " ++
        "+http://www.google.com/bot.html)",
};

const Page = struct {
    const Self = @This();

    url: []const u8,
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

fn printer(print_channel: *PageChannel, allocator: Allocator) void {
    var stdout = std.io.getStdOut().writer();
    while (true) {
        const page_msg = print_channel.receive(null);
        if (page_msg == .eos)
            break;

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
            std.log.err("PARSER: Received null url={s}", .{page_ctx.url});
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

        const curr_depth = page_ctx.depth;
        var curr_url = std.ArrayList(u8).initCapacity(
            allocator,
            page_ctx.url.len,
        ) catch |err| {
            defer {
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "PARSER: Could not allocate url array, err={}, url={s}",
                .{ err, page_ctx.url },
            );
            continue;
        };
        defer curr_url.deinit();

        curr_url.appendSlice(page_ctx.url) catch |err| {
            defer {
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "PARSER: Could append to url array, err={}, url={s}",
                .{ err, page_ctx.url },
            );
            continue;
        };

        print_channel.send(&page_ctx) catch |err| {
            defer {
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err("PARSER: Could not send content, err={}", .{err});
        };

        const links = stripper.links.toOwnedSlice() catch |err| {
            std.log.err("PARSER: Could not own links, err={}", .{err});
            continue;
        };
        defer {
            for (links) |link| {
                allocator.free(link);
            }
            allocator.free(links);
        }

        if (curr_depth == max_depth) {
            continue;
        }

        for (links) |link| {
            if (link.len == 0 or link[0] == '#') continue;
            var new_link = std.ArrayList(u8).init(allocator);
            defer new_link.deinit();

            // Relative link.
            if (link[0] == '/') {
                new_link.appendSlice(curr_url.items) catch |err| {
                    std.log.err(
                        "PARSER: Could not append to new link, err={}, url={s}",
                        .{ err, curr_url.items },
                    );
                    continue;
                };
            }

            new_link.appendSlice(link) catch |err| {
                std.log.err(
                    "PARSER: Could not append to new link, err={}, url={s}",
                    .{ err, curr_url.items },
                );
                continue;
            };

            const new_page_ctx = allocator.create(Page) catch |err| {
                std.log.err(
                    "PARSER: Could not create page ctx, err={}, url={s}, " ++
                        "link={s}",
                    .{ err, curr_url.items, new_link.items },
                );
                continue;
            };

            const link_msg = new_link.toOwnedSlice() catch |err| {
                std.log.err(
                    "PARSER: Could own link msg, err={}, url={s}, link={s}",
                    .{ err, curr_url.items, new_link.items },
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
                    .{ err, curr_url.items, new_link.items },
                );
            };
        }
    }
}

const HttpClient = std.http.Client;
const FetchChannel = Channel(anyerror!HttpClient.FetchResult, false);

fn fetchWithTimeout(
    client: *HttpClient,
    options: std.http.FetchOptions,
) !std.http.FetchResult {
    const uri = switch (options.location) {
        .url => |u| try std.Uri.parse(u),
        .uri => |u| u,
    };
    var server_header_buffer: [16 * 1024]u8 = undefined;

    const method: std.http.Method = options.method orelse
        if (options.payload != null) .POST else .GET;

    var req = try client.open(client, method, uri, .{
        .server_header_buffer = options.server_header_buffer orelse
            &server_header_buffer,
        .redirect_behavior = options.redirect_behavior orelse
            if (options.payload == null) @enumFromInt(3) else .unhandled,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        .keep_alive = options.keep_alive,
    });
    defer req.deinit();

    if (options.payload) |payload| req.transfer_encoding = .{
        .content_length = payload.len,
    };

    try req.send();

    if (options.payload) |payload| try req.writeAll(payload);

    try req.finish();
    try req.wait();

    switch (options.response_storage) {
        .ignore => {
            // Take advantage of request internals to discard the response body
            // and make the connection available for another request.
            req.response.skip = true;
            // No buffer is necessary when skipping.
            std.assert(try req.transferRead(&.{}) == 0);
        },
        .dynamic => |list| {
            const max_append_size = options.max_append_size orelse
                2 * 1024 * 1024;
            try req.reader().readAllArrayList(list, max_append_size);
        },
        .static => |list| {
            const buf = b: {
                const buf = list.unusedCapacitySlice();
                if (options.max_append_size) |len| {
                    if (len < buf.len) break :b buf[0..len];
                }
                break :b buf;
            };
            list.items.len += try req.reader().readAll(buf);
        },
    }

    return .{
        .status = req.response.status,
    };
}

fn request_with_timeout(
    client: *HttpClient,
    url: []const u8,
    html_text: *std.ArrayList(u8),
    out_channel: *FetchChannel,
) !void {
    const uri = try std.Uri.parse(url);
    var server_header_buffer: [16 * 1024]u8 = undefined;
    try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = (&http_header)[0..1],
    });
    const fetch_res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .max_append_size = 5 * 1024 * 1024,
        .response_storage = .{ .dynamic = html_text },
        .extra_headers = (&http_header)[0..1],
    });
    try out_channel.send(&fetch_res);
}

fn requestor(
    req_channel: *PageChannel,
    parse_channel: *PageChannel,
    allocator: Allocator,
) !void {
    var http_client: HttpClient = .{ .allocator = allocator };
    defer http_client.deinit();
    try parse_channel.subscribe_as_sender();
    while (true) {
        const page_msg = req_channel.receive(5_000_000_000);
        if (page_msg == .eos) {
            // Just fail if we cannot close.
            try parse_channel.close();
            break;
        }

        const page_ctx = page_msg.message;
        var html_arr = std.ArrayList(u8).init(allocator);

        var fetch_chnl = FetchChannel.init(allocator);
        defer fetch_chnl.deinit();

        std.log.info("REQUESTOR: Requesting url={s}...", .{page_ctx.url});
        var fetch_thrd = std.Thread.spawn(
            .{},
            request_with_timeout,
            .{
                &http_client,
                page_ctx.url,
                &html_arr,
                &fetch_chnl,
            },
        ) catch |err| {
            defer {
                html_arr.deinit();
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: Cannot spawn fetch thread, url={s}, err={}",
                .{ page_ctx.url, err },
            );
            continue;
        };
        defer fetch_thrd.detach();

        const fetch_thrd_ret = fetch_chnl.receive(5_000_000_000);
        if (fetch_thrd_ret == .eos) {
            defer {
                html_arr.deinit();
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: Fetch channel timedout, url={s}",
                .{page_ctx.url},
            );
            continue;
        }

        const fetch_res = fetch_thrd_ret.message;
        if (fetch_res) |resp| {
            if (resp.status == std.http.Status.ok) {
                page_ctx.html = html_arr.toOwnedSlice() catch |err| err_blk: {
                    defer {
                        html_arr.deinit();
                        page_ctx.deinit();
                        allocator.destroy(page_ctx);
                    }
                    std.log.err(
                        "REQUESTOR: Could not own html buffer, url={s}, err={}",
                        .{ page_ctx.url, err },
                    );
                    break :err_blk null;
                };
                parse_channel.send(&page_ctx) catch |err| {
                    defer {
                        html_arr.deinit();
                        page_ctx.deinit();
                        allocator.destroy(page_ctx);
                    }
                    std.log.err(
                        "REQUESTOR: Could not send html, url={s}, err={}",
                        .{ page_ctx.url, err },
                    );
                };
            } else {
                defer {
                    html_arr.deinit();
                    page_ctx.deinit();
                    allocator.destroy(page_ctx);
                }
                std.log.err(
                    "REQUESTOR: HTTP response not ok, url={s}, status={}",
                    .{ page_ctx.url, resp.status },
                );
            }
        } else |err| {
            defer {
                html_arr.deinit();
                page_ctx.deinit();
                allocator.destroy(page_ctx);
            }
            std.log.err(
                "REQUESTOR: HTTP fetch failed, url={s}, err={}",
                .{ page_ctx.url, err },
            );
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() == .leak) @panic("mem leak");
    }

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();
    const url_arg = args.next().?;
    const seed_url = try allocator.alloc(u8, url_arg.len);
    std.mem.copyForwards(u8, seed_url, url_arg);

    var req_chnl = PageChannel.init(allocator);
    defer req_chnl.deinit();

    var seed_page_ctx = allocator.create(Page) catch |err| {
        allocator.free(seed_url);
        return err;
    };
    seed_page_ctx.* = .{ .url = seed_url, .depth = 0, .allocator = allocator };
    // Seed cannot be send.
    req_chnl.send(&seed_page_ctx) catch |err| {
        seed_page_ctx.deinit();
        allocator.destroy(seed_page_ctx);
        return err;
    };

    var parse_chnl = PageChannel.init(allocator);
    defer parse_chnl.deinit();

    var print_chnl = PageChannel.init(allocator);
    defer print_chnl.deinit();

    var req_thread = try std.Thread.spawn(
        .{},
        requestor,
        .{ &req_chnl, &parse_chnl, allocator },
    );
    // var req2_thread = try std.Thread.spawn(
    //     .{},
    //     requestor,
    //     .{ &req_chnl, &parse_chnl, allocator },
    // );
    // defer req2_thread.join();

    var parse_thread = try std.Thread.spawn(.{}, parser, .{
        &req_chnl,
        &parse_chnl,
        &print_chnl,
        2,
        allocator,
    });

    var print_thread = try std.Thread.spawn(.{}, printer, .{
        &print_chnl,
        allocator,
    });

    req_thread.join();
    std.log.debug("req thread stopped.", .{});
    parse_thread.join();
    std.log.debug("parse thread stopped.", .{});
    print_thread.join();
    std.log.debug("print thread stopped.", .{});
}
