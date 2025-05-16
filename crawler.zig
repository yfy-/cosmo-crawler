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
    const MessageTy = union {
        message: T,
        eos: void,
    };

    return struct {
        const Self = @This();
        const QueueType = std.fifo.LinearFifo(MessageTy, .Dynamic);

        queue: QueueType,
        queue_mutex: std.Thread.Mutex = .{},
        queue_cond: std.Thread.Condition = .{},

        fn init(allocator: Allocator) Self {
            return Self{ .queue = QueueType.init(allocator) };
        }

        fn deinit(self: *Self) void {
            self.queue.deinit();
        }

        // Send a message over the channel.
        fn send(self: *Self, elem: T) !void {
            self.queue_mutex.lock();
            try self.queue.writeItem(MessageTy{ .message = elem });
            self.queue_cond.signal();
            self.queue_mutex.unlock();
        }

        // Receive a message over the channel. Blocking until there is
        // a message.
        fn receive(self: *Self) MessageTy {
            self.queue_mutex.lock();
            while (self.queue.readableLength() == 0) {
                self.queue_cond.wait(&self.queue_mutex);
            }

            if (self.queue.peekItem(self.queue.count - 1))
            const elem = self.queue.readItem().?;
            self.queue_mutex.unlock();

            return elem;
        }
    };
}

fn requestor(
    seed_url: []const u8,
    url_channel: *Channel([]const u8),
    allocator: std.mem.Allocator,
) !void {
    // To be deallocated by the caller.
    var html_text = std.ArrayList(u8).init(allocator);
    errdefer html_text.deinit();

    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    const resp = try http_client.fetch(.{
        .location = .{ .url = seed_url },
        .method = .GET,
        .max_append_size = 5 * 1024 * 1024,
        .response_storage = .{ .dynamic = &html_text },
        .extra_headers = (&http_header)[0..1],
    });

    if (resp.status != std.http.Status.ok) {
        std.log.err("HTTP Request failed with {}", .{resp.status});
        return error.HTTPRequestFailed;
    }

    try url_channel.send(try html_text.toOwnedSlice());
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
    const url = args.next().?;
    var req_chnl = Channel([]const u8).init(allocator);
    var thread = try std.Thread.spawn(
        .{},
        requestor,
        .{ url, &req_chnl, allocator },
    );
    defer thread.join();

    var stripper = HTMLStripper.init(allocator);
    defer stripper.deinit();

    const html_text = req_chnl.receive();
    defer allocator.free(html_text);

    const html_cont = try stripper.strip(html_text);
    defer allocator.free(html_cont);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(html_cont);
}
