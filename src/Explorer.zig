//! The chats, in the sidebar, as a tree (plans/CHAT_PLAN.md): who each is with (the client: the
//! agents, a person), then the project folder it was started in, then the conversations, newest
//! first, each group ordered by its newest. Choosing one opens it in a tab (`Host.openFile`),
//! where `View.zig` draws it like any document. No background of its own: the sidebar shows
//! through, as it does behind the file tree.
//!
//! Chats live in `<config>/chats/<client>/`, beside fizzy's plugins directory: a plugin has no
//! data directory of its own yet (the seam: `Host.pluginDataDir(id)`), and its install directory
//! is the store's to replace. The list is read from disk only when something changed (`changed`),
//! never per frame, and a chat's title is its file's first line, so a listing reads no
//! conversation whole. Transcripts from before chats had clients sit directly in `chats/`: they
//! are the agent's, and move into `chats/agent/` the first time the list is read.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Commands = @import("Commands.zig");
const api = @import("api.zig");

const Row = struct {
    client: []u8,
    path: []u8,
    title: []u8,
    /// The project folder the chat was started in; empty for none.
    folder: []u8,
    /// Seconds since the epoch, for ordering.
    modified: i64,
};

var rows: std.ArrayListUnmanaged(Row) = .empty;
/// Read the directory again before the next draw.
var stale = true;
var migrated = false;

/// Something on disk changed (a chat saved, made or removed, a client came or went): list again.
pub fn changed() void {
    stale = true;
}

pub fn deinit(gpa: std.mem.Allocator) void {
    clear(gpa);
    rows.deinit(gpa);
    for (pluses.items) |p| {
        gpa.free(p.client);
        gpa.free(p.folder);
    }
    pluses.deinit(gpa);
    open.deinit(gpa);
}

fn clear(gpa: std.mem.Allocator) void {
    for (rows.items) |r| {
        gpa.free(r.client);
        gpa.free(r.path);
        gpa.free(r.title);
        gpa.free(r.folder);
    }
    rows.clearRetainingCapacity();
}

/// `<config>/chats`, owned by `gpa`; null when fizzy has no config folder (the web).
pub fn dir(host: *sdk.Host, gpa: std.mem.Allocator) ?[]u8 {
    const plugins = host.plugins_dir orelse return null;
    const config = std.fs.path.dirname(plugins) orelse return null;
    return std.fs.path.join(gpa, &.{ config, "chats" }) catch null;
}

/// A new, empty transcript of `client`'s, written so it opens as theirs, about `folder` (empty:
/// the one fizzy has open). Owned by `host.allocator`.
pub fn newPath(host: *sdk.Host, client: []const u8, folder: []const u8) ![]u8 {
    const gpa = host.allocator;
    const chats = dir(host, gpa) orelse return error.NoConfigFolder;
    defer gpa.free(chats);
    const client_dir = try std.fs.path.join(gpa, &.{ chats, client });
    defer gpa.free(client_dir);
    std.Io.Dir.cwd().createDirPath(dvui.io, client_dir) catch {};
    // Named by when it began, so names sort as the chats do and never collide in practice.
    const now = std.Io.Clock.real.now(dvui.io).toSeconds();
    const day = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const ymd = day.getEpochDay().calculateYearDay();
    const md = ymd.calculateMonthDay();
    const t = day.getDaySeconds();
    var name_buf: [64]u8 = undefined;
    var n: u32 = 0;
    const path = while (true) : (n += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}{s}.chat", .{
            ymd.year,                                                               md.month.numeric(), md.day_index + 1, t.getHoursIntoDay(), t.getMinutesIntoHour(), t.getSecondsIntoMinute(),
            if (n == 0) "" else try std.fmt.bufPrint(name_buf[48..], "-{d}", .{n}),
        });
        const p = try std.fs.path.join(gpa, &.{ client_dir, name });
        std.Io.Dir.cwd().access(dvui.io, p, .{}) catch break p;
        gpa.free(p);
    };
    errdefer gpa.free(path);
    var head: std.Io.Writer.Allocating = .init(gpa);
    defer head.deinit();
    const project = if (folder.len > 0) folder else host.folder() orelse "";
    try head.writer.print("// \n// folder {s}\n", .{project});
    try std.zon.stringify.serialize(.{ .version = @as(u32, 2), .client = client, .folder = project }, .{}, &head.writer);
    try head.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = head.written() });
    changed();
    return path;
}

