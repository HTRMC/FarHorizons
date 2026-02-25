const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const MAX_WIDGETS = Widget.MAX_WIDGETS;
const WidgetData = @import("WidgetData.zig").WidgetData;
const WidgetKind = Widget.WidgetKind;

pub const WidgetTree = struct {
    widgets: [MAX_WIDGETS]Widget.Widget = [_]Widget.Widget{.{}} ** MAX_WIDGETS,
    data: [MAX_WIDGETS]WidgetData = [_]WidgetData{.{ .panel = .{} }} ** MAX_WIDGETS,
    count: WidgetId = 0,
    root: WidgetId = NULL_WIDGET,

    pub fn addWidget(self: *WidgetTree, kind: WidgetKind, parent: WidgetId) ?WidgetId {
        if (self.count >= MAX_WIDGETS) return null;

        const id = self.count;
        self.count += 1;

        self.widgets[id] = .{
            .kind = kind,
            .active = true,
            .parent = parent,
        };

        self.data[id] = switch (kind) {
            .panel => .{ .panel = .{} },
            .label => .{ .label = .{} },
            .button => .{ .button = .{} },
            .text_input => .{ .text_input = .{} },
            .image => .{ .image = .{} },
            .scroll_view => .{ .scroll_view = .{} },
            .list_view => .{ .list_view = .{} },
            .progress_bar => .{ .progress_bar = .{} },
            .checkbox => .{ .checkbox = .{} },
            .slider => .{ .slider = .{} },
            .grid => .{ .grid = .{} },
            .dropdown => .{ .dropdown = .{} },
        };

        // Set default focusability
        switch (kind) {
            .button, .text_input, .checkbox, .slider, .dropdown => self.widgets[id].focusable = true,
            else => {},
        }

        if (parent == NULL_WIDGET) {
            self.root = id;
        } else {
            // Append to parent's child list
            const p = &self.widgets[parent];
            if (p.first_child == NULL_WIDGET) {
                p.first_child = id;
            } else {
                var child = p.first_child;
                while (self.widgets[child].next_sibling != NULL_WIDGET) {
                    child = self.widgets[child].next_sibling;
                }
                self.widgets[child].next_sibling = id;
            }
        }

        return id;
    }

    pub fn getWidget(self: *WidgetTree, id: WidgetId) ?*Widget.Widget {
        if (id >= self.count) return null;
        if (!self.widgets[id].active) return null;
        return &self.widgets[id];
    }

    pub fn getData(self: *WidgetTree, id: WidgetId) ?*WidgetData {
        if (id >= self.count) return null;
        if (!self.widgets[id].active) return null;
        return &self.data[id];
    }

    pub fn getWidgetConst(self: *const WidgetTree, id: WidgetId) ?*const Widget.Widget {
        if (id >= self.count) return null;
        if (!self.widgets[id].active) return null;
        return &self.widgets[id];
    }

    pub fn getDataConst(self: *const WidgetTree, id: WidgetId) ?*const WidgetData {
        if (id >= self.count) return null;
        if (!self.widgets[id].active) return null;
        return &self.data[id];
    }

    pub fn findByIdHash(self: *const WidgetTree, hash: u32) ?WidgetId {
        for (0..self.count) |i| {
            const id: WidgetId = @intCast(i);
            if (self.widgets[id].active and self.widgets[id].id_hash == hash and hash != 0) {
                return id;
            }
        }
        return null;
    }

    pub fn findById(self: *const WidgetTree, id_str: []const u8) ?WidgetId {
        return self.findByIdHash(hashId(id_str));
    }

    pub fn clear(self: *WidgetTree) void {
        self.count = 0;
        self.root = NULL_WIDGET;
    }

    // ── Child iteration ──

    pub const ChildIterator = struct {
        tree: *const WidgetTree,
        current: WidgetId,

        pub fn next(self: *ChildIterator) ?WidgetId {
            if (self.current == NULL_WIDGET) return null;
            const id = self.current;
            self.current = self.tree.widgets[id].next_sibling;
            return id;
        }
    };

    pub fn children(self: *const WidgetTree, parent_id: WidgetId) ChildIterator {
        const w = self.getWidgetConst(parent_id) orelse return .{ .tree = self, .current = NULL_WIDGET };
        return .{
            .tree = self,
            .current = w.first_child,
        };
    }

    // Count direct children
    pub fn childCount(self: *const WidgetTree, parent_id: WidgetId) u16 {
        var iter = self.children(parent_id);
        var n: u16 = 0;
        while (iter.next() != null) n += 1;
        return n;
    }
};

pub fn hashId(id_str: []const u8) u32 {
    if (id_str.len == 0) return 0;
    return @truncate(std.hash.XxHash3.hash(0, id_str));
}

// ── Tests ──

test "add widgets and iterate children" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    try std.testing.expectEqual(@as(WidgetId, 0), root);
    try std.testing.expectEqual(root, tree.root);

    const child1 = tree.addWidget(.label, root).?;
    const child2 = tree.addWidget(.button, root).?;
    const child3 = tree.addWidget(.label, root).?;

    try std.testing.expectEqual(@as(u16, 3), tree.childCount(root));

    var iter = tree.children(root);
    try std.testing.expectEqual(child1, iter.next().?);
    try std.testing.expectEqual(child2, iter.next().?);
    try std.testing.expectEqual(child3, iter.next().?);
    try std.testing.expectEqual(@as(?WidgetId, null), iter.next());
}

test "find by id hash" {
    var tree = WidgetTree{};
    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    tree.widgets[root].id_hash = hashId("myPanel");

    const found = tree.findById("myPanel");
    try std.testing.expectEqual(root, found.?);
    try std.testing.expectEqual(@as(?WidgetId, null), tree.findById("notExist"));
}

test "widget data access" {
    var tree = WidgetTree{};
    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    const lbl = tree.addWidget(.label, root).?;

    var data = tree.getData(lbl).?;
    data.label.setText("Hello");
    try std.testing.expectEqualSlices(u8, "Hello", data.label.getText());
}
