const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const WidgetKind = Widget.WidgetKind;
const SizeSpec = Widget.SizeSpec;
const LayoutMode = Widget.LayoutMode;
const FlexDirection = Widget.FlexDirection;
const Alignment = Widget.Alignment;
const Justification = Widget.Justification;
const AnchorPoint = Widget.AnchorPoint;
const Color = Widget.Color;
const Edges = Widget.Edges;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const hashId = @import("WidgetTree.zig").hashId;
const WidgetData = @import("WidgetData.zig");
const XmlParser = @import("XmlParser.zig");
const XmlEvent = XmlParser.XmlEvent;
const app_config = @import("../app_config.zig");

const Io = std.Io;
const Dir = Io.Dir;
const sep = std.fs.path.sep_str;

const log = std.log.scoped(.UI);

const MAX_DEPTH = 32;

pub fn loadScreen(tree: *WidgetTree, passthrough: *bool, filename: []const u8, allocator: std.mem.Allocator) bool {
    const base_path = app_config.getAppDataPath(allocator) catch return false;
    defer allocator.free(base_path);

    const file_path = std.fmt.allocPrint(
        allocator,
        "{s}" ++ sep ++ "assets" ++ sep ++ "farhorizons" ++ sep ++ "ui" ++ sep ++ "{s}",
        .{ base_path, filename },
    ) catch return false;
    defer allocator.free(file_path);

    const io = Io.Threaded.global_single_threaded.io();
    const data = Dir.readFileAlloc(.cwd(), io, file_path, allocator, .unlimited) catch {
        log.err("Failed to load UI screen: {s}", .{file_path});
        return false;
    };
    defer allocator.free(data);

    return loadScreenFromSource(tree, passthrough, data);
}

pub fn loadScreenFromSource(tree: *WidgetTree, passthrough: *bool, xml: []const u8) bool {
    var parser = XmlParser.XmlParser.init(xml);
    var parent_stack: [MAX_DEPTH]WidgetId = .{NULL_WIDGET} ** MAX_DEPTH;
    var stack_depth: u8 = 0;

    while (parser.next()) |event| {
        switch (event.kind) {
            .open_tag => {
                if (eql(event.tag, "screen")) {
                    if (event.getAttr("passthrough")) |v| {
                        passthrough.* = parseBool(v);
                    }
                    continue;
                }

                const kind = tagToKind(event.tag) orelse continue;
                const parent = if (stack_depth > 0) parent_stack[stack_depth - 1] else NULL_WIDGET;
                const id = tree.addWidget(kind, parent) orelse return false;

                applyWidgetAttrs(tree, id, &event);
                applyDataAttrs(tree, id, kind, &event);

                if (stack_depth < MAX_DEPTH) {
                    parent_stack[stack_depth] = id;
                    stack_depth += 1;
                }
            },
            .self_closing => {
                if (eql(event.tag, "screen")) {
                    if (event.getAttr("passthrough")) |v| {
                        passthrough.* = parseBool(v);
                    }
                    continue;
                }

                const kind = tagToKind(event.tag) orelse continue;
                const parent = if (stack_depth > 0) parent_stack[stack_depth - 1] else NULL_WIDGET;
                const id = tree.addWidget(kind, parent) orelse return false;

                applyWidgetAttrs(tree, id, &event);
                applyDataAttrs(tree, id, kind, &event);
            },
            .close_tag => {
                if (eql(event.tag, "screen")) continue;
                if (stack_depth > 0) stack_depth -= 1;
            },
        }
    }

    return tree.root != NULL_WIDGET;
}


fn tagToKind(tag: []const u8) ?WidgetKind {
    const map = .{
        .{ "panel", WidgetKind.panel },
        .{ "label", WidgetKind.label },
        .{ "button", WidgetKind.button },
        .{ "text_input", WidgetKind.text_input },
        .{ "image", WidgetKind.image },
        .{ "scroll_view", WidgetKind.scroll_view },
        .{ "list_view", WidgetKind.list_view },
        .{ "progress_bar", WidgetKind.progress_bar },
        .{ "checkbox", WidgetKind.checkbox },
        .{ "slider", WidgetKind.slider },
        .{ "grid", WidgetKind.grid },
        .{ "dropdown", WidgetKind.dropdown },
    };
    inline for (map) |entry| {
        if (eql(tag, entry[0])) return entry[1];
    }
    return null;
}


