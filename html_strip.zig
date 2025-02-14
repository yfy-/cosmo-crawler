const std = @import("std");

const character_entity = @import("character_entity.zig");
const ArrayList = std.ArrayList;
const CharList = std.ArrayList(u8);
const Allocator = std.mem.Allocator;

fn isASCIIWhite(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// Append char to list effectively ignoring excess white-space.
fn appendChar(list: *CharList, c: u8) !void {
    if (!isASCIIWhite(c)) {
        try list.append(c);
        return;
    }

    if (list.getLastOrNull()) |last_c| {
        if (!isASCIIWhite(last_c)) try list.append(c);
    }
}

pub const HTMLStripper = struct {
    const Self = @This();
    const HTMLError = error{
        HTMLParseError,
        HTMLAttrValQuoteErr,
        HTMLAttrWithoutTag,
        HTMLWhitespaceBeforeTag,
        HTMLUnmatchedTag,
    };
    const Error = Allocator.Error || HTMLError || character_entity.Error;
    const VoidTags = std.StaticStringMap(void).initComptime(.{
        .{"area"},  .{"base"}, .{"br"},    .{"col"},    .{"command"},
        .{"embed"}, .{"hr"},   .{"img"},   .{"input"},  .{"keygen"},
        .{"link"},  .{"meta"}, .{"param"}, .{"source"}, .{"track"},
        .{"wbr"},   .{"!--"},
    });
    const IgnoreTags = std.StaticStringMap(void).initComptime(.{
        .{"script"}, .{"style"},
    });
    const AngleBracketTags = std.StaticStringMap(void).initComptime(.{
        .{"title"}, .{"textarea"}, .{"script"}, .{"style"},
    });

    allocator: Allocator,
    links: ArrayList([]u8),

    _stack: ArrayList([]u8),
    _state: *const fn (*Self, []const u8, *CharList) Error!usize = _beg,
    _tag_buffer: CharList,
    _attr_key_buffer: CharList,
    _attr_val_buffer: CharList,
    _entity_buffer: CharList,
    _in_entity: bool = false,
    _attr_val_quote: ?u8 = null,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            ._stack = ArrayList([]u8).init(allocator),
            .links = ArrayList([]u8).init(allocator),
            ._tag_buffer = CharList.init(allocator),
            ._attr_key_buffer = CharList.init(allocator),
            ._attr_val_buffer = CharList.init(allocator),
            ._entity_buffer = CharList.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self._stack.items) |item| {
            self.allocator.free(item);
        }
        self._stack.deinit();

        for (self.links.items) |item| {
            self.allocator.free(item);
        }
        self.links.deinit();

        self._tag_buffer.deinit();
        self._attr_key_buffer.deinit();
        self._attr_val_buffer.deinit();
        self._entity_buffer.deinit();
    }

    pub fn clear(self: *Self) void {
        for (self._stack.items) |item| {
            self.allocator.free(item);
        }
        self._stack.clearAndFree();

        for (self.links.items) |item| {
            self.allocator.free(item);
        }
        self.links.clearAndFree();
        self._tag_buffer.clearAndFree();
        self._attr_key_buffer.clearAndFree();
        self._attr_val_buffer.clearAndFree();
        self._entity_buffer.clearAndFree();
    }

    /// Strip given html. Returned slice is owned by the caller.
    pub fn strip(self: *Self, html: []const u8) ![]const u8 {
        // Clear stack and links.
        self.clear();

        var stripped = CharList.init(self.allocator);
        errdefer stripped.deinit();
        var i: usize = 0;
        while (i < html.len) {
            if (self._state(self, html[i..], &stripped)) |skip| {
                i += skip;
            } else |err| {
                std.debug.print(
                    "Error {} at {s} with '{c}'\n",
                    .{
                        err,
                        html[@max(0, i - 100)..@min(i + 101, html.len - 1)],
                        html[i],
                    },
                );
                return err;
            }
        }

        if (stripped.getLastOrNull()) |last_c| {
            if (isASCIIWhite(last_c)) {
                stripped.shrinkAndFree(stripped.items.len - 1);
            }
        }

        return try stripped.toOwnedSlice();
    }

    fn _beg(self: *Self, html: []const u8, content: *CharList) Error!usize {
        _ = content;
        const c = html[0];
        if (c == '<') self._state = _tag;
        return 1;
    }

    fn _content(self: *Self, html: []const u8, content: *CharList) Error!usize {
        const c = html[0];
        const tag = self._stack.getLastOrNull().?;
        if (c == '<') {
            if (!AngleBracketTags.has(tag)) {
                self._state = _tag;
                return 1;
            }

            const tag_end_size = tag.len + 2;
            if (html.len < tag_end_size) return error.HTMLParseError;
            if (html[1] == '/' and
                std.mem.eql(u8, tag, html[2..tag_end_size]))
            {
                try self._tag_buffer.appendSlice(tag);
                self._state = _tagEndFound;
                return tag_end_size;
            }
        }

        if (IgnoreTags.has(tag))
            return 1;

        if (!self._in_entity and c == '&') {
            self._in_entity = true;
            return 1;
        }

        if (self._in_entity and c == ';') {
            defer self._entity_buffer.clearAndFree();
            self._in_entity = false;
            const trans = try character_entity.translate_entity(
                self._entity_buffer.items,
                self.allocator,
            );
            defer self.allocator.free(trans);
            try content.appendSlice(trans);
            return 1;
        }

        if (self._in_entity) {
            try self._entity_buffer.append(c);
            return 1;
        }

        try appendChar(content, c);
        return 1;
    }

    fn _tag(self: *Self, html: []const u8, content: *CharList) Error!usize {
        _ = content;
        const c = html[0];
        if (isASCIIWhite(c)) return error.HTMLWhitespaceBeforeTag;

        if (c == '/') {
            self._state = _tagEnd;
            return 1;
        }

        self._state = _tagStart;
        return 0;
    }

    fn _tagStart(
        self: *Self,
        html: []const u8,
        content: *CharList,
    ) Error!usize {
        _ = content;
        const c = html[0];
        // Handle comments below
        if (html.len > 2 and std.mem.eql(u8, html[0..3], "!--")) {
            self._tag_buffer.clearAndFree();
            self._state = _comment;
            return 3;
        }

        if (isASCIIWhite(c) or c == '>' or c == '/') {
            const tag = try self._tag_buffer.toOwnedSlice();
            // std.debug.print("pushing {s}\n", .{tag});
            try self._stack.append(tag);
            self._state = _tagStartFound;
            return if (isASCIIWhite(c)) 1 else 0;
        }

        try self._tag_buffer.append(c);
        return 1;
    }

    fn _tagStartFound(
        self: *Self,
        html: []const u8,
        content: *CharList,
    ) Error!usize {
        _ = content;
        const c = html[0];
        if (isASCIIWhite(c)) return 1;
        if (c == '/') {
            self._state = _tagEndFound;
            return 1;
        }

        if (c == '>') {
            if (VoidTags.has(self._stack.getLast())) {
                self._state = _tagEndFound;
                return 0;
            }

            self._state = _content;
            return 1;
        }

        self._state = _attrKey;
        return 0;
    }

    fn _tagEnd(self: *Self, html: []const u8, content: *CharList) Error!usize {
        _ = content;
        const c = html[0];
        if (isASCIIWhite(c) or c == '>') {
            self._state = _tagEndFound;
            return if (c == '>') 0 else 1;
        }

        try self._tag_buffer.append(c);
        return 1;
    }

    fn _tagEndFound(
        self: *Self,
        html: []const u8,
        content: *CharList,
    ) Error!usize {
        const c = html[0];
        if (isASCIIWhite(c)) return 1;
        if (c == '>') {
            defer self._tag_buffer.clearAndFree();
            if (self._stack.popOrNull()) |tag| {
                // std.debug.print("popped {s}\n", .{tag});
                defer self.allocator.free(tag);
                if (self._tag_buffer.items.len > 0 and
                    !std.mem.eql(u8, tag, self._tag_buffer.items))
                {
                    std.debug.print(
                        "tag : '{s}', stack: '{s}'\n",
                        .{ self._tag_buffer.items, tag },
                    );
                    return error.HTMLUnmatchedTag;
                }

                self._state = _content;
                try appendChar(content, ' ');
                return 1;
            }

            std.debug.print(
                "Unmatched tag: '{s}'\n",
                .{self._tag_buffer.items},
            );
            return error.HTMLUnmatchedTag;
        }

        return error.HTMLParseError;
    }

    fn _attrKey(self: *Self, html: []const u8, content: *CharList) Error!usize {
        _ = content;
        const c = html[0];
        if (c == '=') {
            self._state = _attrVal;
            return 1;
        }

        if (c == '>') {
            self._attr_key_buffer.clearAndFree();
            self._state = _tagStartFound;
            return 0;
        }

        if (!isASCIIWhite(c)) try self._attr_key_buffer.append(c);
        return 1;
    }

    fn _helperAttrValEnd(self: *Self) !void {
        if (self._stack.items.len == 0) return error.HTMLAttrWithoutTag;

        // Only discover links and clear key and val buffers afterwards.
        if (std.mem.eql(u8, self._stack.getLast(), "a") and
            std.mem.eql(u8, self._attr_key_buffer.items, "href"))
        {
            try self.links.append(try self._attr_val_buffer.toOwnedSlice());
        }

        self._attr_key_buffer.clearAndFree();
        self._attr_val_buffer.clearAndFree();
    }

    fn _attrVal(self: *Self, html: []const u8, content: *CharList) Error!usize {
        _ = content;
        const c = html[0];
        if (self._attr_val_quote) |qc| {
            if (c == qc) {
                try self._helperAttrValEnd();
                self._state = _tagStartFound;
                self._attr_val_quote = null;
            } else {
                try self._attr_val_buffer.append(c);
            }
        } else {
            if (isASCIIWhite(c)) {
                if (self._attr_val_buffer.items.len > 0) {
                    try self._helperAttrValEnd();
                    self._state = _tagStartFound;
                }
            } else if (c == '"' or c == '\'') {
                self._attr_val_quote = c;
            } else if (c == '>') {
                try self._helperAttrValEnd();
                self._state = _tagStartFound;
                return 0;
            } else {
                try self._attr_val_buffer.append(c);
            }
        }

        return 1;
    }

    fn _comment(self: *Self, html: []const u8, content: *CharList) Error!usize {
        _ = content;

        // Immediately exit when '--' is seen. Process 3 chars because
        // '--' cannot occur without the final '>'.
        if (html.len > 1 and std.mem.eql(u8, html[0..2], "--")) {
            self._state = _content;
            return 3;
        }

        return 1;
    }
};

