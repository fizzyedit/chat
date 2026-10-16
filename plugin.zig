//! Conversations in fizzy, for any plugin (fizzyedit/plans, `plans/CHAT_PLAN.md`). The chat is to
//! conversations what the workbench is to files: it owns the tabs, the transcripts, the list and
//! how a conversation is drawn, and knows nothing of who is on the other end. A plugin with someone
//! to talk to is a client: it registers and posts through the chat's commands (`src/api.zig`,
//! `src/Commands.zig`), and the chat calls it back on its own.
//!
//! A conversation is a document: a `.chat` transcript, opened in a tab like any file
//! (`src/Chat.zig`, drawn by `src/View.zig`), kept under its client's folder and listed under its
//! client's group in the sidebar (`src/Explorer.zig`). Agents over ACP are a client here for now
//! (`src/AcpClient.zig`), on their way to the agent plugin.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const Chat = @import("src/Chat.zig");
const View = @import("src/View.zig");
const Commands = @import("src/Commands.zig");
const AcpClient = @import("src/AcpClient.zig");
const Explorer = @import("src/Explorer.zig");
const Settings = @import("src/Settings.zig");
const DocHandle = sdk.DocHandle;

pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .beginFrame = beginFrame,
    .deinit = deinit,
    .fileTypes = fileTypes,
    .documentStackSize = documentStackSize,
    .documentStackAlign = documentStackAlign,
    .loadDocument = loadDocument,
    .loadDocumentFromBytes = loadDocumentFromBytes,
    .documentIdFromBuffer = documentIdFromBuffer,
    .setDocumentGroupingOnBuffer = setDocumentGroupingOnBuffer,
    .deinitDocumentBuffer = deinitDocumentBuffer,
    .registerOpenDocument = registerOpenDocument,
    .documentPtr = documentPtr,
    .documentByPath = documentByPath,
    .unregisterDocument = unregisterDocument,
    .documentGrouping = documentGrouping,
    .setDocumentGrouping = setDocumentGrouping,
    .documentPath = documentPath,
    .setDocumentPath = setDocumentPath,
    .documentTitle = documentTitle,
    .bindDocumentToPane = bindDocumentToPane,
    .documentHasNativeExtension = yes,
    .documentHasRecognizedSaveExtension = yes,
    .drawDocument = drawDocument,
    .closeDocument = closeDocument,
    .reloadDocument = reloadDocument,
    .captureDocumentState = captureDocumentState,
    .restoreDocumentState = restoreDocumentState,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
};

const Schema = sdk.settings.Schema(Settings);

var settings: Settings = .{};
/// Every open chat, by document id. Heap-allocated so a chat never moves: its agent's reader
/// thread wakes the app, and the UI thread finds the chat here.
var chats: std.AutoArrayHashMapUnmanaged(u64, *Chat) = .empty;

pub fn register(host: *sdk.Host) !void {
    Schema.load(host, plugin_id, &settings);
    AcpClient.settings = &settings;
    Chat.owner = &plugin;
    Commands.chats = &chats;
    plugin.state = @ptrCast(&settings);
    try host.registerPlugin(&plugin);
    try Schema.register(host, &plugin, .{ .title = "Chat", .value = &settings });
    try host.registerSurface(.{
        .id = "chat.chats",
        .owner = &plugin,
        .icon = .{ .tvg = dvui.entypo.chat },
        .title = "Chats",
        .keywords = sdk.keywords.ide.sidebar,
        .draw = drawExplorer,
    });
    try Commands.register(host, &plugin);
    // Clients of the chat, through its commands like any other plugin.
    try AcpClient.register(host, &plugin);
}

fn drawExplorer(_: ?*anyopaque) anyerror!dvui.App.Result {
    return Explorer.draw(sdk.host());
}

fn beginFrame(_: *anyopaque) void {
    AcpClient.frame();
    Explorer.frame(sdk.host());
}

fn deinit(_: *anyopaque) void {
    const gpa = sdk.allocator();
    for (chats.values()) |c| {
        Commands.closed(c);
        View.release(c);
        c.deinit();
        gpa.destroy(c);
    }
    chats.deinit(gpa);
    AcpClient.deinit(gpa);
    Commands.deinit(gpa);
    Explorer.deinit(gpa);
}

// ---- documents ------------------------------------------------------------------------------

