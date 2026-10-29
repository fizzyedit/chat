//! The chat's contract with its clients: internal commands, ZON in and out (`api.zig`,
//! plans/CHAT_PLAN.md). A client registers (`chat.register`), opens chats and posts into them;
//! what the person does goes back to that client's own commands (`<client>.chat_send`, …), and to
//! no other client. Nothing here is in fizzy's SDK: the contract is this plugin's, versioned by
//! `api.version`.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const api = @import("api.zig");
const Chat = @import("Chat.zig");
const Explorer = @import("Explorer.zig");

/// Every open chat, by document id: the plugin's, read here to find a chat by its chat id.
pub var chats: *std.AutoArrayHashMapUnmanaged(u64, *Chat) = undefined;

/// Chats a client opened that fizzy has not finished opening (it reads files off the UI thread):
/// posts land here, and the document adopts them when it registers (`adopt`).
var opening: std.ArrayListUnmanaged(*Chat) = .empty;

const Client = struct { id: []u8, title: []u8, version: u32, history: api.History };
/// The registered clients, by id.
var clients: std.ArrayListUnmanaged(Client) = .empty;

pub fn deinit(gpa: std.mem.Allocator) void {
    for (clients.items) |c| freeClient(gpa, c);
    clients.deinit(gpa);
    for (opening.items) |c| {
        c.deinit();
        gpa.destroy(c);
    }
    opening.deinit(gpa);
}

/// A chat document has registered: if a client opened it and has posted into it already, the
/// document takes over what was posted.
pub fn adopt(c: *Chat) void {
    for (opening.items, 0..) |o, i| if (std.mem.eql(u8, o.path, c.path)) {
        _ = opening.swapRemove(i);
        std.mem.swap(@TypeOf(c.transcript), &c.transcript, &o.transcript);
        std.mem.swap(@TypeOf(c.title), &c.title, &o.title);
        std.mem.swap([]u8, &c.resume_state, &o.resume_state);
        std.mem.swap([]u8, &c.folder, &o.folder);
        c.busy = o.busy;
        c.resumed = o.resumed;
        c.header_dirty = true;
        o.saved_version = o.transcript.version; // nothing of its own left to save
        o.header_dirty = false;
        o.deinit();
        sdk.allocator().destroy(o);
        c.host.documentTitleChanged(c.handle());
        return;
    };
}

fn freeClient(gpa: std.mem.Allocator, c: Client) void {
    gpa.free(c.id);
    gpa.free(c.title);
}

pub fn isRegistered(id: []const u8) bool {
    return clientIndex(id) != null;
}

/// The title a client registered with, for its group in the list.
pub fn clientTitle(id: []const u8) ?[]const u8 {
    return clients.items[clientIndex(id) orelse return null].title;
}

/// Whether the client holds `id`'s conversations itself (`api.History`): the chat then writes none
/// of them. A client that is not registered has no say: its chats stay on disk as they were.
pub fn clientKeeps(id: []const u8) bool {
    return (clients.items[clientIndex(id) orelse return false]).history == .client;
}

pub fn registeredIds(out: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator) void {
    for (clients.items) |c| out.append(arena, c.id) catch {};
}

fn clientIndex(id: []const u8) ?usize {
    for (clients.items, 0..) |c, i| if (std.mem.eql(u8, c.id, id)) return i;
    return null;
}

pub fn chatFor(id: api.ChatId) ?*Chat {
    for (chats.values()) |c| if (c.chat_id == id) return c;
    for (opening.items) |c| if (c.chat_id == id) return c;
    return null;
}

/// Call `<client>.<name>` with `args`, when the client registered it. What the person did, handed
/// to the client that owns the chat; a client without the command does not offer that.
pub fn callClient(client: []const u8, comptime name: []const u8, args: anytype) void {
    if (!isRegistered(client)) return;
    const host = sdk.host();
    var buf: [128]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{s}." ++ name, .{client}) catch return;
    if (host.command(id) == null) return;
    const arena = host.arena();
    const zon = api.write(arena, args) catch return;
    switch (host.callCommand(id, zon, arena)) {
        .ok => {},
        else => |o| dvui.log.warn("chat: {s} refused: {any}", .{ id, o }),
    }
}

/// Hand a chat its client's saved state, once per registration, when both are there.
pub fn resumeChat(c: *Chat) void {
    if (c.resumed or c.resume_state.len == 0 or !isRegistered(c.client_id)) return;
    c.resumed = true;
    callClient(c.client_id, "chat_resume", api.Resume{ .chat = c.chat_id, .state = c.resume_state });
}

/// The chat is going away (its tab closed, or this plugin unloading): tell its client.
pub fn closed(c: *Chat) void {
    callClient(c.client_id, "chat_closed", api.ChatOnly{ .chat = c.chat_id });
}

fn changed(c: *Chat) void {
    c.view.contentChanged();
    sdk.host().refresh();
}

// ---- registration ---------------------------------------------------------------------------

