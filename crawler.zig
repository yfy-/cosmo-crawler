const std = @import("std");
const CharList = std.ArrayList(u8);
const Allocator = std.mem.Allocator;

fn isASCIIWhite(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Append char to list, effectively ignoring excess white-space.
fn appendChar(list: *CharList, c: u8) !void {
    if (!isASCIIWhite(c)) {
        try list.append(c);
        return;
    }

    if (list.getLastOrNull()) |last_c| {
        if (!isASCIIWhite(last_c)) try list.append(c);
    }
}

/// Remove tags form the given html. Note that output needs to be
/// de-allocated by the caller.
pub fn stripHtml(
    allocator: Allocator,
    html_text: []const u8,
) ![]u8 {
    var stripped = CharList.init(allocator);
    var in_tag = false;
    for (html_text) |c| {
        if (c == '<') {
            if (in_tag) {
                stripped.deinit();
                return error.InvalidHtml;
            }

            in_tag = true;
        } else if (c == '>') {
            if (!in_tag) {
                stripped.deinit();
                return error.InvalidHtml;
            }

            in_tag = false;
            try appendChar(&stripped, ' ');
        } else if (!in_tag) {
            try appendChar(&stripped, c);
        }
    }

    if (stripped.getLastOrNull()) |last_c| {
        if (isASCIIWhite(last_c)) {
            stripped.shrinkAndFree(stripped.items.len - 1);
        }
    }

    return stripped.allocatedSlice();
}

/// Check if stripped html_text is equal to expected.
fn expectHtmlStrip(expected: []const u8, html_text: []const u8) !void {
    const actual = try stripHtml(
        std.testing.allocator,
        html_text,
    );
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "strip_html simple" {
    try expectHtmlStrip("erman", "<p> erman </p>");
}

test "strip_html simple nested" {
    try expectHtmlStrip(
        "This is a simple example.",
        "<p>This is a <strong>simple</strong> example.</p>",
    );
}

test "strip_html href" {
    try expectHtmlStrip(
        "Title Paragraph with link .",
        "<div><h1>Title</h1><p>Paragraph with <a href=\"#\">link</a>." ++
            "</p></div>",
    );
}

test "strip_html list" {
    try expectHtmlStrip(
        "Item 1 Item 2 with emphasis Item 3",
        \\<ul>
        \\  <li>Item 1</li>
        \\  <li>Item 2 with <em>emphasis</em></li>
        \\  <li>Item 3</li>
        \\</ul>
        ,
    );
}

pub fn main() !void {
    const str = "hello";
    for (str, 0..) |_, i| {
        std.debug.print("{d}", .{i});
    }
}
