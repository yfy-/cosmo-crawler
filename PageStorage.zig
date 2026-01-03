const std = @import("std");
const serde = @import("serializer.zig");

const c = @cImport({
    @cInclude("rocksdb/c.h");
});

const Self = @This();
db: *c.rocksdb_t = undefined,
db_opts: *c.rocksdb_options_t = undefined,
write_opts: *c.rocksdb_writeoptions_t = undefined,
read_opts: *c.rocksdb_readoptions_t = undefined,

pub const Page = struct {
    last_crawled_sec: i64,
    etag_fp: i64,
    crawl_period_min: i32,
    url: [:0]u8,
    content: []u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.content);
    }
};

pub fn init(db_path: [*c]const u8) !Self {
    const db_opts = c.rocksdb_options_create() orelse return error.DbInitError;
    errdefer c.rocksdb_options_destroy(db_opts);

    c.rocksdb_options_increase_parallelism(db_opts, 6);
    c.rocksdb_options_optimize_level_style_compaction(db_opts, 0);
    c.rocksdb_options_set_create_if_missing(db_opts, 1);

    const err: [*c][*c]u8 = null;
    const db = c.rocksdb_open(db_opts, db_path, err) orelse {
        return error.DbInitError;
    };
    if (err != null) {
        std.debug.print("DBInitError: {s}", .{err});
        return err.DBInitError;
    }
    errdefer c.rocksdb_close(db);

    const write_opts = c.rocksdb_writeoptions_create() orelse {
        return error.DbInitError;
    };
    errdefer c.rocksdb_writeoptions_destroy(write_opts);

    const read_opts = c.rocksdb_readoptions_create() orelse {
        return error.DbInitError;
    };
    errdefer c.rocksdb_readoptions_destroy(read_opts);

    return Self{
        .db = db,
        .db_opts = db_opts,
        .write_opts = write_opts,
        .read_opts = read_opts,
    };
}

pub fn deinit(self: Self) void {
    c.rocksdb_options_destroy(self.db_opts);
    c.rocksdb_writeoptions_destroy(self.write_opts);
    c.rocksdb_readoptions_destroy(self.read_opts);
    c.rocksdb_close(self.db);
}

pub fn create_page_id(url: [:0]const u8) u128 {
    var key_arr: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(url, key_arr[0..], .{});
    return std.mem.bytesToValue(u128, key_arr[0..@sizeOf(u128)]);
}

pub fn create_page(
    self: Self,
    allocator: std.mem.Allocator,
    page: *const Page,
) !u128 {
    const key = create_page_id(page.url);
    const key_buf = std.mem.asBytes(&key);
    const value_buf = try serde.serialize(Page, allocator, page);
    defer allocator.free(value_buf);
    const err: [*c][*c]u8 = null;
    c.rocksdb_put(
        self.db,
        self.write_opts,
        key_buf,
        key_buf.len,
        value_buf.ptr,
        value_buf.len,
        err,
    );
    if (err != null) {
        std.debug.print("Put error: {s}\n", .{err});
        return err.RocksDBPutError;
    }

    return key;
}

pub fn read_page_by_url(
    self: Self,
    allocator: std.mem.Allocator,
    url: [:0]u8,
) !?Page {
    return self.read_page_by_id(allocator, create_page_id(url));
}

pub fn read_page_by_id(
    self: Self,
    allocator: std.mem.Allocator,
    page_id: u128,
) !?Page {
    var read_len: usize = undefined;
    const err: [*c][*c]u8 = null;
    const key_bytes = std.mem.asBytes(&page_id);
    const read_buf = c.rocksdb_get(
        self.db,
        self.read_opts,
        key_bytes,
        key_bytes.len,
        &read_len,
        err,
    );
    if (err != null) {
        std.debug.print("Get error: {s}\n", .{err});
        return err.RocksDBGetError;
    }
    defer c.rocksdb_free(read_buf);
    if (read_len == 0) return null;
    return try serde.deserialize(Page, allocator, read_buf[0..read_len]);
}