pub fn register(host: *sdk.Host, owner: *sdk.Plugin) !void {
    inline for (.{
        .{ "register", api.Register, cmdRegister },
        .{ "unregister", api.Unregister, cmdUnregister },
        .{ "open", api.Open, cmdOpen },
        .{ "post", api.Post, cmdPost },
        .{ "append_text", api.AppendText, cmdAppendText },
        .{ "append", api.Append, cmdAppend },
        .{ "tool", api.AddTool, cmdTool },
        .{ "update_tool", api.UpdateTool, cmdUpdateTool },
        .{ "set_plan", api.SetPlan, cmdSetPlan },
        .{ "ask", api.Ask, cmdAsk },
        .{ "unask", api.Unask, cmdUnask },
        .{ "set_busy", api.SetBusy, cmdSetBusy },
        .{ "set_title", api.SetTitle, cmdSetTitle },
        .{ "set_resume", api.SetResume, cmdSetResume },
        .{ "focus", api.Focus, cmdFocus },
        .{ "set_settings", api.SetSettings, cmdSetSettings },
        .{ "attach", api.Attach, cmdAttach },
        .{ "delete", api.Delete, cmdDelete },
    }) |entry| {
        try host.registerCommand(.{
            .id = "chat." ++ entry[0],
            .owner = owner,
            .title = "Chat: " ++ entry[0],
            .visibility = .internal,
            .runWith = Handler(entry[1], entry[2]).run,
        });
    }
}

/// A command's `runWith`: its arguments parsed into `Args`, then `f`. A malformed call is answered
/// with why, in words, as a bad call.
fn Handler(comptime Args: type, comptime f: fn (Args, *sdk.Command.Call) anyerror!void) type {
    return struct {
        fn run(_: *anyopaque, call: *sdk.Command.Call) anyerror!void {
            const args = api.parse(Args, call.arena, call.args) catch |err| {
                call.bad_args = true;
                return call.fail("expected {s} (api.zig): {t}", .{ @typeName(Args), err });
            };
            return f(args, call);
        }
    };
}

/// The chat whose tab is in front, if the document in front is a chat.
fn front() ?*Chat {
    const doc = sdk.host().activeDoc() orelse return null;
    for (chats.values()) |c| if (c.id == doc.id) return c;
    return null;
}

fn find(id: api.ChatId, call: *sdk.Command.Call) !*Chat {
    return chatFor(id) orelse call.fail("no chat {d} is open", .{id});
}

/// The person's messages come only from their typing.
fn notPerson(author: api.Author, call: *sdk.Command.Call) !void {
    if (author == .person) return call.fail("a client posts as .other or .note, never as the person", .{});
}

fn cmdRegister(a: api.Register, call: *sdk.Command.Call) !void {
    if (a.version > api.version) return call.fail("this chat speaks version {d} of the contract; {s} asked for {d}", .{ api.version, a.client, a.version });
    if (a.client.len == 0 or std.mem.indexOfAny(u8, a.client, "/\\.") != null) return call.fail("a client id is a plain name: {s}", .{a.client});
    const gpa = sdk.allocator();
    const entry: Client = .{ .id = try gpa.dupe(u8, a.client), .title = try gpa.dupe(u8, a.title), .version = a.version, .history = a.history };
    if (clientIndex(a.client)) |i| {
        freeClient(gpa, clients.items[i]);
        clients.items[i] = entry;
    } else try clients.append(gpa, entry);
    for (chats.values()) |c| if (std.mem.eql(u8, c.client_id, a.client)) {
        c.resumed = false;
        resumeChat(c);
        changed(c);
    };
    Explorer.changed();
}

fn cmdUnregister(a: api.Unregister, _: *sdk.Command.Call) !void {
    const i = clientIndex(a.client) orelse return;
    freeClient(sdk.allocator(), clients.orderedRemove(i));
    // Its chats stay open, read-only: nothing they show depended on it.
    for (chats.values()) |c| if (std.mem.eql(u8, c.client_id, a.client)) {
        c.busy = false;
        c.transcript.cancelQuestions();
        changed(c);
    };
    Explorer.changed();
}

fn cmdOpen(a: api.Open, call: *sdk.Command.Call) !void {
    if (!isRegistered(a.client)) return call.fail("{s} is not registered (chat.register)", .{a.client});
    const host = sdk.host();
    const gpa = sdk.allocator();
    const path = try Explorer.newPath(host, a.client, a.folder, clientKeeps(a.client));
    defer host.allocator.free(path);
    // The chat exists from now: what the client posts before fizzy has opened its document waits
    // here, and the document adopts it.
    const c = try gpa.create(Chat);
    errdefer gpa.destroy(c);
    c.* = try Chat.fromPath(path);
    errdefer c.deinit();
    if (a.title.len > 0) {
        c.title.clearRetainingCapacity();
        try c.title.appendSlice(gpa, a.title);
    }
    try opening.append(gpa, c);
    _ = try host.openFile(.{ .path = path });
    try call.returns(api.Opened{ .chat = c.chat_id });
}

