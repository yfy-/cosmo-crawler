const std = @import("std");
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

const HTMLStripper = struct {
    const Self = @This();
    const HTMLError = error{
        HTMLParseError,
        HTMLAttrValQuoteErr,
        HTMLAttrWithoutTag,
        HTMLWhitespaceBeforeTag,
        HTMLUnmatchedTag,
    };
    const Error = Allocator.Error || HTMLError;
    const IgnoreTags = std.StaticStringMap(void).initComptime(.{
        .{"head"},   .{"meta"},   .{"title"},    .{"base"},     .{"link"},
        .{"style"},  .{"script"}, .{"noscript"}, .{"template"}, .{"slot"},
        .{"iframe"}, .{"area"},   .{"track"},    .{"colgroup"}, .{"br"},
        .{"hr"},     .{"img"},    .{"wbr"},
    });

    allocator: Allocator,
    links: ArrayList([]u8),

    _stack: ArrayList([]u8),
    _state: *const fn (*Self, u8, *CharList) Error!bool = _content,
    _tag_buffer: CharList,
    _attr_key_buffer: CharList,
    _attr_val_buffer: CharList,
    _attr_val_quote: ?u8 = null,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            ._stack = ArrayList([]u8).init(allocator),
            .links = ArrayList([]u8).init(allocator),
            ._tag_buffer = CharList.init(allocator),
            ._attr_key_buffer = CharList.init(allocator),
            ._attr_val_buffer = CharList.init(allocator),
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
    }

    /// Strip given html. Returned slice is owned by the caller.
    pub fn strip(self: *Self, html: []const u8) ![]const u8 {
        // Clear stack and links.
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

        var stripped = CharList.init(self.allocator);
        var i: usize = 0;
        while (i < html.len) {
            if (self._state(self, html[i], &stripped)) |skip| {
                if (skip) i += 1;
            } else |err| {
                std.debug.print(
                    "Error {} at {s} with '{c}'\n",
                    .{
                        err,
                        html[@max(0, i - 40)..@min(i + 41, html.len - 1)],
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

    fn _content(self: *Self, c: u8, content: *CharList) Error!bool {
        if (c == '<') {
            self._state = _tag;
        } else if (self._stack.getLastOrNull()) |tag| {
            if (!IgnoreTags.has(tag)) try appendChar(content, c);
        }

        return true;
    }

    fn _tag(self: *Self, c: u8, content: *CharList) Error!bool {
        _ = content;
        if (isASCIIWhite(c)) return error.HTMLWhitespaceBeforeTag;

        if (c == '/') {
            self._state = _tagEnd;
            return true;
        }

        self._state = _tagStart;
        return false;
    }

    fn _tagStart(self: *Self, c: u8, content: *CharList) Error!bool {
        _ = content;
        if (isASCIIWhite(c) or c == '>') {
            const tag = try self._tag_buffer.toOwnedSlice();
            try self._stack.append(tag);
            self._state = _tagStartFound;
            return c != '>';
        }

        try self._tag_buffer.append(c);
        return true;
    }

    fn _tagStartFound(self: *Self, c: u8, content: *CharList) Error!bool {
        _ = content;
        if (isASCIIWhite(c)) return true;
        if (c == '/') {
            self._state = _tagEndFound;
            return true;
        }

        if (c == '>') {
            self._state = _content;
            return true;
        }

        self._state = _attrKey;
        return false;
    }

    fn _tagEnd(self: *Self, c: u8, content: *CharList) Error!bool {
        _ = content;
        if (isASCIIWhite(c) or c == '>') {
            self._state = _tagEndFound;
            return c != '>';
        }

        try self._tag_buffer.append(c);
        return true;
    }

    fn _tagEndFound(self: *Self, c: u8, content: *CharList) Error!bool {
        if (isASCIIWhite(c)) return true;
        if (c == '>') {
            defer self._tag_buffer.clearAndFree();
            // NOTE: If tag buffer is empty then we have html like:
            // <link ... /> that ends with '/'. We don't need to
            // search for it in the stack. Instead we can just pop the
            // stack and remove it.
            if (self._tag_buffer.items.len > 0) {
                while (self._stack.popOrNull()) |tag| {
                    defer self.allocator.free(tag);
                    if (std.mem.eql(u8, tag, self._tag_buffer.items)) break;
                } else {
                    std.debug.print("Unmatched tag: '{s}'\n", .{self._tag_buffer.items});
                    return error.HTMLUnmatchedTag;
                }
            } else {
                self.allocator.free(self._stack.pop());
            }

            self._state = _content;
            try appendChar(content, ' ');
            return true;
        }

        return error.HTMLParseError;
    }

    fn _attrKey(self: *Self, c: u8, content: *CharList) Error!bool {
        _ = content;
        if (c == '=') {
            self._state = _attrVal;
            return true;
        }

        if (c == '>') {
            self._attr_key_buffer.clearAndFree();
            self._state = _content;
            return true;
        }

        if (!isASCIIWhite(c)) try self._attr_key_buffer.append(c);
        return true;
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

    fn _attrVal(self: *Self, c: u8, content: *CharList) Error!bool {
        _ = content;
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
                    self._state = _attrKey;
                }
            } else if (c == '"' or c == '\'') {
                if (self._attr_val_buffer.items.len > 0) {
                    return error.HTMLAttrValQuoteErr;
                }

                self._attr_val_quote = c;
            } else if (c == '>') {
                try self._helperAttrValEnd();
                self._state = _tagStartFound;
                return false;
            } else {
                try self._attr_val_buffer.append(c);
            }
        }

        return true;
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
        "<div><h1>Title</h1><p>Paragraph with <a href=\"http://wiki\">link</a>." ++
            "</p></div>",
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() == .leak) @panic("mem leak");
    }

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();
    const fname = args.next().?;

    const hfile = try std.fs.cwd().openFile(fname, .{});
    defer hfile.close();

    const html_text = try hfile.readToEndAlloc(allocator, 5 * 1024 * 1024);
    defer allocator.free(html_text);

    var stripper = HTMLStripper.init(allocator);
    defer stripper.deinit();

    const html_cont = try stripper.strip(html_text);
    defer allocator.free(html_cont);
    // for (stripper.links.items) |link| {
    //     std.debug.print("Link: {s}\n", .{link});
    // }

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(html_cont);
}