/// The first version's chats, directly in `chats/`, into `chats/agent/`.
fn migrate(gpa: std.mem.Allocator, chats: []const u8) void {
    var d = std.Io.Dir.cwd().openDir(dvui.io, chats, .{ .iterate = true }) catch return;
    defer d.close(dvui.io);
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = d.iterate();
    while (it.next(dvui.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".chat")) continue;
        names.append(gpa, gpa.dupe(u8, entry.name) catch continue) catch {};
    }
    if (names.items.len == 0) return;
    d.createDirPath(dvui.io, "agent") catch return;
    for (names.items) |name| {
        const to = std.fs.path.join(gpa, &.{ "agent", name }) catch continue;
        defer gpa.free(to);
        d.rename(name, d, to, dvui.io) catch |err| dvui.log.warn("chat: could not move {s} into agent/: {t}", .{ name, err });
    }
}

fn scan(host: *sdk.Host) void {
    const gpa = host.allocator;
    clear(gpa);
    const chats = dir(host, gpa) orelse return;
    defer gpa.free(chats);
    if (!migrated) {
        migrated = true;
        migrate(gpa, chats);
    }
    var top = std.Io.Dir.cwd().openDir(dvui.io, chats, .{ .iterate = true }) catch return;
    defer top.close(dvui.io);
    var clients = top.iterate();
    while (clients.next(dvui.io) catch null) |c| {
        if (c.kind != .directory or c.name.len == 0 or c.name[0] == '.') continue;
        var d = top.openDir(dvui.io, c.name, .{ .iterate = true }) catch continue;
        defer d.close(dvui.io);
        var it = d.iterate();
        while (it.next(dvui.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".chat")) continue;
            const stat = d.statFile(dvui.io, entry.name, .{}) catch continue;
            const path = std.fs.path.join(gpa, &.{ chats, c.name, entry.name }) catch continue;
            const client = gpa.dupe(u8, c.name) catch {
                gpa.free(path);
                continue;
            };
            const head = readHead(gpa, d, entry.name);
            rows.append(gpa, .{
                .client = client,
                .path = path,
                .title = head.title,
                .folder = head.folder,
                .modified = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)),
            }) catch {
                gpa.free(path);
                gpa.free(client);
                gpa.free(head.title);
                gpa.free(head.folder);
            };
        }
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn newer(_: void, a: Row, b: Row) bool {
            return a.modified > b.modified;
        }
    }.newer);
}

const Head = struct { title: []u8, folder: []u8 };

/// A transcript's first two lines (`Transcript.save`): `// <title>`, then `// folder <path>`,
/// which a first-version transcript does not have.
fn readHead(gpa: std.mem.Allocator, d: std.Io.Dir, name: []const u8) Head {
    var buf: [1024]u8 = undefined;
    const n = blk: {
        var file = d.openFile(dvui.io, name, .{}) catch break :blk 0;
        defer file.close(dvui.io);
        break :blk file.readPositional(dvui.io, &.{&buf}, 0) catch 0;
    };
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    const first = lines.next() orelse "";
    const second = lines.next() orelse "";
    const title = std.mem.trim(u8, if (std.mem.startsWith(u8, first, "//")) first[2..] else "", " \t\r");
    const folder = if (std.mem.startsWith(u8, second, "// folder ")) std.mem.trim(u8, second["// folder ".len..], " \t\r") else "";
    return .{ .title = gpa.dupe(u8, title) catch &.{}, .folder = gpa.dupe(u8, folder) catch &.{} };
}