/// A block as the transcript keeps it: an image's file read in.
fn resolve(arena: std.mem.Allocator, b: api.Block) !api.Block {
    if (b != .image or b.image.bytes.len > 0) return b;
    var img = b.image;
    // An image arrives as bytes on the web, which has no path to read.
    if (comptime builtin.os.tag == .freestanding) return error.NoFilesOnTheWeb;
    img.bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, img.path, arena, .limited(32 * 1024 * 1024));
    if (img.mime.len == 0) img.mime = mimeOf(img.path);
    return .{ .image = img };
}

fn resolveAll(arena: std.mem.Allocator, blocks: []const api.Block) ![]const api.Block {
    const out = try arena.alloc(api.Block, blocks.len);
    for (blocks, out) |b, *o| o.* = try resolve(arena, b);
    return out;
}

fn mimeOf(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const known = [_][2][]const u8{ .{ ".png", "image/png" }, .{ ".jpg", "image/jpeg" }, .{ ".jpeg", "image/jpeg" }, .{ ".gif", "image/gif" }, .{ ".bmp", "image/bmp" }, .{ ".tga", "image/x-tga" } };
    for (known) |k| if (std.ascii.eqlIgnoreCase(ext, k[0])) return k[1];
    return "application/octet-stream";
}

fn cmdPost(a: api.Post, call: *sdk.Command.Call) !void {
    try notPerson(a.author, call);
    const c = try find(a.chat, call);
    defer changed(c);
    const id = try c.transcript.post(a.author, try resolveAll(call.arena, a.blocks));
    try call.returns(api.Posted{ .message = id });
}

fn cmdAppendText(a: api.AppendText, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    defer changed(c);
    c.transcript.appendText(a.message, a.kind, a.text) catch |err| return call.fail("{t}", .{err});
}

fn cmdAppend(a: api.Append, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    defer changed(c);
    c.transcript.append(a.message, try resolve(call.arena, a.block)) catch |err| return call.fail("{t}", .{err});
}

fn cmdTool(a: api.AddTool, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    defer changed(c);
    var t = a.tool;
    t.content = try resolveAll(call.arena, t.content);
    const id = c.transcript.tool(a.message, t) catch |err| return call.fail("{t}", .{err});
    try call.returns(api.Added{ .tool = id });
}

fn cmdUpdateTool(a: api.UpdateTool, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    defer changed(c);
    var u = a.update;
    if (u.content) |content| u.content = try resolveAll(call.arena, content);
    c.transcript.updateTool(a.tool, u) catch |err| return call.fail("{t}", .{err});
}

fn cmdSetPlan(a: api.SetPlan, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    defer changed(c);
    c.transcript.setPlan(a.message, a.entries) catch |err| return call.fail("{t}", .{err});
}

fn cmdAsk(a: api.Ask, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    defer changed(c);
    const id = c.transcript.ask(a.message, a.question) catch |err| return call.fail("{t}", .{err});
    try call.returns(api.Asked{ .question = id });
}

fn cmdUnask(a: api.Unask, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    c.transcript.cancelQuestion(a.question);
    changed(c);
}

fn cmdSetBusy(a: api.SetBusy, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    c.busy = a.busy;
    // A turn that ended left its questions unanswered: they close with it. The end of a turn is
    // also the natural place to keep the conversation.
    if (!a.busy) {
        c.transcript.cancelQuestions();
        c.save() catch |err| dvui.log.warn("chat: could not save {s}: {t}", .{ c.path, err });
    }
    changed(c);
}

fn cmdSetTitle(a: api.SetTitle, call: *sdk.Command.Call) !void {
    (try find(a.chat, call)).setTitle(a.title);
}

fn cmdSetResume(a: api.SetResume, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    c.setResume(a.state);
    c.resumed = true;
}

fn cmdSetSettings(a: api.SetSettings, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    try c.setSettings(a.settings);
    changed(c);
}

/// What the person's + does, for whoever else attaches: a drop from the file tree, an agent.
fn cmdAttach(a: api.Attach, call: *sdk.Command.Call) !void {
    const c = if (a.chat != 0) try find(a.chat, call) else front() orelse return call.fail("no chat is in front", .{});
    // A path is a file on disk; the web has none to attach.
    if (comptime builtin.os.tag == .freestanding) return call.fail("files cannot be attached on the web", .{});
    std.Io.Dir.cwd().access(dvui.io, a.path, .{}) catch return call.fail("no file at {s}", .{a.path});
    c.attach(a.path);
    changed(c);
}

fn cmdDelete(a: api.Delete, call: *sdk.Command.Call) !void {
    const path = if (a.path.len > 0) a.path else (front() orelse return call.fail("no chat is in front", .{})).path;
    if (!Explorer.delete(sdk.host(), path)) return call.fail("no chat {s} is in the list", .{path});
}

fn cmdFocus(a: api.Focus, call: *sdk.Command.Call) !void {
    const c = try find(a.chat, call);
    _ = try sdk.host().openFile(.{ .path = c.path });
}
