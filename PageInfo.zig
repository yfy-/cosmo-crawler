const std = @import("std");

const c = @cImport({
    @cInclude("rocksdb/c.h");
});

const Self = @This();
// db_path: [*c]const u8,
db: *c.rocksdb_t = undefined,
db_opts: *c.rocksdb_options_t = undefined,
write_opts: *c.rocksdb_writeoptions_t = undefined,
read_opts: *c.rocksdb_readoptions_t = undefined,

pub fn check_type_serializable(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") {
        @compileError("can only serialize structs");
    }

    inline for (std.meta.fields(T)) |f| {
        switch (@typeInfo(f.type)) {
            inline .bool, .int, .float => {},
            inline .pointer => |ti| {
                if (ti.size != .slice) @compileError("pointer field types must be slices");
                const child_ti = @typeInfo(ti.child);
                if (child_ti != .bool and child_ti != .int and child_ti != .float) {
                    @compileError("slice child type must be primitive");
                }
            },
            else => |ti| @compileError(
                "only primitive or slice field types are supported, got " ++ @tagName(ti),
            ),
        }
    }
}

/// Serialize a struct to byte buffer.
/// value is not owned, should be managed by the caller.
pub fn serialize(comptime T: type, allocator: std.mem.Allocator, value: *const T) ![]u8 {
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
            inline .pointer => |ti| {
                const slice = @field(value, f.name);
                if (i < t_fields.len - 1) {
                    const len_size = @sizeOf(usize);
                    @memcpy(
                        buf[offset .. offset + len_size],
                        std.mem.asBytes(&slice.len),
                    );
                    offset += len_size;
                }

                for (slice) |e| {
                    const e_size = @sizeOf(ti.child);
                    @memcpy(buf[offset .. offset + e_size], std.mem.asBytes(&e));
                    offset += e_size;
                }
            },
            inline else => {
                const f_size = @sizeOf(f.type);
                @memcpy(buf[offset .. offset + f_size], std.mem.asBytes(&@field(value, f.name)));
                offset += f_size;
            },
        }
    }
    return buf;
}

