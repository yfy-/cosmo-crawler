const std = @import("std");
const builtin = @import("builtin");
const HTMLStripper = @import("html_strip.zig").HTMLStripper;
const Allocator = std.mem.Allocator;
const http_header: std.http.Header = .{
    .name = "User-Agent",
    .value = "Mozilla/5.0 (compatible; Googlebot/2.1; " ++
        "+http://www.google.com/bot.html)",
};

fn Channel(comptime T: type, comptime message_free: bool) type {
    const ChannelMessage = union(enum) {
        message: T,
        eos: void,
    };

    return struct {
        const Self = @This();
        const QueueType = std.fifo.LinearFifo(ChannelMessage, .Dynamic);

        allocator: Allocator,
        queue: QueueType,
        timeout_ns: u64,
        queue_mutex: std.Thread.Mutex = .{},
        queue_cond: std.Thread.Condition = .{},

        /// Initialize a channel with timeout.
        /// Thread unsafe.
        pub fn init(allocator: Allocator, timeout_ns: u64) Self {
            return Self{
                .allocator = allocator,
                .queue = QueueType.init(allocator),
                .timeout_ns = timeout_ns,
            };
        }

        /// Deinitialize a channel. Thread unsafe.
        pub fn deinit(self: *Self) void {
            if (comptime message_free) {
                while (self.queue.readItem()) |msg| {
                    if (msg == .eos)
                        continue;

                    self.allocator.free(msg.message);
                }
            }
            self.queue.deinit();
        }

        fn _send(self: *Self, message: *const ChannelMessage) !void {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            try self.queue.writeItem(message.*);
            self.queue_cond.signal();
        }

        /// Send a message over the channel. Thread safe.
        pub fn send(self: *Self, elem: *const T) !void {
            const msg = ChannelMessage{ .message = elem.* };
            try self._send(&msg);
        }

        /// Receive a message over the channel. Blocking until there is
        /// a message or timeout. Thread safe.
        pub fn receive(self: *Self) ChannelMessage {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            while (self.queue.readableLength() == 0) {
                self.queue_cond.timedWait(&self.queue_mutex, self.timeout_ns) catch {
                    return ChannelMessage.eos;
                };
            }

            if (self.queue.peekItem(0) == .eos) {
                return ChannelMessage.eos;
            }

            return self.queue.readItem().?;
        }

        /// Close the channel to notify receivers. Thread safe.
        pub fn close(self: *Self) !void {
            const msg = ChannelMessage{ .eos = {} };
            try self._send(&msg);
        }
    };
}

const StrChannel = Channel([]const u8, true);

fn printer(print_channel: *StrChannel, allocator: Allocator) void {
    var stdout = std.io.getStdOut().writer();
    while (true) {
        const print_msg = print_channel.receive();
        if (print_msg == .eos)
            break;

        defer allocator.free(print_msg.message);
        stdout.print("{s}\n", .{print_msg.message}) catch |err| {
            std.log.err("PRINTER: err={}", .{err});
        };
    }
}

fn parser(
    url_channel: *StrChannel,
    parse_channel: *StrChannel,
    print_channel: *StrChannel,
    allocator: Allocator,
) void {
    var stripper = HTMLStripper.init(allocator);
    defer stripper.deinit();
    while (true) {
        const html_text_msg = parse_channel.receive();
        if (html_text_msg == .eos)
            break;

        const html_text = html_text_msg.message;
        defer allocator.free(html_text);
        const html_cont = stripper.strip(html_text) catch |err| {
            std.log.err("PARSER: Parse err={}", .{err});
            continue;
        };

        print_channel.send(&html_cont) catch |err| {
            defer allocator.free(html_cont);
            std.log.err("PARSER: Could not send content, err={}", .{err});
            continue;
        };

        const links = stripper.links.toOwnedSlice() catch |err| {
            std.log.err("PARSER: Could not own links, err={}", .{err});
            continue;
        };

        for (links) |link| {
            url_channel.send(&link) catch |err| {
                std.log.err("PARSER: Could not send link={s}, err={}", .{ link, err });
            };
        }
    }
}

const HttpClient = std.http.Client;
const FetchChannel = Channel(anyerror!HttpClient.FetchResult, false);

fn request_with_timeout(
    client: *HttpClient,
    url: []const u8,
    html_text: *std.ArrayList(u8),
    out_channel: *FetchChannel,
) !void {
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
    req_channel: *StrChannel,
    parse_channel: *StrChannel,
    allocator: Allocator,
) !void {
    var http_client: HttpClient = .{ .allocator = allocator };
    defer http_client.deinit();
    while (true) {
        const url_msg = req_channel.receive();
        if (url_msg == .eos)
            break;

        const url = url_msg.message;
        defer allocator.free(url);

        var html_text = std.ArrayList(u8).init(allocator);
        errdefer html_text.deinit();

        var fetch_chnl = FetchChannel.init(allocator, 5 * 1000 * 1000 * 1000);
        defer fetch_chnl.deinit();

        var fetch_thrd = std.Thread.spawn(
            .{},
            request_with_timeout,
            .{
                &http_client,
                url,
                &html_text,
                &fetch_chnl,
            },
        ) catch |err| {
            defer html_text.deinit();
            std.log.err("REQUESTOR: Cannot spawn fetch thread, url={s}, err={}", .{ url, err });
            continue;
        };
        defer fetch_thrd.join();

        const fetch_thrd_ret = fetch_chnl.receive();
        if (fetch_thrd_ret == .eos) {
            defer html_text.deinit();
            std.log.err("REQUESTOR: Fetch channel timedout, url={s}", .{url});
            continue;
        }

        const fetch_res = fetch_thrd_ret.message;
        if (fetch_res) |resp| {
            if (resp.status == std.http.Status.ok) {
                try parse_channel.send(&@as([]const u8, try html_text.toOwnedSlice()));
            } else {
                defer html_text.deinit();
                std.log.err("REQUESTOR: HTTP response not ok, url={s}, status={}", .{
                    url,
                    resp.status,
                });
            }
        } else |err| {
            defer html_text.deinit();
            std.log.err("REQUESTOR: HTTP fetch failed, url={s}, err={}", .{ url, err });
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

    var req_chnl = StrChannel.init(allocator, 500 * 1000 * 1000);
    defer req_chnl.deinit();

    // Seed cannot be send.
    req_chnl.send(&seed_url) catch |err| {
        allocator.free(seed_url);
        return err;
    };

    var parse_chnl = StrChannel.init(allocator, 5000 * 1000 * 1000);
    defer parse_chnl.deinit();

    var print_chnl = StrChannel.init(allocator, 5000 * 1000 * 1000);
    defer print_chnl.deinit();

    var req_thread = try std.Thread.spawn(
        .{},
        requestor,
        .{ &req_chnl, &parse_chnl, allocator },
    );
    defer req_thread.join();

    var parse_thread = try std.Thread.spawn(.{}, parser, .{
        &req_chnl,
        &parse_chnl,
        &print_chnl,
        allocator,
    });
    defer parse_thread.join();

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