pub fn draw(host: *sdk.Host) !dvui.App.Result {
    if (stale) {
        stale = false;
        scan(host);
    }
    const theme = dvui.themeGet();
    const arena = host.arena();
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    const width = if (scroll.si.viewport.w > 0) scroll.si.viewport.w else 200;

    // Who: registered clients first, in the order they came; then any whose chats are on disk but
    // who are not here (their plugin is not loaded).
    var clients: std.ArrayListUnmanaged([]const u8) = .empty;
    Commands.registeredIds(&clients, arena);
    for (rows.items) |r| {
        if (!contains(clients.items, r.client)) clients.append(arena, r.client) catch {};
    }
    if (clients.items.len == 0) {
        var hint = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .padding = .all(10),
            .background = false,
            .color_text = .{ .color = theme.color(.content, .text).opacity(0.6) },
            .max_size_content = .width(@max(width - 20, 40)),
        });
        hint.addText("No chats yet. A plugin that holds conversations (the agent plugin, for one) adds its own here.", .{});
        hint.deinit();
        return .ok;
    }

    const active: []const u8 = if (host.activeDoc()) |doc| doc.owner.documentPath(doc) else "";
    const active_hash = std.hash.Wyhash.hash(0, active);
    const active_moved = active_hash != last_active;
    last_active = active_hash;
    const open_folder = host.folder() orelse "";
    claimPluses(host);
    var tree = core.widgets.TreeWidget.tree(@src(), .{}, .{ .background = false, .expand = .horizontal });
    defer tree.deinit();
    // Each group's place in the palette, counted as the file tree counts its folders: a row takes
    // the count as it is drawn, and a group moves it on once its rows are drawn.
    var tint_i: usize = 0;

    for (clients.items) |client| {
        const live = Commands.isRegistered(client);
        const color = theme.color(.control, .text).opacity(if (live) 1 else 0.5);
        const branch = groupBranch(host, tree, client, null, true, color, tint_i, Commands.clientTitle(client) orelse client, null, if (live) "" else null);
        defer branch.deinit();
        defer tint_i += 1;
        if (!expander(host, branch)) continue;

        if (!live) {
            var note = dvui.textLayout(@src(), .{}, .{ .background = false, .margin = .{ .x = indent }, .color_text = .{ .color = color }, .max_size_content = .width(@max(width - 40, 40)) });
            note.format("Needs the {s} plugin to continue these.", .{client}, .{});
            note.deinit();
        }
        // Where: the project folders its chats were started in, newest first (rows are sorted
        // newest first, so the order folders first appear in is theirs).
        var folders: std.ArrayListUnmanaged([]const u8) = .empty;
        for (rows.items) |r| {
            if (std.mem.eql(u8, r.client, client) and !contains(folders.items, r.folder)) folders.append(arena, r.folder) catch {};
        }
        for (folders.items) |folder| {
            var holds_active = false;
            for (rows.items) |r| {
                if (std.mem.eql(u8, r.client, client) and std.mem.eql(u8, r.folder, folder) and std.mem.eql(u8, r.path, active)) holds_active = true;
            }
            const name = if (folder.len > 0) std.fs.path.basename(folder) else "No folder";
            // A chat just made active opens the groups it is in, once; then they are the person's.
            if (holds_active and active_moved) {
                open.put(host.allocator, groupId(client, null), true) catch {};
                open.put(host.allocator, groupId(client, folder), true) catch {};
            }
            const fb = groupBranch(host, tree, client, folder, holds_active or std.mem.eql(u8, folder, open_folder) or folders.items.len == 1, color, tint_i, name, dvui.entypo.folder, if (live) folder else null);
            defer fb.deinit();
            defer tint_i += 1;
            if (!expander(host, fb)) continue;
            for (rows.items) |r| {
                if (!std.mem.eql(u8, r.client, client) or !std.mem.eql(u8, r.folder, folder)) continue;
                chatRow(host, tree, r, std.mem.eql(u8, r.path, active), tint_i, width);
            }
        }
    }
    return .ok;
}