/// Deserialize a byte buffer to the given type struct.
/// buffer is not owned, should be managed by the caller.
pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, buffer: []u8) !*T {
    check_type_serializable(T);
    var res = try allocator.create(T);
    errdefer allocator.destroy(res);

    const t_fields = std.meta.fields(T);
    var offset: usize = 0;
    inline for (t_fields, 0..) |f, i| {
        switch (@typeInfo(f.type)) {
            inline .pointer => |ti| {
                const child_sz = @sizeOf(ti.child);
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
                    const rem_sz = buffer.len - offset;
                    if (rem_sz % child_sz != 0) {
                        return error.RemainingBufferSizeNotDivisile;
                    }

                    break :last rem_sz / child_sz;
                };
                @field(res, f.name) = try allocator.alloc(ti.child, slice_len);
                // FIXME: Freeing the slice here is not enough.
                errdefer allocator.free(@field(res, f.name));
                for (0..slice_len) |si| {
                    if (offset + child_sz > buffer.len) return error.BufferTooSmall;
                    @field(res, f.name)[si] = std.mem.bytesToValue(
                        ti.child,
                        buffer[offset .. offset + child_sz],
                    );
                    offset += child_sz;
                }
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

const PageMeta = struct {
    last_crawled: u64,
    etag_fp: u64,
    crawl_period: u32,
    url: []u8,
    content: []u8,

    pub fn serialize(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        const sz_last = @sizeOf(@TypeOf(self.last_crawled));
        const sz_etag = @sizeOf(@TypeOf(self.etag_fp));
        const sz_period = @sizeOf(@TypeOf(self.crawl_period));
        const sz_url = @sizeOf(@TypeOf(self.content.len)) + self.url.len;
        const sz_content = self.content.len;
        const sz_page = sz_last + sz_etag + sz_period + sz_url + sz_content;
        const buffer = try allocator.alloc(u8, sz_page);
        errdefer allocator.free(buffer);

        var offset: usize = 0;

        std.mem.writeInt(
            @TypeOf(self.last_crawled),
            &buffer[offset .. offset + sz_last],
            self.last_crawled,
            .little,
        );
        offset += sz_last;

        std.mem.writeInt(
            @TypeOf(self.etag_fp),
            &buffer[offset .. offset + sz_etag],
            self.etag_fp,
            .little,
        );
        offset += sz_etag;

        std.mem.writeInt(
            @TypeOf(self.crawl_period),
            &buffer[offset .. offset + sz_period],
            self.crawl_period,
            .little,
        );
        offset += sz_period;

        @memcpy(buffer[offset..], self.url);
        return buffer;
    }

    pub fn deserialize(owned_buffer: []u8, allocator: std.mem.Allocator) !*PageMeta {
        var offset: usize = 0;

        const ty_last = std.meta.fieldInfo(@This(), .last_crawled).type;
        const last_crawled = std.mem.readInt(
            ty_last,
            &owned_buffer[offset .. offset + @sizeOf(ty_last)],
            .little,
        );
        offset += @sizeOf(ty_last);

        const ty_etag = std.meta.fieldInfo(@This(), .etag_fp).type;
        const etag_fp = std.mem.readInt(
            ty_etag,
            &owned_buffer[offset .. offset + @sizeOf(ty_etag)],
            .little,
        );
        offset += @sizeOf(ty_etag);

        const ty_period = std.meta.fieldInfo(@This(), .crawl_period).type;
        const crawl_period = std.mem.readInt(
            ty_period,
            &owned_buffer[offset .. offset + @sizeOf(ty_period)],
            .little,
        );
        offset += @sizeOf(ty_period);

        const url = try allocator.alloc(u8, owned_buffer.len - offset);
        errdefer allocator.free(url);
        @memcpy(url, owned_buffer[offset..]);

        const page_meta = try allocator.create(@This());
        page_meta.* = .{
            .last_crawled = last_crawled,
            .etag_fp = etag_fp,
            .crawl_period = crawl_period,
            .url = url,
        };
        allocator.free(owned_buffer);
        return page_meta;
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.url);
    }
};

pub fn init(db_path: [*c]const u8) !Self {
    const db_opts = c.rocksdb_options_create() orelse return error.DbInitError;
    errdefer c.rocksdb_options_destroy(db_opts);

    c.rocksdb_options_increase_parallelism(db_opts, 6);
    c.rocksdb_options_optimize_level_style_compaction(db_opts, 0);
    c.rocksdb_options_set_create_if_missing(db_opts, 1);

    const err: [*c][*c]u8 = null;
    const db = c.rocksdb_open(db_opts, db_path, err) orelse return error.DbInitError;
    if (err != null) {
        std.debug.print("DBInitError: {s}", .{err});
        return err.DBInitError;
    }
    errdefer c.rocksdb_close(db);

    const write_opts = c.rocksdb_writeoptions_create() orelse return error.DbInitError;
    errdefer c.rocksdb_writeoptions_destroy(write_opts);

    const read_opts = c.rocksdb_readoptions_create() orelse return error.DbInitError;
    errdefer c.rocksdb_readoptions_destroy(read_opts);

    return Self{ .db = db, .db_opts = db_opts, .write_opts = write_opts, .read_opts = write_opts };
}

pub fn deinit(self: Self) void {
    c.rocksdb_options_destroy(self.db_opts);
    c.rocksdb_writeoptions_destroy(self.write_opts);
    c.rocksdb_readoptions_destroy(self.read_opts);
    c.rocksdb_close(self.db);
}

// pub fn set_page(self: Self) !u128 {
//     const key = "erman";
//     const value = "yafay";
//     c.rocksdb_put(
//         self.db,
//         self.write_opts,
//         @ptrCast(key.ptr),
//         key.len,
//         @ptrCast(value.ptr),
//         value.len,
//         err,
//     );
//     if (err != null) {
//         std.debug.print("Put error: {s}", .{err});
//         return err.PutError;
//     }
// }

// pub fn get_page(self: Self, page_id: u128) !PageMeta {
//     var read_len: usize = undefined;
//     const read_value = c.rocksdb_get(db, read_opts, @ptrCast(key.ptr), key.len, &read_len, err);
//     if (err != null) {
//         std.debug.print("Get error: {s}", .{err});
//         return err.GetError;
//     }
//     defer c.rocksdb_free(read_value);
// }