fn applyWidgetAttrs(tree: *WidgetTree, id: WidgetId, event: *const XmlEvent) void {
    const w = tree.getWidget(id) orelse return;

    for (event.attrs[0..event.attr_count]) |attr| {
        const name = attr.name;
        const val = attr.value;

        if (eql(name, "id")) {
            w.id_hash = hashId(val);
        } else if (eql(name, "width")) {
            w.width = parseSize(val);
        } else if (eql(name, "height")) {
            w.height = parseSize(val);
        } else if (eql(name, "min_width")) {
            w.min_width = parseFloat(val);
        } else if (eql(name, "min_height")) {
            w.min_height = parseFloat(val);
        } else if (eql(name, "layout")) {
            w.layout_mode = parseLayoutMode(val);
        } else if (eql(name, "direction")) {
            w.flex_direction = parseFlexDirection(val);
        } else if (eql(name, "cross_align")) {
            w.cross_align = parseAlignment(val);
        } else if (eql(name, "justify")) {
            w.justify = parseJustification(val);
        } else if (eql(name, "gap")) {
            w.gap = parseFloat(val);
        } else if (eql(name, "flex_grow")) {
            w.flex_grow = parseFloat(val);
        } else if (eql(name, "anchor_x")) {
            w.anchor_x = parseAnchorPoint(val);
        } else if (eql(name, "anchor_y")) {
            w.anchor_y = parseAnchorPoint(val);
        } else if (eql(name, "offset_x")) {
            w.offset_x = parseFloat(val);
        } else if (eql(name, "offset_y")) {
            w.offset_y = parseFloat(val);
        } else if (eql(name, "padding")) {
            w.padding = parseEdges(val);
        } else if (eql(name, "margin")) {
            w.margin = parseEdges(val);
        } else if (eql(name, "background")) {
            w.background = parseColor(val);
        } else if (eql(name, "border_color")) {
            w.border_color = parseColor(val);
        } else if (eql(name, "border_width")) {
            w.border_width = parseFloat(val);
        } else if (eql(name, "visible")) {
            w.visible = parseBool(val);
        } else if (eql(name, "focusable")) {
            w.focusable = parseBool(val);
        } else if (eql(name, "tooltip")) {
            const len: u8 = @intCast(@min(val.len, 64));
            @memcpy(w.tooltip[0..len], val[0..len]);
            w.tooltip_len = len;
        }
    }
}

