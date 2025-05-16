const std = @import("std");
const builtin = @import("builtin");
const HTMLStripper = @import("html_strip.zig").HTMLStripper;
const Allocator = std.mem.Allocator;
const http_header: std.http.Header = .{
    .name = "User-Agent",
    .value = "Mozilla/5.0 (compatible; Googlebot/2.1; " ++
        "+http://www.google.com/bot.html)",
};

fn Channel(comptime T: type) type {
    const ChannelMessage = union(enum) {
        message: T,
        eos: void,
    };

    return struct {
        const Self = @This();
        const QueueType = std.fifo.LinearFifo(ChannelMessage, .Dynamic);

        queue: QueueType,
        timeout_ns: u64,
        queue_mutex: std.Thread.Mutex = .{},
        queue_cond: std.Thread.Condition = .{},

        pub fn init(allocator: Allocator, timeout_ns: u64) Self {
            return Self{
                .queue = QueueType.init(allocator),
                .timeout_ns = timeout_ns,
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
        }

        fn _send(self: *Self, message: *const ChannelMessage) !void {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            try self.queue.writeItem(message.*);
            self.queue_cond.signal();
        }

        // Send a message over the channel.
        pub fn send(self: *Self, elem: *const T) !void {
            const msg = ChannelMessage{ .message = elem.* };
            try self._send(&msg);
        }

        // Receive a message over the channel. Blocking until there is
        // a message.
        pub fn receive(self: *Self) ChannelMessage {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            while (self.queue.readableLength() == 0) {
                self.queue_cond.timedWait(&self.queue_mutex, self.timeout_ns) catch {
                    return ChannelMessage.eos;
                };
            }

            if (self.queue.peekItem(self.queue.head) == .eos) {
                return ChannelMessage.eos;
            }

            return self.queue.readItem().?;
        }

        // Close the channel. Receivers will be notified.
        pub fn close(self: *Self) !void {
            const msg = ChannelMessage{ .eos = {} };
            try self._send(&msg);
        }
    };
}

fn printer(print_channel: *Channel([]const u8), allocator: Allocator) !void {
    var stdout = std.io.getStdOut().writer();
    while (true) {
        const print_msg = print_channel.receive();
        if (print_msg == .eos)
            break;

        defer allocator.free(print_msg.message);
        try stdout.print("{s}\n", .{print_msg.message});
    }
}

fn parser(
    url_channel: *Channel([]const u8),
    parse_channel: *Channel([]const u8),
    print_channel: *Channel([]const u8),
    allocator: Allocator,
) !void {
    var stripper = HTMLStripper.init(allocator);
    defer stripper.deinit();

    while (true) {
        const html_text_msg = parse_channel.receive();
        if (html_text_msg == .eos)
            break;

        const html_text = html_text_msg.message;
        defer allocator.free(html_text);
        const html_cont = stripper.strip(html_text) catch |err| {
            std.log.err("Parse error {}", .{err});
            continue;
        };

        print_channel.send(&html_cont) catch |err| {
            allocator.free(html_cont);
            return err;
        };

        for (stripper.links.items) |link| {
            try url_channel.send(&link);
        }
    }
}

fn requestor(
    req_channel: *Channel([]const u8),
    parse_channel: *Channel([]const u8),
    allocator: Allocator,
) !void {
    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();
    while (true) {
        const url_msg = req_channel.receive();
        if (url_msg == .eos)
            break;

        defer allocator.free(url_msg.message);
        var html_text = std.ArrayList(u8).init(allocator);
        errdefer html_text.deinit();

        std.debug.print("got={s}\n", .{url_msg.message});
        const resp = try http_client.fetch(.{
            .location = .{ .url = url_msg.message },
            .method = .GET,
            .max_append_size = 5 * 1024 * 1024,
            .response_storage = .{ .dynamic = &html_text },
            .extra_headers = (&http_header)[0..1],
        });
        if (resp.status != std.http.Status.ok) {
            defer html_text.deinit();
            std.log.err("HTTP Request failed, url={s}, status={}", .{
                url_msg.message,
                resp.status,
            });
            continue;
        }

        try parse_channel.send(&@as([]const u8, try html_text.toOwnedSlice()));
    }

    // try url_channel.send(&@as([]const u8, try html_text.toOwnedSlice()));
    // try url_channel.close();
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

    var req_chnl = Channel([]const u8).init(allocator, 500 * 1000 * 1000);
    defer req_chnl.deinit();

    // Seed cannot be send.
    req_chnl.send(&seed_url) catch |err| {
        allocator.free(seed_url);
        return err;
    };

    var parse_chnl = Channel([]const u8).init(allocator, 500 * 1000 * 1000);
    defer parse_chnl.deinit();

    var print_chnl = Channel([]const u8).init(allocator, 500 * 1000 * 1000);
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
    defer print_thread.join();
}
