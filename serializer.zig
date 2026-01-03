const std = @import("std");

/// Check if the given type is supported for (de)serialization.
pub fn check_type_serializable(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") {
        @compileError("can only serialize structs");
    }

    inline for (std.meta.fields(T)) |f| {
        switch (@typeInfo(f.type)) {
            inline .bool, .int, .float => {},
            inline .pointer => |ti| {
                if (ti.size != .slice) {
                    @compileError("pointer field types must be slices");
                }
                const child_ti = @typeInfo(ti.child);
                if (child_ti != .bool and child_ti != .int and child_ti != .float) {
                    @compileError("slice child type must be primitive");
                }
            },
            else => |ti| @compileError(
                "only primitive or slice field types are supported, got " ++
                    @tagName(ti),
            ),
        }
    }
}

/// Serialize a struct to byte buffer.
/// value is not owned, should be managed by the caller.
pub fn serialize(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: *const T,
) ![]u8 {
    check_type_serializable(T);
    var total_sz: usize = 0;
    const t_fields = std.meta.fields(T);
    inline for (t_fields, 0..) |f, i| {
        switch (@typeInfo(f.type)) {
            inline .bool, .int, .float => total_sz += @sizeOf(f.type),
            inline .pointer => |ti| {
                total_sz += @field(value, f.name).len * @sizeOf(ti.child);
                if (i < t_fields.len - 1) {
                    total_sz += @sizeOf(usize);
                }
            },
            else => {},
        }
    }

    const buf = try allocator.alloc(u8, total_sz);
    errdefer allocator.free(buf);

    var offset: usize = 0;
    inline for (t_fields, 0..) |f, i| {
        switch (@typeInfo(f.type)) {
            inline .pointer => {
                const slice = @field(value, f.name);
                if (i < t_fields.len - 1) {
                    const len_size = @sizeOf(usize);
                    @memcpy(
                        buf[offset .. offset + len_size],
                        std.mem.asBytes(&slice.len),
                    );
                    offset += len_size;
                }

                const slice_bytes = std.mem.sliceAsBytes(slice);
                @memcpy(buf[offset .. offset + slice_bytes.len], slice_bytes);
                offset += slice_bytes.len;
            },
            inline else => {
                const f_size = @sizeOf(f.type);
                @memcpy(
                    buf[offset .. offset + f_size],
                    std.mem.asBytes(&@field(value, f.name)),
                );
                offset += f_size;
            },
        }
    }
    return buf;
}

/// Deserialize a byte buffer to the given type struct.
/// buffer is not owned, should be managed by the caller.
pub fn deserialize(
    comptime T: type,
    allocator: std.mem.Allocator,
    buffer: []const u8,
) !T {
    check_type_serializable(T);
    var res: T = undefined;
    const t_fields = std.meta.fields(T);

    // Initialize slices to empty.
    inline for (t_fields) |f| {
        const ti = @typeInfo(f.type);
        if (ti != .pointer) continue;
        @field(res, f.name) = &.{};
    }

    // Deallocate the slice fields on errors.
    errdefer {
        inline for (t_fields) |f| {
            const ti = @typeInfo(f.type);
            if (ti != .pointer) continue;
            if (@field(res, f.name).len > 0) allocator.free(@field(res, f.name));
        }
    }

    var offset: usize = 0;
    inline for (t_fields, 0..) |f, i| {
        switch (@typeInfo(f.type)) {
            inline .pointer => |ti| {
                const child_sz = @sizeOf(ti.child);
                const rem_sz = buffer.len - offset;
                const slice_len = if (i < t_fields.len - 1) not_last: {
                    const len_size = @sizeOf(usize);
                    if (offset + len_size > buffer.len) return error.BufferTooSmall;
                    const sl = std.mem.bytesToValue(
                        usize,
                        buffer[offset .. offset + len_size],
                    );
                    offset += len_size;
                    break :not_last sl;
                } else last: {
                    if (rem_sz % child_sz != 0) {
                        return error.RemainingBufferSizeNotAligned;
                    }

                    break :last rem_sz / child_sz;
                };
                const slice_sz = child_sz * slice_len;
                if (rem_sz < slice_sz) return error.BufferTooSmall;
                if (ti.sentinel()) |ti_sent| {
                    @field(res, f.name) = try allocator.allocSentinel(
                        ti.child,
                        slice_len,
                        ti_sent,
                    );
                } else {
                    @field(res, f.name) = try allocator.alloc(ti.child, slice_len);
                }
                const slice_bytes = std.mem.sliceAsBytes(@field(res, f.name));
                @memcpy(slice_bytes, buffer[offset .. offset + slice_sz]);
                offset += slice_sz;
            },
            inline else => {
                const field_sz = @sizeOf(f.type);
                if (offset + field_sz > buffer.len) return error.BufferTooSmall;
                @field(res, f.name) = std.mem.bytesToValue(
                    f.type,
                    buffer[offset .. offset + field_sz],
                );
                offset += field_sz;
            },
        }
    }

    return res;
}

const talloc = std.testing.allocator;

const TestStruct = struct {
    x: []u8,
    y: i32,
    z: []i32,
    t: []u8,
    u: bool,
    v: []u64,
};

test "serde_simple" {
    var x: [3]u8 = .{ 'a', 'b', 'c' };
    var z: [3]i32 = .{ 3, 4, 5 };
    var t: [2]u8 = .{ 'd', 'e' };
    var v: [6]u64 = .{ 6, 7, 2, 6, 1, 12 };
    var val = TestStruct{
        .x = &x,
        .y = 5,
        .z = &z,
        .t = &t,
        .u = true,
        .v = &v,
    };
    const buf = try serialize(TestStruct, talloc, &val);
    defer talloc.free(buf);
    const de = try deserialize(TestStruct, talloc, buf);
    defer {
        talloc.free(de.x);
        talloc.free(de.z);
        talloc.free(de.t);
        talloc.free(de.v);
    }
    try std.testing.expectEqualDeep(val, de);
}

test "serde_empty_slices" {
    var val = TestStruct{
        .x = &.{},
        .y = 99999,
        .z = &.{},
        .t = &.{},
        .u = false,
        .v = &.{},
    };
    const buf = try serialize(TestStruct, talloc, &val);
    defer talloc.free(buf);
    const de = try deserialize(TestStruct, talloc, buf);
    try std.testing.expectEqualDeep(val, de);
}

test "deserialization_small_buffer" {
    const buf = "\x01" ++ "\x00" ** 7 ++ "a";
    try std.testing.expectError(error.BufferTooSmall, deserialize(
        TestStruct,
        talloc,
        buf,
    ));
}

test "last_slice_not_aligned" {
    // First 29 bytes until the last slice are just 0.
    const buf = "\x00" ** 29 ++
        // Last slice length is 3.
        "\x03" ++ "\x00" ** 7 ++
        // But there are 25 bytes remaining which should not be
        // divisible by 8.
        "\x00" ** 25;

    try std.testing.expectError(error.RemainingBufferSizeNotAligned, deserialize(
        TestStruct,
        talloc,
        buf,
    ));
}

test "deserialize_memory_bomb" {
    // Insanely large slice size, but the buffer is very small.
    const buf = "\xFF" ** 8 ++ "x00";
    try std.testing.expectError(error.BufferTooSmall, deserialize(
        TestStruct,
        talloc,
        buf,
    ));
}