fn fileTypes(_: *anyopaque) []const []const u8 {
    return &.{".chat"};
}
fn documentStackSize(_: *anyopaque) usize {
    return @sizeOf(Chat);
}
fn documentStackAlign(_: *anyopaque) usize {
    return @alignOf(Chat);
}
fn loadDocument(_: *anyopaque, path: []const u8, out: *anyopaque) anyerror!void {
    try sdk.document.loadPathInto(Chat, path, buf(out));
}
fn loadDocumentFromBytes(_: *anyopaque, path: []const u8, bytes: []const u8, out: *anyopaque) anyerror!void {
    try sdk.document.loadBytesInto(Chat, path, bytes, buf(out));
}
fn documentIdFromBuffer(_: *anyopaque, doc: *anyopaque) u64 {
    return buf(doc).id;
}
fn setDocumentGroupingOnBuffer(_: *anyopaque, doc: *anyopaque, grouping: u64) void {
    buf(doc).grouping = grouping;
}
fn deinitDocumentBuffer(_: *anyopaque, doc: *anyopaque) void {
    buf(doc).deinit();
}
fn registerOpenDocument(_: *anyopaque, staged: *anyopaque) anyerror!*anyopaque {
    const gpa = sdk.allocator();
    const c = try gpa.create(Chat);
    errdefer gpa.destroy(c);
    c.* = buf(staged).*;
    try chats.put(gpa, c.id, c);
    Commands.adopt(c);
    Commands.resumeChat(c);
    return c;
}
fn documentPtr(_: *anyopaque, id: u64) ?*anyopaque {
    return chats.get(id);
}
fn documentByPath(_: *anyopaque, path: []const u8) ?*anyopaque {
    for (chats.values()) |c| if (std.mem.eql(u8, c.path, path)) return c;
    return null;
}
fn unregisterDocument(_: *anyopaque, id: u64) void {
    _ = chats.swapRemove(id);
}
fn documentGrouping(_: *anyopaque, handle: DocHandle) u64 {
    return (from(handle) orelse return 0).grouping;
}
fn setDocumentGrouping(_: *anyopaque, handle: DocHandle, grouping: u64) void {
    (from(handle) orelse return).grouping = grouping;
}
fn documentPath(_: *anyopaque, handle: DocHandle) []const u8 {
    return (from(handle) orelse return "").path;
}
fn setDocumentPath(_: *anyopaque, handle: DocHandle, path: []const u8) anyerror!void {
    const c = from(handle) orelse return error.DocumentNotFound;
    const gpa = sdk.allocator();
    const new = try gpa.dupe(u8, path);
    gpa.free(c.path);
    c.path = new;
}
/// The tab reads as the chat's first question, not its file name.
fn documentTitle(_: *anyopaque, handle: DocHandle) ?[]const u8 {
    const c = from(handle) orelse return null;
    return if (c.title.items.len > 0) c.title.items else "New chat";
}
fn bindDocumentToPane(_: *anyopaque, _: DocHandle, _: dvui.Id, _: *anyopaque, _: bool) void {}
fn yes(_: *anyopaque, _: DocHandle) bool {
    return true;
}
fn drawDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const c = from(handle) orelse return;
    _ = try View.draw(c);
}
/// Closing a chat's tab saves it and tells its client; the transcript stays in the list.
fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    const c = from(handle) orelse return;
    Commands.closed(c);
    View.release(c);
    c.deinit();
    _ = chats.swapRemove(c.id);
    sdk.allocator().destroy(c);
}
/// A transcript is written by the chat itself as each turn ends; one changed on disk while open
/// is the chat's own write, and needs no reload.
fn reloadDocument(_: *anyopaque, _: DocHandle) anyerror!void {}
/// What a chat carries across a reload of this plugin (and a demo's snapshot): its transcript,
/// which it saves here and reads back on restore, and the message being typed, carried in the
/// bytes. A version byte first, so a build that reads it differently refuses it rather than
/// misreading it.
const state_version: u8 = 1;
fn captureDocumentState(_: *anyopaque, handle: DocHandle, allocator: std.mem.Allocator) anyerror![]u8 {
    const c = from(handle) orelse return error.DocumentNotFound;
    try c.save();
    const out = try allocator.alloc(u8, 1 + c.input.items.len);
    out[0] = state_version;
    @memcpy(out[1..], c.input.items);
    return out;
}
fn restoreDocumentState(_: *anyopaque, handle: DocHandle, bytes: []const u8) anyerror!void {
    const c = from(handle) orelse return error.DocumentNotFound;
    if (bytes.len < 1 or bytes[0] != state_version) return error.BadState;
    try c.reloadTranscript();
    c.host.documentTitleChanged(handle);
    Commands.resumeChat(c);
    c.input.clearRetainingCapacity();
    try c.input.appendSlice(c.gpa, bytes[1..]);
}
fn isDirty(_: *anyopaque, _: DocHandle) bool {
    return false;
}
fn saveDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    try (from(handle) orelse return).save();
}

fn buf(p: *anyopaque) *Chat {
    return @ptrCast(@alignCast(p));
}
fn from(handle: DocHandle) ?*Chat {
    return chats.get(handle.id);
}
