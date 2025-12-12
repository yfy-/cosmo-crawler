const std = @import("std");

const c = @cImport({
    @cInclude("rocksdb/c.h");
});

const Self = @This();
// db_path: [*c]const u8,
db: *c.rocksdb_t = undefined,
db_opts: *c.rocksdb_options_t = null,
write_opts: *c.rocksdb_writeoptions_t = null,
read_opts: *c.rocksdb_readoptions_t = null,

const PageMeta = struct {
    last_crawled: u64,
    etag_fp: u64,
    crawl_period: u32,
    url: []u8,

    pub fn serialize(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        const sz_last = @sizeOf(@TypeOf(self.last_crawled));
        const sz_etag = @sizeOf(@TypeOf(self.etag_fp));
        const sz_period = @sizeOf(@TypeOf(self.crawl_period));
        const sz_page = sz_last + sz_etag + sz_period + self.url.len;
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

pub fn set_page(self: Self) !u128 {
    const key = "erman";
    const value = "yafay";
    c.rocksdb_put(
        self.db,
        self.write_opts,
        @ptrCast(key.ptr),
        key.len,
        @ptrCast(value.ptr),
        value.len,
        err,
    );
    if (err != null) {
        std.debug.print("Put error: {s}", .{err});
        return err.PutError;
    }
}

pub fn get_page(self: Self, page_id: u128) !PageMeta {
    var read_len: usize = undefined;
    const read_value = c.rocksdb_get(db, read_opts, @ptrCast(key.ptr), key.len, &read_len, err);
    if (err != null) {
        std.debug.print("Get error: {s}", .{err});
        return err.GetError;
    }
    defer c.rocksdb_free(read_value);
}
