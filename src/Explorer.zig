//! The chats, in the sidebar: New Chat, then every saved conversation, newest first. Choosing one
//! opens it in a tab (`Host.openFile`), where `Chat.zig` draws it like any document.
//!
//! Chats live in `<config>/chats/`, beside fizzy's plugins directory: a plugin has no data
//! directory of its own yet (the seam: `Host.pluginDataDir(id)`), and its install directory is
//! the store's to replace. The list is read from disk only when something changed (`changed`),
//! never per frame, and a chat's title is its file's first line, so a listing reads no
//! conversation whole.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");

const Row = struct {
    path: []u8,
    title: []u8,
    /// Seconds since the epoch, for ordering.
    modified: i64,
};

var rows: std.ArrayListUnmanaged(Row) = .empty;
/// Read the directory again before the next draw.
var stale = true;

/// Something on disk changed (a chat saved, made or removed): list again before the next draw.
pub fn changed() void {
    stale = true;
}

pub fn deinit(gpa: std.mem.Allocator) void {
    clear(gpa);
    rows.deinit(gpa);
}

fn clear(gpa: std.mem.Allocator) void {
    for (rows.items) |r| {
        gpa.free(r.path);
        gpa.free(r.title);
    }
    rows.clearRetainingCapacity();
}

/// `<config>/chats`, owned by `gpa`; null when fizzy has no config folder (the web).
pub fn dir(host: *sdk.Host, gpa: std.mem.Allocator) ?[]u8 {
    const plugins = host.plugins_dir orelse return null;
    const config = std.fs.path.dirname(plugins) orelse return null;
    return std.fs.path.join(gpa, &.{ config, "chats" }) catch null;
}

/// Start a new chat: an empty transcript, opened in a tab.
pub fn newChat(host: *sdk.Host) !void {
    const gpa = host.allocator;
    const chats = dir(host, gpa) orelse return error.NoConfigFolder;
    defer gpa.free(chats);
    std.Io.Dir.cwd().createDirPath(dvui.io, chats) catch {};
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
            ymd.year, md.month.numeric(), md.day_index + 1, t.getHoursIntoDay(), t.getMinutesIntoHour(), t.getSecondsIntoMinute(),
            if (n == 0) "" else try std.fmt.bufPrint(name_buf[48..], "-{d}", .{n}),
        });
        const p = try std.fs.path.join(gpa, &.{ chats, name });
        std.Io.Dir.cwd().access(dvui.io, p, .{}) catch break p;
        gpa.free(p);
    };
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = "// \n.{}\n" });
    changed();
    _ = try host.openFile(.{ .path = path });
}

fn scan(host: *sdk.Host) void {
    const gpa = host.allocator;
    clear(gpa);
    const chats = dir(host, gpa) orelse return;
    defer gpa.free(chats);
    var d = std.Io.Dir.cwd().openDir(dvui.io, chats, .{ .iterate = true }) catch return;
    defer d.close(dvui.io);
    var it = d.iterate();
    while (it.next(dvui.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".chat")) continue;
        const path = std.fs.path.join(gpa, &.{ chats, entry.name }) catch continue;
        const stat = d.statFile(dvui.io, entry.name, .{}) catch {
            gpa.free(path);
            continue;
        };
        rows.append(gpa, .{
            .path = path,
            .title = readTitle(gpa, d, entry.name) catch gpa.dupe(u8, "") catch "",
            .modified = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)),
        }) catch gpa.free(path);
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn newer(_: void, a: Row, b: Row) bool {
            return a.modified > b.modified;
        }
    }.newer);
}

/// A transcript's first line, `// <title>` (`Chat.save`).
fn readTitle(gpa: std.mem.Allocator, d: std.Io.Dir, name: []const u8) ![]u8 {
    var file = try d.openFile(dvui.io, name, .{});
    defer file.close(dvui.io);
    var buf: [256]u8 = undefined;
    const n = try file.readPositional(dvui.io, &.{&buf}, 0);
    const first = buf[0 .. std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n];
    const title = std.mem.trim(u8, if (std.mem.startsWith(u8, first, "//")) first[2..] else "", " \t\r");
    return gpa.dupe(u8, title);
}

pub fn draw(host: *sdk.Host) !dvui.App.Result {
    if (stale) {
        stale = false;
        scan(host);
    }
    const theme = dvui.themeGet();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer col.deinit();

    if (dvui.button(@src(), "New Chat", .{}, .{ .expand = .horizontal, .margin = .all(6) })) {
        newChat(host) catch |err| dvui.log.err("chat: could not start a new chat: {t}", .{err});
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    if (rows.items.len == 0) {
        var hint = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .padding = .all(10),
            .background = false,
            .color_text = .{ .color = theme.color(.content, .text).opacity(0.6) },
            .max_size_content = if (scroll.si.viewport.w > 0) .{ .w = scroll.si.viewport.w - 20, .h = std.math.floatMax(f32) } else null,
        });
        hint.addText("No chats yet. New Chat starts one with the agent set in Settings > Chat.", .{});
        hint.deinit();
    }
    const active: []const u8 = if (host.activeDoc()) |doc| doc.owner.documentPath(doc) else "";
    for (rows.items, 0..) |r, i| {
        const is_active = std.mem.eql(u8, r.path, active);
        var b: dvui.ButtonWidget = undefined;
        b.init(@src(), .{}, .{
            .expand = .horizontal,
            .id_extra = i,
            .margin = .{ .x = 4, .w = 4 },
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            // The open chat on the control fill, its text as legible as the rest.
            .background = is_active,
            .style = if (is_active) .control else .content,
        });
        b.processEvents();
        b.drawBackground();
        const title = if (r.title.len > 0) r.title else "New chat";
        // One line, clipped to the sidebar rather than widening it.
        dvui.label(@src(), "{s}", .{title}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .max_size_content = if (scroll.si.viewport.w > 0) .{ .w = scroll.si.viewport.w - 32, .h = std.math.floatMax(f32) } else null,
        });
        if (b.clicked()) _ = host.openFile(.{ .path = r.path }) catch {};
        b.deinit();
    }
    return .ok;
}
