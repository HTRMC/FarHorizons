const std = @import("std");

pub const MAX_ATTRS = 32;

pub const EventKind = enum {
    open_tag,
    close_tag,
    self_closing,
};

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const XmlEvent = struct {
    kind: EventKind,
    tag: []const u8,
    attrs: [MAX_ATTRS]Attr = undefined,
    attr_count: u8 = 0,

    pub fn getAttr(self: *const XmlEvent, name: []const u8) ?[]const u8 {
        for (self.attrs[0..self.attr_count]) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }
};

pub const XmlParser = struct {
    source: []const u8,
    pos: usize,

    pub fn init(source: []const u8) XmlParser {
        return .{ .source = source, .pos = 0 };
    }

    pub fn next(self: *XmlParser) ?XmlEvent {
        while (self.pos < self.source.len and self.source[self.pos] != '<') {
            self.pos += 1;
        }
        if (self.pos >= self.source.len) return null;
        self.pos += 1;
        if (self.pos >= self.source.len) return null;

        if (self.pos + 2 < self.source.len and
            self.source[self.pos] == '!' and
            self.source[self.pos + 1] == '-' and
            self.source[self.pos + 2] == '-')
        {
            self.pos += 3;
            while (self.pos + 2 < self.source.len) {
                if (self.source[self.pos] == '-' and
                    self.source[self.pos + 1] == '-' and
                    self.source[self.pos + 2] == '>')
                {
                    self.pos += 3;
                    return self.next();
                }
                self.pos += 1;
            }
            self.pos = self.source.len;
            return null;
        }

        if (self.source[self.pos] == '?') {
            while (self.pos + 1 < self.source.len) {
                if (self.source[self.pos] == '?' and self.source[self.pos + 1] == '>') {
                    self.pos += 2;
                    return self.next();
                }
                self.pos += 1;
            }
            self.pos = self.source.len;
            return null;
        }

        if (self.source[self.pos] == '/') {
            self.pos += 1;
            self.skipWhitespace();
            const tag = self.readName();
            self.skipTo('>');
            if (self.pos < self.source.len) self.pos += 1;
            return .{ .kind = .close_tag, .tag = tag };
        }

        self.skipWhitespace();
        const tag = self.readName();

        var event = XmlEvent{ .kind = .open_tag, .tag = tag };

        while (self.pos < self.source.len) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) break;

            if (self.source[self.pos] == '>') {
                self.pos += 1;
                return event;
            }
            if (self.source[self.pos] == '/' and
                self.pos + 1 < self.source.len and
                self.source[self.pos + 1] == '>')
            {
                self.pos += 2;
                event.kind = .self_closing;
                return event;
            }

            const attr_name = self.readName();
            if (attr_name.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.source.len and self.source[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const attr_value = self.readQuotedValue();
                if (event.attr_count < MAX_ATTRS) {
                    event.attrs[event.attr_count] = .{ .name = attr_name, .value = attr_value };
                    event.attr_count += 1;
                }
            }
        }

        return event;
    }

    fn skipWhitespace(self: *XmlParser) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    fn skipTo(self: *XmlParser, ch: u8) void {
        while (self.pos < self.source.len and self.source[self.pos] != ch) {
            self.pos += 1;
        }
    }

    fn readName(self: *XmlParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and isNameChar(self.source[self.pos])) {
            self.pos += 1;
        }
        return self.source[start..self.pos];
    }

    fn readQuotedValue(self: *XmlParser) []const u8 {
        if (self.pos >= self.source.len) return "";
        const quote = self.source[self.pos];
        if (quote != '"' and quote != '\'') return "";
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != quote) {
            self.pos += 1;
        }
        const value = self.source[start..self.pos];
        if (self.pos < self.source.len) self.pos += 1;
        return value;
    }

    fn isNameChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.' or c == ':';
    }
};


test "self-closing tags" {
    var parser = XmlParser.init("<br/><img src=\"test\"/>");

    const e1 = parser.next().?;
    try std.testing.expectEqualStrings("br", e1.tag);
    try std.testing.expectEqual(EventKind.self_closing, e1.kind);
    try std.testing.expectEqual(@as(u8, 0), e1.attr_count);

    const e2 = parser.next().?;
    try std.testing.expectEqualStrings("img", e2.tag);
    try std.testing.expectEqual(EventKind.self_closing, e2.kind);
    try std.testing.expectEqualStrings("test", e2.getAttr("src").?);

    try std.testing.expect(parser.next() == null);
}

test "nested elements" {
    var parser = XmlParser.init("<root><child>text</child></root>");

    const e1 = parser.next().?;
    try std.testing.expectEqualStrings("root", e1.tag);
    try std.testing.expectEqual(EventKind.open_tag, e1.kind);

    const e2 = parser.next().?;
    try std.testing.expectEqualStrings("child", e2.tag);
    try std.testing.expectEqual(EventKind.open_tag, e2.kind);

    const e3 = parser.next().?;
    try std.testing.expectEqualStrings("child", e3.tag);
    try std.testing.expectEqual(EventKind.close_tag, e3.kind);

    const e4 = parser.next().?;
    try std.testing.expectEqualStrings("root", e4.tag);
    try std.testing.expectEqual(EventKind.close_tag, e4.kind);

    try std.testing.expect(parser.next() == null);
}

test "attributes" {
    var parser = XmlParser.init(
        \\<panel width="320" height="auto" background="#1A1A2ECC"/>
    );

    const e = parser.next().?;
    try std.testing.expectEqualStrings("panel", e.tag);
    try std.testing.expectEqual(@as(u8, 3), e.attr_count);
    try std.testing.expectEqualStrings("320", e.getAttr("width").?);
    try std.testing.expectEqualStrings("auto", e.getAttr("height").?);
    try std.testing.expectEqualStrings("#1A1A2ECC", e.getAttr("background").?);
    try std.testing.expect(e.getAttr("nonexistent") == null);
}

test "comments and PIs are skipped" {
    var parser = XmlParser.init("<?xml version=\"1.0\"?><!-- comment --><root/>");

    const e = parser.next().?;
    try std.testing.expectEqualStrings("root", e.tag);
    try std.testing.expectEqual(EventKind.self_closing, e.kind);

    try std.testing.expect(parser.next() == null);
}