fn applyDataAttrs(tree: *WidgetTree, id: WidgetId, kind: WidgetKind, event: *const XmlEvent) void {
    const data = tree.getData(id) orelse return;

    switch (kind) {
        .label => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "text")) {
                    data.label.setText(attr.value);
                } else if (eql(attr.name, "color")) {
                    data.label.color = parseColor(attr.value);
                } else if (eql(attr.name, "font_size")) {
                    data.label.font_size = parseInt(attr.value);
                } else if (eql(attr.name, "wrap")) {
                    data.label.wrap = parseBool(attr.value);
                } else if (eql(attr.name, "shadow")) {
                    data.label.shadow = parseBool(attr.value);
                } else if (eql(attr.name, "shadow_color")) {
                    data.label.shadow_color = parseColor(attr.value);
                }
            }
        },
        .button => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "text")) {
                    data.button.setText(attr.value);
                } else if (eql(attr.name, "text_color")) {
                    data.button.text_color = parseColor(attr.value);
                } else if (eql(attr.name, "hover_color")) {
                    data.button.hover_color = parseColor(attr.value);
                } else if (eql(attr.name, "press_color")) {
                    data.button.press_color = parseColor(attr.value);
                } else if (eql(attr.name, "on_click")) {
                    data.button.setAction(attr.value);
                } else if (eql(attr.name, "shadow")) {
                    data.button.shadow = parseBool(attr.value);
                } else if (eql(attr.name, "shadow_color")) {
                    data.button.shadow_color = parseColor(attr.value);
                }
            }
        },
        .text_input => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "placeholder")) {
                    const len: u8 = @intCast(@min(attr.value.len, WidgetData.MAX_TEXT_LEN));
                    @memcpy(data.text_input.placeholder[0..len], attr.value[0..len]);
                    data.text_input.placeholder_len = len;
                } else if (eql(attr.name, "text_color")) {
                    data.text_input.text_color = parseColor(attr.value);
                } else if (eql(attr.name, "placeholder_color")) {
                    data.text_input.placeholder_color = parseColor(attr.value);
                } else if (eql(attr.name, "max_len")) {
                    data.text_input.max_len = parseInt(attr.value);
                }
            }
        },
        .progress_bar => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "value")) {
                    data.progress_bar.value = parseFloat(attr.value);
                } else if (eql(attr.name, "fill_color")) {
                    data.progress_bar.fill_color = parseColor(attr.value);
                } else if (eql(attr.name, "track_color")) {
                    data.progress_bar.track_color = parseColor(attr.value);
                }
            }
        },
        .slider => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "value")) {
                    data.slider.value = parseFloat(attr.value);
                } else if (eql(attr.name, "min_value")) {
                    data.slider.min_value = parseFloat(attr.value);
                } else if (eql(attr.name, "max_value")) {
                    data.slider.max_value = parseFloat(attr.value);
                } else if (eql(attr.name, "track_color")) {
                    data.slider.track_color = parseColor(attr.value);
                } else if (eql(attr.name, "fill_color")) {
                    data.slider.fill_color = parseColor(attr.value);
                } else if (eql(attr.name, "thumb_color")) {
                    data.slider.thumb_color = parseColor(attr.value);
                } else if (eql(attr.name, "on_change")) {
                    const len: u8 = @intCast(@min(attr.value.len, WidgetData.MAX_ACTION_LEN));
                    @memcpy(data.slider.on_change_action[0..len], attr.value[0..len]);
                    data.slider.on_change_action_len = len;
                }
            }
        },
        .checkbox => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "checked")) {
                    data.checkbox.checked = parseBool(attr.value);
                } else if (eql(attr.name, "check_color")) {
                    data.checkbox.check_color = parseColor(attr.value);
                } else if (eql(attr.name, "box_color")) {
                    data.checkbox.box_color = parseColor(attr.value);
                } else if (eql(attr.name, "on_change")) {
                    const len: u8 = @intCast(@min(attr.value.len, WidgetData.MAX_ACTION_LEN));
                    @memcpy(data.checkbox.on_change_action[0..len], attr.value[0..len]);
                    data.checkbox.on_change_action_len = len;
                }
            }
        },
        .image => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "src")) {
                    const len: u8 = @intCast(@min(attr.value.len, WidgetData.MAX_TEXT_LEN));
                    @memcpy(data.image.src[0..len], attr.value[0..len]);
                    data.image.src_len = len;
                } else if (eql(attr.name, "tint")) {
                    data.image.tint = parseColor(attr.value);
                } else if (eql(attr.name, "nine_slice_border")) {
                    data.image.nine_slice_border = parseFloat(attr.value);
                } else if (eql(attr.name, "atlas_u")) {
                    data.image.atlas_u = parseFloat(attr.value);
                } else if (eql(attr.name, "atlas_v")) {
                    data.image.atlas_v = parseFloat(attr.value);
                } else if (eql(attr.name, "atlas_w")) {
                    data.image.atlas_w = parseFloat(attr.value);
                } else if (eql(attr.name, "atlas_h")) {
                    data.image.atlas_h = parseFloat(attr.value);
                } else if (eql(attr.name, "blend")) {
                    if (eql(attr.value, "inverted")) {
                        data.image.blend_mode = .inverted;
                    }
                }
            }
        },
        .scroll_view => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "scroll_bar_visible")) {
                    data.scroll_view.scroll_bar_visible = parseBool(attr.value);
                }
            }
        },
        .list_view => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "item_height")) {
                    data.list_view.item_height = parseFloat(attr.value);
                } else if (eql(attr.name, "item_count")) {
                    data.list_view.item_count = std.fmt.parseInt(u16, attr.value, 10) catch 0;
                } else if (eql(attr.name, "selected_index")) {
                    data.list_view.selected_index = std.fmt.parseInt(u16, attr.value, 10) catch 0;
                } else if (eql(attr.name, "selection_color")) {
                    data.list_view.selection_color = parseColor(attr.value);
                } else if (eql(attr.name, "on_change")) {
                    const len: u8 = @intCast(@min(attr.value.len, WidgetData.MAX_ACTION_LEN));
                    @memcpy(data.list_view.on_change_action[0..len], attr.value[0..len]);
                    data.list_view.on_change_action_len = len;
                } else if (eql(attr.name, "on_double_click")) {
                    const len: u8 = @intCast(@min(attr.value.len, WidgetData.MAX_ACTION_LEN));
                    @memcpy(data.list_view.on_double_click_action[0..len], attr.value[0..len]);
                    data.list_view.on_double_click_action_len = len;
                }
            }
        },
        .grid => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "columns")) {
                    data.grid.columns = parseInt(attr.value);
                } else if (eql(attr.name, "rows")) {
                    data.grid.rows = parseInt(attr.value);
                } else if (eql(attr.name, "cell_size")) {
                    data.grid.cell_size = parseFloat(attr.value);
                } else if (eql(attr.name, "cell_gap")) {
                    data.grid.cell_gap = parseFloat(attr.value);
                }
            }
        },
        .dropdown => {
            for (event.attrs[0..event.attr_count]) |attr| {
                if (eql(attr.name, "items")) {
                    var start: usize = 0;
                    for (attr.value, 0..) |ch, j| {
                        if (ch == ',') {
                            data.dropdown.addItem(attr.value[start..j]);
                            start = j + 1;
                        }
                    }
                    if (start < attr.value.len) {
                        data.dropdown.addItem(attr.value[start..]);
                    }
                } else if (eql(attr.name, "selected")) {
                    data.dropdown.selected = parseInt(attr.value);
                } else if (eql(attr.name, "text_color")) {
                    data.dropdown.text_color = parseColor(attr.value);
                } else if (eql(attr.name, "item_bg")) {
                    data.dropdown.item_bg = parseColor(attr.value);
                } else if (eql(attr.name, "hover_color")) {
                    data.dropdown.hover_color = parseColor(attr.value);
                } else if (eql(attr.name, "on_change")) {
                    const len: u8 = @intCast(@min(attr.value.len, WidgetData.MAX_ACTION_LEN));
                    @memcpy(data.dropdown.on_change_action[0..len], attr.value[0..len]);
                    data.dropdown.on_change_action_len = len;
                }
            }
        },
        .panel => {},
    }
}


fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseSize(s: []const u8) SizeSpec {
    if (eql(s, "auto")) return .auto;
    if (eql(s, "fill")) return .fill;
    if (s.len > 0 and s[s.len - 1] == '%') {
        return .{ .percent = parseFloat(s[0 .. s.len - 1]) };
    }
    return .{ .px = parseFloat(s) };
}

fn parseColor(s: []const u8) Color {
    if (s.len == 7 and s[0] == '#') {
        const hex = std.fmt.parseInt(u24, s[1..7], 16) catch return Color.white;
        return Color.fromHex((@as(u32, hex) << 8) | 0xFF);
    }
    if (s.len == 9 and s[0] == '#') {
        const hex = std.fmt.parseInt(u32, s[1..9], 16) catch return Color.white;
        return Color.fromHex(hex);
    }
    return Color.white;
}

fn parseEdges(s: []const u8) Edges {
    var parts: [4][]const u8 = undefined;
    var count: u8 = 0;
    var start: usize = 0;

    for (s, 0..) |c, i| {
        if (c == ',') {
            if (count < 4) {
                parts[count] = s[start..i];
                count += 1;
            }
            start = i + 1;
        }
    }
    if (count < 4) {
        parts[count] = s[start..];
        count += 1;
    }

    if (count == 4) {
        return .{
            .top = parseFloat(parts[0]),
            .right = parseFloat(parts[1]),
            .bottom = parseFloat(parts[2]),
            .left = parseFloat(parts[3]),
        };
    }
    return Edges.uniform(parseFloat(s));
}