// The file tree's look (the workbench's `files.zig`, `drawRow`), which fizzy's core does not
// hold as a style of its own: its indent, row fills, label padding and fonts, and its icon tint.
const indent = 14;
/// The file tree's label padding: a row is as tall as its text and this, and no taller.
const label_padding: dvui.Rect = .all(3);

/// A row's text, as the file tree draws its names.
fn rowLabel(src: std.builtin.SourceLocation, text: []const u8, color: dvui.Color, font: dvui.Font, opts: dvui.Options) void {
    dvui.labelNoFmt(src, text, .{}, (dvui.Options{
        .gravity_y = 0.5,
        .padding = label_padding,
        .margin = .all(0),
        .color_text = .{ .color = color },
        .font = font,
    }).override(opts));
}

/// The file tree's icon colour: the row's palette colour (or the one a plugin gives that place,
/// `Host.fileRowFillColor`), faded into the window by how far the pointer is from the row. An open
/// group counts as its whole area, less the indent its rows sit in.
fn tint(host: *sdk.Host, index: usize, rect: dvui.Rect.Physical, expanded: bool) dvui.Color {
    const p = dvui.currentWindow().mouse_pt;
    const max = if (expanded) rect.w / 8 else rect.h * 3;
    const left = rect.x + if (expanded) indent * dvui.currentWindow().natural_scale else 0;
    const right = rect.x + rect.w;
    const bottom = rect.y + rect.h;
    const dx: f32 = if (p.x < left) std.math.floatMax(f32) else if (p.x > right) p.x - right else 0;
    const dy: f32 = if (p.y < rect.y) rect.y - p.y else if (p.y > bottom) p.y - bottom else 0;
    const t = 1 - @sqrt(dx * dx + dy * dy) / max;
    const color = host.fileRowFillColor(index) orelse core.palette.at(index);
    return dvui.themeGet().color(.window, .fill).lerp(color, t);
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn idOf(parts: []const []const u8) usize {
    var h = std.hash.Wyhash.init(0x63686174);
    for (parts) |p| {
        h.update(p);
        h.update("/");
    }
    return @truncate(h.final());
}

fn rowOptions(id: usize, selected: bool) dvui.Options {
    const theme = dvui.themeGet();
    return .{
        .id_extra = id,
        .expand = .horizontal,
        .color_fill_hover = .{ .color = theme.color(.control, .fill).opacity(0.5) },
        .color_fill_press = .{ .color = theme.color(.control, .fill_press) },
        .color_fill = .{ .color = if (selected) theme.color(.control, .fill).opacity(0.5) else core.widgets.hoverRestFill(theme.color(.control, .fill)) },
        .padding = dvui.Rect.all(1),
    };
}

/// A + at a group row's right edge, as drawn last frame, and the chat it makes.
const Plus = struct { rect: dvui.Rect.Physical, client: []u8, folder: []u8, id: usize };
var pluses: std.ArrayListUnmanaged(Plus) = .empty;
/// The + the pointer is over, by row id.
var plus_hot: ?usize = null;

/// Clicks on a row's +, taken before the row's own button sees them (a press there would fold the
/// group): by where each + was drawn last frame. Then the list is drawn afresh.
fn claimPluses(host: *sdk.Host) void {
    const gpa = host.allocator;
    const mp = dvui.currentWindow().mouse_pt;
    plus_hot = null;
    for (pluses.items) |p| if (p.rect.contains(mp)) {
        plus_hot = p.id;
    };
    var made: ?usize = null;
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (!me.button.pointer() or (me.action != .press and me.action != .release)) continue;
        for (pluses.items, 0..) |p, i| if (p.rect.contains(me.p)) {
            e.handled = true;
            if (me.action == .release) made = i;
            break;
        };
    }
    if (made) |i| newChat(host, pluses.items[i].client, pluses.items[i].folder);
    for (pluses.items) |p| {
        gpa.free(p.client);
        gpa.free(p.folder);
    }
    pluses.clearRetainingCapacity();
}

