const std = @import("std");
const Allocator = std.mem.Allocator;

/// A simple Ring Buffer.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        buffer: []T = &.{},
        head: usize = 0,
        len: usize = 0,

        pub fn init(allocator: Allocator) Self {
            return Self{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            if (self.buffer.len > 0)
                self.allocator.free(self.buffer);
        }

        fn grow(self: *Self) !void {
            var new_capacity = 2 * self.buffer.len;
            if (new_capacity == 0)
                new_capacity = 8;

            var new_buffer = try self.allocator.alloc(T, new_capacity);
            for (0..self.len) |i| {
                new_buffer[i] = self.buffer[(self.head + i) % self.buffer.len];
            }
            self.deinit();
            self.buffer = new_buffer;
            self.head = 0;
        }

        pub fn push(self: *Self, elem: T) !void {
            if (self.len == self.buffer.len)
                try self.grow();

            self.buffer[(self.head + self.len) % self.buffer.len] = elem;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0)
                return null;

            const elem_idx = self.head;
            self.head = (self.head + 1) % self.buffer.len;
            self.len -= 1;
            return self.buffer[elem_idx];
        }

        pub fn peek(self: *Self) ?T {
            if (self.len == 0)
                return null;

            return self.buffer[self.head];
        }
    };
}

test "RingBuffer push all pop all" {
    var rb = RingBuffer(i32).init(std.testing.allocator);
    defer rb.deinit();
    for (@as(i32, 1)..@as(i32, 65)) |i| {
        try rb.push(@intCast(i));
    }

    for (1..65) |i| {
        const exp_i: i32 = @intCast(i);
        try std.testing.expectEqual(exp_i, rb.pop());
    }
}

test "RingBuffer arbitrary push and pop" {
    var rb = RingBuffer(i32).init(std.testing.allocator);
    defer rb.deinit();
    try rb.push(1);
    try rb.push(2);
    try rb.push(3);
    try std.testing.expectEqual(1, rb.pop());
    try rb.push(4);
    try rb.push(5);
    try std.testing.expectEqual(2, rb.pop());
    try std.testing.expectEqual(3, rb.peek());
    try rb.push(6);
    try std.testing.expectEqual(3, rb.peek());
    try std.testing.expectEqual(3, rb.pop());
    for (@as(i32, 7)..@as(i32, 17)) |i| {
        try rb.push(@intCast(i));
    }

    for (@as(i32, 4)..@as(i32, 17)) |i| {
        const exp_i: i32 = @intCast(i);
        try std.testing.expectEqual(exp_i, rb.pop());
    }

    try std.testing.expectEqual(null, rb.peek());
    try std.testing.expectEqual(null, rb.pop());
}

/// Send and receive messages in a thread safe manner. Messages in
/// transit are owned by the channel. If they require deallocation,
/// set message_free flag.
pub fn Channel(comptime T: type, comptime message_free: bool) type {
    const ChannelMessage = union(enum) {
        message: T,
        eos: void,
    };

    return struct {
        const Self = @This();
        const QueueType = RingBuffer(ChannelMessage);

        allocator: Allocator,
        queue: QueueType,
        queue_mutex: std.Thread.Mutex = .{},
        queue_cond: std.Thread.Condition = .{},

        sender_count: usize = 0,
        closed: bool = false,
        sender_count_mutex: std.Thread.Mutex = .{},

        /// Initialize a channel with timeout.
        /// Thread unsafe.
        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .queue = QueueType.init(allocator),
            };
        }

        /// Deinitialize a channel. Thread unsafe.
        pub fn deinit(self: *Self) void {
            if (comptime message_free) {
                while (self.queue.pop()) |msg| {
                    if (msg == .eos)
                        continue;

                    const t_info = @typeInfo(T);
                    if (t_info != .pointer) {
                        @compileError("cannot free non-pointer!");
                    }

                    switch (@typeInfo(t_info.pointer.child)) {
                        .@"struct", .@"enum", .@"union" => {
                            if (@hasDecl(t_info.pointer.child, "deinit")) {
                                msg.message.deinit();
                            }
                            self.allocator.destroy(msg.message);
                        },
                        else => self.allocator.free(msg.message),
                    }
                }
            }
            self.queue.deinit();
        }

        pub fn subscribe_as_sender(self: *Self) !void {
            self.sender_count_mutex.lock();
            defer self.sender_count_mutex.unlock();
            if (self.closed)
                return error.ClosedChannel;

            self.sender_count += 1;
        }

        fn _send(self: *Self, message: *const ChannelMessage) !void {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            try self.queue.push(message.*);
            self.queue_cond.signal();
        }

        /// Send a message over the channel. Thread safe.
        pub fn send(self: *Self, elem: *const T) !void {
            const msg = ChannelMessage{ .message = elem.* };
            self.sender_count_mutex.lock();
            defer self.sender_count_mutex.unlock();
            if (self.closed)
                return error.ClosedChannel;

            try self._send(&msg);
        }

        /// Receive a message over the channel. Blocking until there is
        /// a message or timeout. Thread safe.
        pub fn receive(self: *Self, timeout_ns: ?u64) ChannelMessage {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            while (self.queue.len == 0) {
                if (timeout_ns) |t_ns| {
                    self.queue_cond.timedWait(
                        &self.queue_mutex,
                        t_ns,
                    ) catch {
                        return ChannelMessage.eos;
                    };
                } else {
                    self.queue_cond.wait(&self.queue_mutex);
                }
            }

            if (self.queue.peek().? == .eos) {
                return ChannelMessage.eos;
            }

            return self.queue.pop().?;
        }

        /// Close the channel to notify receivers. Thread safe.
        pub fn close(self: *Self) !void {
            self.sender_count_mutex.lock();
            defer self.sender_count_mutex.unlock();

            if (self.sender_count == 0) {
                return error.DoubleClose;
            }

            self.sender_count -= 1;
            if (self.sender_count > 0) return;

            self.closed = true;
            const msg = ChannelMessage{ .eos = {} };
            try self._send(&msg);
        }
    };
}