fn parseFloat(s: []const u8) f32 {
    return std.fmt.parseFloat(f32, s) catch 0;
}

fn parseInt(s: []const u8) u8 {
    return std.fmt.parseInt(u8, s, 10) catch 0;
}

fn parseBool(s: []const u8) bool {
    return eql(s, "true");
}

fn parseLayoutMode(s: []const u8) LayoutMode {
    if (eql(s, "anchor")) return .anchor;
    return .flex;
}

fn parseFlexDirection(s: []const u8) FlexDirection {
    if (eql(s, "row")) return .row;
    return .column;
}

fn parseAlignment(s: []const u8) Alignment {
    if (eql(s, "center")) return .center;
    if (eql(s, "end")) return .end;
    if (eql(s, "stretch")) return .stretch;
    return .start;
}

fn parseJustification(s: []const u8) Justification {
    if (eql(s, "center")) return .center;
    if (eql(s, "end")) return .end;
    if (eql(s, "space_between")) return .space_between;
    return .start;
}

fn parseAnchorPoint(s: []const u8) AnchorPoint {
    if (eql(s, "center")) return .center;
    if (eql(s, "end")) return .end;
    return .start;
}


test "minimal screen" {
    var tree = WidgetTree{};
    var passthrough = false;
    const result = loadScreenFromSource(&tree, &passthrough, "<screen><panel/></screen>");
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(WidgetId, 0), tree.root);
    try std.testing.expectEqual(WidgetKind.panel, tree.widgets[0].kind);
}

test "nested widgets" {
    var tree = WidgetTree{};
    var passthrough = false;
    const xml =
        \\<screen>
        \\  <panel width="fill" height="fill" layout="anchor">
        \\    <label text="Hello" color="#FFCC00FF" font_size="2"/>
        \\    <button text="Click" on_click="test_action" width="80" height="28"/>
        \\  </panel>
        \\</screen>
    ;
    const result = loadScreenFromSource(&tree, &passthrough, xml);
    try std.testing.expect(result);

    const root = tree.getWidgetConst(0).?;
    try std.testing.expectEqual(SizeSpec.fill, root.width);
    try std.testing.expectEqual(LayoutMode.anchor, root.layout_mode);

    const lbl_data = tree.getDataConst(1).?;
    try std.testing.expectEqualSlices(u8, "Hello", lbl_data.label.getText());
    try std.testing.expectEqual(@as(u8, 2), lbl_data.label.font_size);

    const btn_data = tree.getDataConst(2).?;
    try std.testing.expectEqualSlices(u8, "Click", btn_data.button.getText());
    try std.testing.expectEqualSlices(u8, "test_action", btn_data.button.getAction());
    try std.testing.expectEqual(SizeSpec{ .px = 80 }, tree.getWidgetConst(2).?.width);
}

test "screen passthrough" {
    var tree = WidgetTree{};
    var passthrough = false;
    _ = loadScreenFromSource(&tree, &passthrough,
        \\<screen passthrough="true"><panel/></screen>
    );
    try std.testing.expect(passthrough);
}

test "parse helpers" {
    try std.testing.expectEqual(SizeSpec.auto, parseSize("auto"));
    try std.testing.expectEqual(SizeSpec.fill, parseSize("fill"));
    try std.testing.expectEqual(SizeSpec{ .px = 320 }, parseSize("320"));
    try std.testing.expectEqual(SizeSpec{ .percent = 50 }, parseSize("50%"));

    const c = parseColor("#FF8800FF");
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.533), c.g, 0.01);

    const e1 = parseEdges("16");
    try std.testing.expectApproxEqAbs(@as(f32, 16), e1.top, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16), e1.left, 0.01);

    const e2 = parseEdges("8,16,8,16");
    try std.testing.expectApproxEqAbs(@as(f32, 8), e2.top, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16), e2.right, 0.01);

    try std.testing.expect(parseBool("true"));
    try std.testing.expect(!parseBool("false"));
}