/// Whether each group is open, by row id. The tree takes `expanded` as where the row should be,
/// every frame, and animates toward it whenever it differs from where the row is: a wish worked
/// out afresh each frame (the folder holding the active chat) that disagreed with the person's
/// last click restarted the fold every frame, and the group stuck a frame into it, its last rows
/// cut off. So a group's wish only opens it the first time it is drawn, and after that the tree
/// is handed back what it last was.
var open: std.AutoHashMapUnmanaged(usize, bool) = .empty;
/// The active chat's path, hashed, as last drawn: a group opens for it only when it changes.
var last_active: u64 = 0;

/// A group row's expander, its open state kept for the next frame's `groupBranch`.
fn expander(host: *sdk.Host, branch: *core.widgets.TreeWidget.Branch) bool {
    const expanded = branch.expander(@src(), .{ .indent = indent }, .{ .expand = .horizontal, .corners = .all(8) });
    open.put(host.allocator, branch.init_options.branch_id.?, expanded) catch {};
    return expanded;
}

/// A group row's id: a client's (`folder` null), or one of its folders' ("" is "No folder", which
/// must not be taken for the client's own row).
fn groupId(client: []const u8, folder: ?[]const u8) usize {
    return if (folder) |f| idOf(&.{ client, f, "group" }) else idOf(&.{ client, "client" });
}

/// A group's row: a client (`folder` null), or a folder under one. Its caret, its icon, its name,
/// and a + at the right edge (`plus`: the folder a new chat goes in, "" for the open one; null for
/// none). `first_open`: whether it opens the first time it is drawn.
fn groupBranch(host: *sdk.Host, tree: *core.widgets.TreeWidget, client: []const u8, folder: ?[]const u8, first_open: bool, color: dvui.Color, tint_i: usize, name: []const u8, icon: ?[]const u8, plus: ?[]const u8) *core.widgets.TreeWidget.Branch {
    const id = groupId(client, folder);
    const branch = tree.branch(@src(), .{
        .expanded = open.get(id) orelse first_open,
        .animation_duration = 450_000,
        .animation_easing = core.motion.enter,
        .can_accept_children = false,
        .draggable = false,
        .branch_id = id,
    }, rowOptions(id, false));
    // Named for a demo tape: `chat.group:<client>`, or `chat.group:<client>:<folder>`.
    if (folder) |f| core.anchor.mark(branch.button.data(), "chat.group:{s}:{s}", .{ client, f }) else core.anchor.mark(branch.button.data(), "chat.group:{s}", .{client});
    const glyph = tint(host, tint_i, branch.data().borderRectScale().r, branch.expanded).opacity(@as(f32, @floatFromInt(color.a)) / 255);
    core.widgets.treeCaret(@src(), branch.expanded, glyph);
    if (plus) |plus_folder| {
        const theme = dvui.themeGet();
        var box = dvui.box(@src(), .{}, .{
            .gravity_x = 1,
            .gravity_y = 0.5,
            .margin = .{ .w = 4 },
            .padding = .all(3),
            .corners = .all(6),
            .background = plus_hot == id,
            .color_fill = .{ .color = theme.color(.control, .fill_hover) },
        });
        core.icon.icon(@src(), "chat-plus", dvui.entypo.plus, .{ .fill_color = .{ .color = if (plus_hot == id) theme.color(.highlight, .fill) else color } }, .{ .min_size_content = .{ .w = 12, .h = 12 } });
        const r = box.data().borderRectScale().r;
        box.deinit();
        const gpa = sdk.allocator();
        if (gpa.dupe(u8, client)) |c| {
            if (gpa.dupe(u8, plus_folder)) |f| {
                pluses.append(gpa, .{ .rect = r, .client = c, .folder = f, .id = id }) catch {
                    gpa.free(c);
                    gpa.free(f);
                };
            } else |_| gpa.free(c);
        } else |_| {}
    }
    if (icon) |tvg| {
        var slot = core.widgets.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
        core.icon.icon(@src(), "chat-group", tvg, .{ .fill_color = .{ .color = glyph }, .stroke_color = .{ .color = glyph } }, core.widgets.treeRowIconOptions(.{}));
        slot.deinit();
    }
    // A client heads its chats as the open folder heads the file tree, in the heading font.
    rowLabel(@src(), name, color, dvui.Font.theme(if (icon == null) .heading else .body), .{});
    return branch;
}

