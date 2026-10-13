//! The chats, in the sidebar, grouped by the client each belongs to (plans/CHAT_PLAN.md): a
//! group per client, its title and a New button, then its conversations, newest first. Choosing
//! one opens it in a tab (`Host.openFile`), where `View.zig` draws it like any document.
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

const Row = struct {
    client: []u8,
    path: []u8,
    title: []u8,
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
}

fn clear(gpa: std.mem.Allocator) void {
    for (rows.items) |r| {
        gpa.free(r.client);
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

/// A new, empty transcript of `client`'s, written so it opens as theirs. Owned by `host.allocator`.
pub fn newPath(host: *sdk.Host, client: []const u8) ![]u8 {
    const gpa = host.allocator;
    const chats = dir(host, gpa) orelse return error.NoConfigFolder;
    defer gpa.free(chats);
    const folder = try std.fs.path.join(gpa, &.{ chats, client });
    defer gpa.free(folder);
    std.Io.Dir.cwd().createDirPath(dvui.io, folder) catch {};
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
        const p = try std.fs.path.join(gpa, &.{ folder, name });
        std.Io.Dir.cwd().access(dvui.io, p, .{}) catch break p;
        gpa.free(p);
    };
    errdefer gpa.free(path);
    var head: std.Io.Writer.Allocating = .init(gpa);
    defer head.deinit();
    try head.writer.writeAll("// \n");
    try std.zon.stringify.serialize(.{ .version = @as(u32, 2), .client = client }, .{}, &head.writer);
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
            rows.append(gpa, .{
                .client = client,
                .path = path,
                .title = readTitle(gpa, d, entry.name) catch gpa.dupe(u8, "") catch "",
                .modified = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)),
            }) catch {
                gpa.free(path);
                gpa.free(client);
            };
        }
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn newer(_: void, a: Row, b: Row) bool {
            return a.modified > b.modified;
        }
    }.newer);
}

/// A transcript's first line, `// <title>` (`Transcript.save`).
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
    const arena = host.arena();
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    const width = if (scroll.si.viewport.w > 0) scroll.si.viewport.w else 200;

    // Registered clients first, in the order they came; then any whose chats are on disk but who
    // are not here (their plugin is not loaded).
    var groups: std.ArrayListUnmanaged([]const u8) = .empty;
    Commands.registeredIds(&groups, arena);
    for (rows.items) |r| {
        for (groups.items) |g| {
            if (std.mem.eql(u8, g, r.client)) break;
        } else groups.append(arena, r.client) catch {};
    }
    if (groups.items.len == 0) {
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
    for (groups.items, 0..) |g, gi| {
        const live = Commands.isRegistered(g);
        {
            var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = gi, .padding = .{ .x = 10, .y = 8, .w = 6, .h = 2 } });
            defer head.deinit();
            if (live) {
                if (dvui.buttonIcon(@src(), "New chat", dvui.entypo.plus, .{}, .{}, .{ .gravity_x = 1, .gravity_y = 0.5, .id_extra = gi, .min_size_content = .{ .w = 12, .h = 12 }, .padding = .all(4), .corners = .all(6) })) newChat(host, g);
            }
            const title = Commands.clientTitle(g) orelse g;
            dvui.labelNoFmt(@src(), title, .{}, .{
                .gravity_y = 0.5,
                .font = theme.font_body.larger(-1).withWeight(.bold),
                .color_text = .{ .color = theme.color(.content, .text).opacity(if (live) 0.75 else 0.45) },
            });
        }
        if (!live) dvui.label(@src(), "needs the {s} plugin", .{g}, .{ .id_extra = gi, .margin = .{ .x = 10 }, .color_text = .{ .color = theme.color(.content, .text).opacity(0.45) }, .font = theme.font_body.larger(-2) });
        for (rows.items, 0..) |r, i| {
            if (!std.mem.eql(u8, r.client, g)) continue;
            const is_active = std.mem.eql(u8, r.path, active);
            var b: dvui.ButtonWidget = undefined;
            b.init(@src(), .{}, .{
                .expand = .horizontal,
                .id_extra = i,
                .margin = .{ .x = 4, .w = 4 },
                .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
                // The open chat on a light wash of the highlight, its text as legible as the rest.
                .background = is_active,
                .color_fill = .{ .color = theme.color(.highlight, .fill).opacity(0.25) },
                .corners = .all(6),
            });
            b.processEvents();
            b.drawBackground();
            // One line, clipped to the sidebar rather than widening it.
            dvui.labelNoFmt(@src(), if (r.title.len > 0) r.title else "New chat", .{}, .{
                .id_extra = i,
                .gravity_y = 0.5,
                .max_size_content = .width(@max(width - 32, 20)),
            });
            if (b.clicked()) _ = host.openFile(.{ .path = r.path }) catch {};
            b.deinit();
        }
    }
    return .ok;
}

/// New, for `client`: its own `chat_new` when it has one (it may want to set the chat up), else a
/// plain new chat of its.
fn newChat(host: *sdk.Host, client: []const u8) void {
    var buf: [128]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{s}.chat_new", .{client}) catch return;
    if (host.command(id) != null) {
        _ = host.callCommand(id, ".{}", host.arena());
        return;
    }
    const path = newPath(host, client) catch |err| return dvui.log.err("chat: could not start a new chat: {t}", .{err});
    defer host.allocator.free(path);
    _ = host.openFile(.{ .path = path }) catch {};
}