/// Check if stripped html_text is equal to expected.
fn expectHtmlStrip(expected: []const u8, html_text: []const u8) !HTMLStripper {
    var stripper = HTMLStripper.init(std.testing.allocator);
    const actual = try stripper.strip(html_text);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    return stripper;
}

test "stripHtml" {
    // Very simple.
    var s1 = try expectHtmlStrip("erman", "<p> erman </p>");
    defer s1.deinit();

    // Nested simple.
    var s2 = try expectHtmlStrip(
        "This is a simple example.",
        "<p>This is a <strong>simple</strong> example.</p>",
    );
    defer s2.deinit();

    // Nested link.
    var s3 = try expectHtmlStrip(
        "Title Paragraph with link .",
        \\<div><h1>Title</h1><p>Paragraph with <a href="http://wiki">link</a>.
        \\</p></div>
        ,
    );
    defer s3.deinit();
    try std.testing.expectEqualSlices(u8, "http://wiki", s3.links.items[0]);

    // Nested list.
    var s4 = try expectHtmlStrip(
        "Item 1 Item 2 with emphasis Item 3",
        \\<ul>
        \\  <li>Item 1</li>
        \\  <li>Item 2 with <em>emphasis</em></li>
        \\  <li>Item 3</li>
        \\</ul>
        ,
    );
    defer s4.deinit();
}