fn chatRow(host: *sdk.Host, tree: *core.widgets.TreeWidget, r: Row, selected: bool, tint_i: usize, width: f32) void {
    const theme = dvui.themeGet();
    const id = idOf(&.{r.path});
    const branch = tree.branch(@src(), .{ .can_accept_children = false, .draggable = false, .branch_id = id }, rowOptions(id, selected));
    defer branch.deinit();
    core.anchor.mark(branch.button.data(), "chat.chat:{s}", .{r.path});
    {
        var slot = core.widgets.treeRowGlyph(@src(), .{});
        slot.deinit();
    }
    {
        var slot = core.widgets.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
        const glyph = tint(host, tint_i, branch.data().borderRectScale().r, false);
        core.icon.icon(@src(), "chat-row", dvui.entypo.chat, .{ .fill_color = .{ .color = glyph }, .stroke_color = .{ .color = glyph } }, core.widgets.treeRowIconOptions(.{}));
        slot.deinit();
    }
    // When it last moved, at the right; the title takes what is left, on one line, brighter while
    // the chat is open in a tab, as a file's name is.
    rowLabel(@src(), age(host.arena(), r.modified), theme.color(.control, .text).opacity(0.45), dvui.Font.theme(.body).larger(-2), .{ .gravity_x = 1 });
    rowLabel(@src(), if (r.title.len > 0) r.title else "New chat", theme.color(if (host.docFromPath(r.path) != null) .window else .control, .text), dvui.Font.theme(.body), .{
        .max_size_content = .width(@max(width - 110, 20)),
    });
    if (branch.button.clicked()) _ = host.openFile(.{ .path = r.path }) catch {};
}

/// How long ago, as a person says it: "now", "5m", "3h", "2d", "6w".
fn age(arena: std.mem.Allocator, modified: i64) []const u8 {
    const now = std.Io.Clock.real.now(dvui.io).toSeconds();
    const s = @max(0, now - modified);
    if (s < 60) return "now";
    const v, const unit: []const u8 = if (s < 3600) .{ @divFloor(s, 60), "m" } else if (s < 86400) .{ @divFloor(s, 3600), "h" } else if (s < 86400 * 14) .{ @divFloor(s, 86400), "d" } else .{ @divFloor(s, 86400 * 7), "w" };
    return std.fmt.allocPrint(arena, "{d}{s}", .{ v, unit }) catch "";
}

/// New, for `client`, in `folder` (empty: the one fizzy has open): its own `chat_new` when it has
/// one (it may want to set the chat up), else a plain new chat of its.
fn newChat(host: *sdk.Host, client: []const u8, folder: []const u8) void {
    var buf: [128]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{s}.chat_new", .{client}) catch return;
    if (host.command(id) != null) {
        const args = api.write(host.arena(), api.NewChat{ .folder = folder }) catch return;
        _ = host.callCommand(id, args, host.arena());
        return;
    }
    const path = newPath(host, client, folder) catch |err| return dvui.log.err("chat: could not start a new chat: {t}", .{err});
    defer host.allocator.free(path);
    _ = host.openFile(.{ .path = path }) catch {};
}
