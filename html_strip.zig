const std = @import("std");
const fs = std.fs;
const character_entity = @import("character_entity.zig");

const isASCIIWhite = character_entity.isASCIIWhite;
const EntityAutoTranslator = character_entity.AutoTranslator;
const ArrayList = std.ArrayList;
const CharList = std.ArrayList(u8);
const Allocator = std.mem.Allocator;

pub const HTMLStripper = struct {
    const Self = @This();
    const HTMLError = error{
        HTMLParseError,
        HTMLAttrValQuoteErr,
        HTMLAttrWithoutTag,
        HTMLWhitespaceBeforeTag,
        HTMLUnmatchedTag,
        HTMLNoTag,
    };
    const Error = Allocator.Error || HTMLError || character_entity.Error;

    /// Tags that can end without the associated closing tag.
    const VoidTags = std.StaticStringMap(void).initComptime(.{
        .{"area"},  .{"base"}, .{"br"},    .{"col"},    .{"command"},
        .{"embed"}, .{"hr"},   .{"img"},   .{"input"},  .{"keygen"},
        .{"link"},  .{"meta"}, .{"param"}, .{"source"}, .{"track"},
        .{"wbr"},   .{"!--"},
    });

    /// Tags that don't interest humans.
    const IgnoreTags = std.StaticStringMap(void).initComptime(.{
        .{"script"}, .{"style"},
    });

    /// Tags that < and > can appear.
    const AngleBracketTags = std.StaticStringMap(void).initComptime(.{
        .{"title"}, .{"textarea"}, .{"script"}, .{"style"},
    });

    /// Tags that start a new line. 'br' is actually inline but since
    /// it specially inserts a new line to the rendered output we
    /// store it here.
    const BlockLevelTags = std.StaticStringMap(void).initComptime(.{
        .{"address"}, .{"article"},  .{"aside"},      .{"blockquote"},
        .{"canvas"},  .{"dd"},       .{"div"},        .{"dl"},
        .{"dt"},      .{"fieldset"}, .{"figcaption"}, .{"figure"},
        .{"footer"},  .{"form"},     .{"header"},     .{"hr"},
        .{"li"},      .{"main"},     .{"nav"},        .{"noscript"},
        .{"ol"},      .{"p"},        .{"pre"},        .{"section"},
        .{"table"},   .{"tfoot"},    .{"ul"},         .{"vide"},
        .{"h1"},      .{"h2"},       .{"h3"},         .{"h4"},
        .{"h5"},      .{"h6"},       .{"br"},
    });

    allocator: Allocator,
    links: ArrayList([]u8),

    _stack: ArrayList([]u8),
    _state: *const fn (
        *Self,
        []const u8,
        *EntityAutoTranslator,
    ) Error!usize = _beg,
    _tag_buffer: CharList,
    _attr_key_buffer: CharList,
    _attr_val_buffer: EntityAutoTranslator,
    _attr_val_quote: ?u8 = null,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            ._stack = ArrayList([]u8){},
            .links = ArrayList([]u8){},
            ._tag_buffer = CharList{},
            ._attr_key_buffer = CharList{},
            ._attr_val_buffer = EntityAutoTranslator.init(
                allocator,
                false,
            ),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self._stack.items) |item| {
            self.allocator.free(item);
        }
        self._stack.deinit(self.allocator);

        for (self.links.items) |item| {
            self.allocator.free(item);
        }
        self.links.deinit(self.allocator);

        self._tag_buffer.deinit(self.allocator);
        self._attr_key_buffer.deinit(self.allocator);
        self._attr_val_buffer.deinit();
    }

    pub fn clearAndFree(self: *Self) void {
        for (self._stack.items) |item| {
            self.allocator.free(item);
        }
        self._stack.clearAndFree(self.allocator);

        for (self.links.items) |item| {
            self.allocator.free(item);
        }
        self.links.clearAndFree(self.allocator);
        self._tag_buffer.clearAndFree(self.allocator);
        self._attr_key_buffer.clearAndFree(self.allocator);
        self._attr_val_buffer.clearAndFree();
        self._state = _beg;
    }

    /// Strip given html. Returned slice is owned by the caller.
    pub fn strip(self: *Self, html: []const u8) ![]u8 {
        // Clear stack and links.
        self.clearAndFree();

        var stripped = EntityAutoTranslator.init(self.allocator, true);
        errdefer stripped.deinit();
        var i: usize = 0;
        while (i < html.len) {
            if (self._state(self, html[i..], &stripped)) |skip| {
                i += skip;
            } else |err| {
                std.log.err(
                    "Error {} at {s} with '{c}' at index '{d}'",
                    .{
                        err,
                        html[@max(0, i -| 100)..@min(i +| 101, html.len - 1)],
                        html[i],
                        i,
                    },
                );
                return err;
            }
        }

        if (stripped.translated.getLastOrNull()) |last_c| {
            if (isASCIIWhite(last_c)) {
                stripped.translated.shrinkAndFree(
                    self.allocator,
                    stripped.translated.items.len - 1,
                );
            }
        }

        return try stripped.toOwnedSlice();
    }

    fn _beg(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
        _ = content;
        const c = html[0];
        if (c == '<') self._state = _tag;
        return 1;
    }

    fn _content(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
        const c = html[0];
        if (self._stack.getLastOrNull()) |tag| {
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
                    try self._tag_buffer.appendSlice(self.allocator, tag);
                    self._state = _tagEndFound;
                    return tag_end_size;
                }
            }

            if (IgnoreTags.has(tag))
                return 1;

            // Swap new lines with ordinary spaces since new lines can
            // only be inserted with BlockLevelTags.
            if (c == '\n' or c == '\r') {
                try content.append(' ');
            } else {
                try content.append(c);
            }

            return 1;
        } else {
            return HTMLError.HTMLNoTag;
        }
    }

    fn _tag(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
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
        content: *EntityAutoTranslator,
    ) Error!usize {
        _ = content;
        const c = html[0];
        // Handle comments below
        if (html.len > 2 and std.mem.eql(u8, html[0..3], "!--")) {
            self._tag_buffer.clearAndFree(self.allocator);
            self._state = _comment;
            return 3;
        }

        if (isASCIIWhite(c) or c == '>' or c == '/') {
            const tag = try self._tag_buffer.toOwnedSlice(self.allocator);
            try self._stack.append(self.allocator, tag);
            self._state = _tagStartFound;
            return if (isASCIIWhite(c)) 1 else 0;
        }

        try self._tag_buffer.append(self.allocator, c);
        return 1;
    }

    fn _tagStartFound(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
        if (BlockLevelTags.has(self._stack.getLast())) {
            try content.append('\n');
        }

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

    fn _tagEnd(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
        _ = content;
        const c = html[0];
        if (isASCIIWhite(c) or c == '>') {
            self._state = _tagEndFound;
            return if (c == '>') 0 else 1;
        }

        try self._tag_buffer.append(self.allocator, c);
        return 1;
    }

    fn unmatchedTag(self: *Self) void {
        var found_idx = self._stack.items.len;
        while (found_idx > 0) : (found_idx -= 1) {
            if (std.mem.eql(
                u8,
                self._tag_buffer.items,
                self._stack.items[found_idx - 1],
            )) {
                self.allocator.free(self._stack.orderedRemove(found_idx - 1));
                std.log.warn(
                    "Found matching tag at: {}",
                    .{found_idx - 1},
                );
                return;
            }
        }

        std.log.warn("Stray tag.", .{});
    }

    fn _tagEndFound(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
        _ = content;
        const c = html[0];
        if (isASCIIWhite(c)) return 1;
        if (c == '>') {
            defer self._tag_buffer.clearAndFree(self.allocator);
            if (self._stack.getLastOrNull()) |tag| {
                if (self._tag_buffer.items.len > 0 and
                    !std.mem.eql(u8, tag, self._tag_buffer.items))
                {
                    std.log.warn(
                        "Unmatched tag: '{s}'",
                        .{self._tag_buffer.items},
                    );
                    self.unmatchedTag();
                } else {
                    _ = self._stack.pop();
                    self.allocator.free(tag);
                }

                self._state = _content;
                return 1;
            }

            std.log.err(
                "Unmatched tag: '{s}'",
                .{self._tag_buffer.items},
            );
            return error.HTMLUnmatchedTag;
        }

        return error.HTMLParseError;
    }

    fn _attrKey(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
        _ = content;
        const c = html[0];
        if (c == '=') {
            self._state = _attrVal;
            return 1;
        }

        if (c == '>') {
            self._attr_key_buffer.clearAndFree(self.allocator);
            self._state = _tagStartFound;
            return 0;
        }

        if (!isASCIIWhite(c)) try self._attr_key_buffer.append(self.allocator, c);
        return 1;
    }

    fn _helperAttrValEnd(self: *Self) !void {
        defer self._attr_val_buffer.clearAndFree();
        defer self._attr_key_buffer.clearAndFree(self.allocator);

        if (self._stack.items.len == 0) return error.HTMLAttrWithoutTag;

        // Only discover links and clear key and val buffers afterwards.
        if (std.mem.eql(u8, self._stack.getLast(), "a") and
            std.mem.eql(u8, self._attr_key_buffer.items, "href"))
        {
            try self.links.append(self.allocator, try self._attr_val_buffer.toOwnedSlice());
        }
    }

    fn _attrVal(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
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
                if (self._attr_val_buffer.translated.items.len > 0) {
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

    fn _comment(
        self: *Self,
        html: []const u8,
        content: *EntityAutoTranslator,
    ) Error!usize {
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

const talloc = std.testing.allocator;

/// Check if stripped html_text is equal to expected.
fn expectHtmlStrip(expected: []const u8, html_text: []const u8) !HTMLStripper {
    var stripper = HTMLStripper.init(talloc);
    errdefer stripper.deinit();
    const actual = try stripper.strip(html_text);
    defer talloc.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    return stripper;
}

test "strip_html_very_simple" {
    var s = try expectHtmlStrip("erman", "<p> erman </p>");
    s.deinit();
}

test "strip_html_nested_simple" {
    var s = try expectHtmlStrip(
        "This is a simple example.",
        "<p>This is a <strong>simple</strong> example.</p>",
    );
    s.deinit();
}

test "strip_html_nested_link" {
    var s = try expectHtmlStrip(
        "Title\nParagraph with link.",
        \\<div><h1>Title</h1><p>Paragraph with <a href="http://wiki">link</a>.
        \\</p></div>
        ,
    );
    defer s.deinit();
    try std.testing.expectEqualSlices(u8, "http://wiki", s.links.items[0]);
}

test "strip_html_nested_list" {
    var s = try expectHtmlStrip(
        "Item 1\nItem 2 with emphasis\nItem 3",
        \\<ul>
        \\  <li>Item 1</li>
        \\  <li>Item 2 with <em>emphasis</em></li>
        \\  <li>Item 3</li>
        \\</ul>
        ,
    );
    defer s.deinit();
}

test "strip_html_link_with_entity" {
    var s = try expectHtmlStrip(
        "Title\nParagraph with link.",
        \\<div><h1>Title</h1><p>Paragraph with <a href="http://wiki&amp;">
        \\link</a>.</p></div>
        ,
    );
    defer s.deinit();
    try std.testing.expectEqualSlices(u8, "http://wiki&", s.links.items[0]);
}

test "strip_html_void_tags" {
    const html =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<title>Simple HTML Example</title>
        \\</head>
        \\<body>
        \\<div>
        \\<h1>Welcome</h1>
        \\<p>This paragraph contains an image:
        \\<img src="example.jpg" alt="Example Image">
        \\</p>
        \\<div>
        \\<p>
        \\Here is a line break after this sentence:<br>
        \\And here is the next line.
        \\</p>
        \\<hr>
        \\<p>Enter your name:
        \\<input type="text" placeholder="Name">
        \\</p>
        \\</div>
        \\</div>
        \\</body>
        \\</html>
    ;
    const exp = "Simple HTML Example\nWelcome\nThis paragraph contains an " ++
        "image:\nHere is a line break after this sentence:\nAnd here is the " ++
        "next line.\nEnter your name:";
    var s = try expectHtmlStrip(exp, html);
    s.deinit();
}

test "strip_html_ignore_tags_comment" {
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<meta charset="UTF-8">
        \\<title>Short &lt; &gt;</title>
        \\<style>
        \\body { font-family: Arial; }
        \\</style>
        \\</head>
        \\<body>
        \\<!-- A simple comment -->
        \\<!-- <p>This is a valid HTML snippet inside a comment.</p> -->
        \\<h1>Hi! &#x00A8; </h1>
        \\<script>
        \\alert('Hello!');
        \\</script>
        \\</body>
        \\</html>
    ;
    const exp = "Short < >\nHi! ¨";
    var s = try expectHtmlStrip(exp, html);
    s.deinit();
}

test "strip_html_weird_unmatching" {
    var s = try expectHtmlStrip(
        "12345",
        "<p>1<b>2<i>3</b>4</i>5</p>",
    );
    s.deinit();
}

fn expectHtmlStripFile(comptime file_base: []const u8) !void {
    const src_dir = fs.path.dirname(@src().file) orelse "";
    const resource_dir = try fs.path.join(
        talloc,
        &[_][]const u8{ src_dir, "test-resource", "html-strip" },
    );
    defer talloc.free(resource_dir);

    // Read html file
    const html_path = try fs.path.join(
        talloc,
        &[_][]const u8{ resource_dir, file_base ++ ".html" },
    );
    defer talloc.free(html_path);

    const html_file = try fs.cwd().openFile(html_path, .{});
    defer html_file.close();

    const html = try html_file.readToEndAlloc(
        talloc,
        5 * 1024 * 1024,
    );
    defer talloc.free(html);

    // Read text file
    const text_path = try fs.path.join(
        talloc,
        &[_][]const u8{ resource_dir, file_base ++ ".txt" },
    );
    defer talloc.free(text_path);

    const text_file = try fs.cwd().openFile(text_path, .{});
    defer text_file.close();

    const text = try text_file.readToEndAlloc(
        talloc,
        5 * 1024 * 1024,
    );
    defer talloc.free(text);

    var s = try expectHtmlStrip(text, html);
    s.deinit();
}

test "integration_mygithub" {
    try expectHtmlStripFile("mygithub");
}

test "integration_w3c" {
    try expectHtmlStripFile("w3c");
}

test "integration_vertex_cover" {
    try expectHtmlStripFile("vertex_cover");
}
