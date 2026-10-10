//! One conversation with one agent, over ACP (`acp.zig`, `Agent.zig`): a document, opened in a
//! tab like any file. Its transcript is a `.chat` file in fizzy's config folder (`Explorer.zig`
//! lists them), saved as each turn ends. Each open chat runs its own agent, started when the
//! person presses Start. UI thread only: `frame` takes what the agent sent since the last frame
//! and acts on it; `draw` shows the conversation and takes what the person types.
//!
//! The agent gets fizzy's tools through `fizzy-mcp`, which the agent plugin installs beside
//! itself: `session/new` names it in `mcpServers`, pointed at this fizzy's profile, so the agent
//! the person talks to is the one driving fizzy. The chat imports nothing of the agent plugin's.
const Chat = @This();

const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const acp = @import("acp.zig");
const Agent = @import("Agent.zig");
const Settings = @import("Settings.zig");
const json = std.json;

gpa: std.mem.Allocator,
host: *sdk.Host,
/// The document: fizzy's id for it, its transcript's path, and the pane it is in.
id: u64,
path: []u8,
grouping: u64 = 0,
/// The tab's name (`documentTitle`): the first thing the person asked, cut short. Empty until then.
title: std.ArrayListUnmanaged(u8) = .empty,
agent: ?*Agent = null,
state: State = .idle,
/// What the agent calls itself (`initialize`'s `agentInfo`).
agent_title: ?[]u8 = null,
session_id: ?[]u8 = null,
next_id: i64 = 1,
/// Our requests still waiting for an answer, by id.
pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
entries: std.ArrayListUnmanaged(Entry) = .empty,
/// What the person is typing.
input: std.ArrayList(u8) = .empty,
/// Scroll to the end on the next draw: something was added.
follow: bool = false,
/// The `fizzy-mcp` handed to the agent, when there is one.
mcp_path: ?[]u8 = null,
/// What the person sent before the agent was ready: sent once the session opens.
queued: ?[]u8 = null,

/// The chat plugin's settings, which every chat reads, and the plugin itself, which owns every
/// chat's `DocHandle` (both set once, in `register`).
pub var settings: *const Settings = undefined;
pub var owner: *sdk.Plugin = undefined;

pub const State = enum { idle, starting, ready, prompting, stopped };
const Pending = enum { initialize, session_new, prompt };

const Entry = struct {
    kind: Kind,
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// `tool`: the agent's `toolCallId`.
    tool_id: []u8 = &.{},
    status: ToolStatus = .pending,
    /// `permission`: the request to answer, and its options, until it is answered (the answer
    /// is then part of `text`).
    request: ?RequestId = null,
    options: []Option = &.{},
    answered: bool = false,

    const Kind = enum { user, agent, thought, tool, plan, permission, note, failure };

    fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        gpa.free(self.tool_id);
        for (self.options) |o| {
            gpa.free(o.id);
            gpa.free(o.name);
        }
        gpa.free(self.options);
        if (self.request) |r| r.deinit(gpa);
    }
};

const ToolStatus = enum { pending, in_progress, completed, failed };
const Option = struct { id: []u8, name: []u8, allow: bool };

/// An agent's request id, kept to answer it: a number or a string, as the agent wrote it.
const RequestId = union(enum) {
    int: i64,
    str: []u8,

    fn of(gpa: std.mem.Allocator, v: json.Value) ?RequestId {
        return switch (v) {
            .integer => |n| .{ .int = n },
            .string => |s| .{ .str = gpa.dupe(u8, s) catch return null },
            else => null,
        };
    }
    fn value(self: RequestId) json.Value {
        return switch (self) {
            .int => |n| .{ .integer = n },
            .str => |s| .{ .string = s },
        };
    }
    fn deinit(self: RequestId, gpa: std.mem.Allocator) void {
        if (self == .str) gpa.free(self.str);
    }
};

/// A chat from its transcript on disk; a path with no file yet is a new, empty chat.
pub fn fromPath(path: []const u8) !Chat {
    const gpa = sdk.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return fromBytes(path, ""),
        else => return err,
    };
    defer gpa.free(bytes);
    return fromBytes(path, bytes);
}

pub fn fromBytes(path: []const u8, bytes: []const u8) !Chat {
    const gpa = sdk.allocator();
    var self: Chat = .{ .gpa = gpa, .host = sdk.host(), .id = sdk.host().allocDocId(), .path = try gpa.dupe(u8, path) };
    errdefer gpa.free(self.path);
    if (std.mem.trim(u8, bytes, " \t\r\n").len > 0) self.load(bytes) catch |err| {
        // A transcript fizzy cannot read still opens: say so, and keep the file as it is.
        self.note("This transcript could not be read ({t}).", .{err});
    };
    self.follow = true;
    return self;
}

/// What a transcript holds: the title, and each entry's kind, text and how its tool call ended.
/// A request still open when it was saved was never answered, and is not kept as one.
const Saved = struct {
    title: []const u8 = "",
    entries: []const struct { kind: Entry.Kind, text: []const u8, status: ToolStatus = .pending } = &.{},
};

fn load(self: *Chat, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const source = try arena_state.allocator().dupeZ(u8, bytes);
    const saved = try std.zon.parse.fromSliceAlloc(Saved, arena_state.allocator(), source, null, .{ .ignore_unknown_fields = true });
    try self.title.appendSlice(self.gpa, saved.title);
    for (saved.entries) |e| {
        const entry = self.add(e.kind) orelse return error.OutOfMemory;
        try entry.text.appendSlice(self.gpa, e.text);
        entry.status = e.status;
        entry.answered = true;
    }
}

/// Write the transcript. Its first line names the chat, so the explorer lists chats without
/// reading whole conversations.
pub fn save(self: *Chat) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Kept = @typeInfo(@FieldType(Saved, "entries")).pointer.child;
    var kept: std.ArrayListUnmanaged(Kept) = .empty;
    for (self.entries.items) |e| try kept.append(arena, .{ .kind = e.kind, .text = e.text.items, .status = e.status });
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("// {s}\n", .{firstLine(self.title.items)});
    try std.zon.stringify.serialize(Saved{ .title = self.title.items, .entries = kept.items }, .{}, &out.writer);
    try out.writer.writeByte('\n');
    if (std.fs.path.dirname(self.path)) |dir| std.Io.Dir.cwd().createDirPath(dvui.io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = self.path, .data = out.written() });
    @import("Explorer.zig").changed();
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

pub fn deinit(self: *Chat) void {
    self.save() catch {};
    self.disconnect();
    if (self.queued) |q| self.gpa.free(q);
    for (self.entries.items) |*e| e.deinit(self.gpa);
    self.entries.deinit(self.gpa);
    self.input.deinit(self.gpa);
    self.pending.deinit(self.gpa);
    self.title.deinit(self.gpa);
    self.gpa.free(self.path);
}

fn wake() void {
    sdk.host().refresh();
}

// ---- starting and stopping ------------------------------------------------------------------

/// Start the agent the settings name and open a session with it.
pub fn connect(self: *Chat) void {
    self.disconnect();
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = std.mem.trim(u8, settings.agent_command.get(), " \t");
    if (line.len == 0) return self.fail("No agent to run. Set one in Settings > Chat: a command line for an agent " ++
        "that speaks the Agent Client Protocol, such as `npx -y @agentclientprotocol/claude-agent-acp`.", .{});
    const argv = acp.splitCommand(arena, line) catch return self.fail("Could not read the agent command.", .{});
    const cwd = self.host.folder() orelse std.mem.span(std.c.getenv("HOME") orelse "/".ptr);
    self.agent = Agent.start(self.gpa, dvui.io, argv, cwd, wake) catch |err| switch (err) {
        error.SpawnFailed => return self.fail("Could not start `{s}`. Is it installed, and on your shell's PATH?", .{argv[0]}),
        else => return self.fail("Could not start the agent: {t}", .{err}),
    };
    self.state = .starting;
    if (self.entries.items.len > 0) {
        self.note("Starting `{s}` in a new session: the agent does not remember what came before.", .{line});
    } else self.note("Starting `{s}`...", .{line});
    self.request(.initialize, "initialize", .{
        .protocolVersion = acp.protocol_version,
        // Reading and writing files through fizzy's open documents, and terminals, come later
        // (plans/AGENTS_PLAN.md, "The chat plugin"): until then the agent uses its own.
        .clientCapabilities = .{ .fs = .{ .readTextFile = false, .writeTextFile = false }, .terminal = false },
        .clientInfo = .{ .name = "fizzy", .title = "Fizzy", .version = "0.1.0" },
    });
}

/// Stop the agent, if one runs. The conversation stays.
pub fn disconnect(self: *Chat) void {
    if (self.agent) |a| a.stop();
    self.agent = null;
    self.pending.clearRetainingCapacity();
    if (self.session_id) |s| self.gpa.free(s);
    self.session_id = null;
    if (self.agent_title) |t| self.gpa.free(t);
    self.agent_title = null;
    if (self.mcp_path) |p| self.gpa.free(p);
    self.mcp_path = null;
    if (self.state != .idle) self.state = .stopped;
    self.cancelPermissions(false);
}

fn openSession(self: *Chat) void {
    const Env = struct { name: []const u8, value: []const u8 };
    const Server = struct { name: []const u8, command: []const u8, args: []const []const u8, env: []const Env };
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // fizzy-mcp finds this fizzy by its profile: the directory holding the plugins directory.
    var servers: []const Server = &.{};
    if (self.findMcp()) |mcp| {
        self.mcp_path = mcp;
        if (self.host.plugins_dir) |plugins| {
            const profile = std.fs.path.dirname(plugins) orelse plugins;
            const args = arena.dupe([]const u8, &.{ "--profile", profile }) catch &.{};
            servers = arena.dupe(Server, &.{.{ .name = "fizzy", .command = mcp, .args = args, .env = &.{} }}) catch &.{};
        }
    } else self.note("fizzy-mcp was not found, so the agent cannot see or drive fizzy. Install the agent plugin, " ++
        "or name fizzy-mcp in Settings > Chat.", .{});

    const cwd = self.host.folder() orelse std.mem.span(std.c.getenv("HOME") orelse "/".ptr);
    self.request(.session_new, "session/new", .{ .cwd = cwd, .mcpServers = servers });
}

/// The setting's fizzy-mcp, else the one beside the agent plugin. Owned by `gpa`.
fn findMcp(self: *Chat) ?[]u8 {
    const set = std.mem.trim(u8, settings.mcp_command.get(), " \t");
    if (set.len > 0) return self.gpa.dupe(u8, set) catch null;
    const dir = self.host.pluginInstallDir("agent") orelse return null;
    defer self.host.allocator.free(dir);
    const name = if (@import("builtin").os.tag == .windows) "fizzy-mcp.exe" else "fizzy-mcp";
    const path = std.fs.path.join(self.gpa, &.{ dir, name }) catch return null;
    std.Io.Dir.accessAbsolute(dvui.io, path, .{ .execute = true }) catch {
        self.gpa.free(path);
        return null;
    };
    return path;
}

// ---- talking --------------------------------------------------------------------------------

/// What the person typed: the next turn now, or once the agent is ready (starting it if none
/// runs). Nothing typed is dropped for being early. True when it was taken.
pub fn send(self: *Chat, text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or self.queued != null) return false;
    switch (self.state) {
        .ready => self.prompt(trimmed),
        .prompting => return false,
        .starting, .idle, .stopped => {
            self.queued = self.gpa.dupe(u8, trimmed) catch return false;
            if (self.agent == null) self.connect();
            // It did not start: the message goes back where it was typed, not lost.
            if (self.agent == null) {
                self.unqueue();
                return false;
            }
        },
    }
    return true;
}

/// Put a queued message back in the input box: the agent will not take it.
fn unqueue(self: *Chat) void {
    const q = self.queued orelse return;
    self.queued = null;
    defer self.gpa.free(q);
    if (self.input.items.len == 0) self.input.appendSlice(self.gpa, q) catch {};
}

fn prompt(self: *Chat, text: []const u8) void {
    const session = self.session_id orelse return;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or self.state != .ready) return;
    const e = self.add(.user) orelse return;
    e.text.appendSlice(self.gpa, trimmed) catch {};
    // The chat is named by the first thing asked in it.
    if (self.title.items.len == 0) {
        const line = firstLine(trimmed);
        self.title.appendSlice(self.gpa, line[0..@min(line.len, 60)]) catch {};
        if (line.len > 60) self.title.appendSlice(self.gpa, "...") catch {};
        // The tab follows (`documentTitle`); the Host keeps its own copy.
        self.host.documentTitleChanged(.{ .ptr = self, .id = self.id, .owner = owner });
    }
    const Block = struct { type: []const u8, text: []const u8 };
    self.request(.prompt, "session/prompt", .{ .sessionId = session, .prompt = &[_]Block{.{ .type = "text", .text = trimmed }} });
    self.state = .prompting;
}

/// Ask the agent to stop the turn it is on. It answers the prompt with `cancelled`.
pub fn cancel(self: *Chat) void {
    const session = self.session_id orelse return;
    if (self.state != .prompting) return;
    self.cancelPermissions(true);
    self.write(acp.writeNotification, .{ "session/cancel", .{ .sessionId = session } });
}

fn request(self: *Chat, what: Pending, method: []const u8, params: anytype) void {
    const id = self.next_id;
    self.next_id += 1;
    self.pending.put(self.gpa, id, what) catch return;
    self.write(acp.writeRequest, .{ id, method, params });
}

/// Write one message with `writer` (an `acp.write*`) and send it.
fn write(self: *Chat, comptime writer: anytype, args: anytype) void {
    const agent = self.agent orelse return;
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    @call(.auto, writer, .{&out.writer} ++ args) catch return;
    agent.send(out.written()) catch self.fail("Could not write to the agent.", .{});
}

// ---- what the agent sends -------------------------------------------------------------------

/// Act on what the agent sent since the last frame. Once a frame, from `beginFrame`.
pub fn frame(self: *Chat) void {
    const agent = self.agent orelse return;
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer lines.deinit(self.gpa);
    const exited = agent.take(&lines);
    for (lines.items) |line| {
        defer self.gpa.free(line);
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const v = json.parseFromSliceLeaky(json.Value, arena_state.allocator(), line, .{}) catch continue;
        self.handle(acp.Inbound.classify(v));
    }
    if (exited and self.agent != null) {
        var buf: [600]u8 = undefined;
        const why = std.mem.trim(u8, agent.stderrTail(&buf), " \t\r\n");
        if (why.len > 0) self.fail("The agent stopped:\n{s}", .{why}) else self.fail("The agent stopped.", .{});
        self.disconnect();
        self.unqueue();
    }
}

fn handle(self: *Chat, msg: acp.Inbound) void {
    switch (msg) {
        .response => |r| {
            const what = (self.pending.fetchRemove(r.id) orelse return).value;
            if (r.err) |err| return self.refused(what, err);
            self.answered(what, r.result orelse .null);
        },
        .notification => |n| if (std.mem.eql(u8, n.method, "session/update")) self.update(n.params),
        .request => |q| {
            if (std.mem.eql(u8, q.method, "session/request_permission")) return self.askPermission(q.id, q.params);
            // Files and terminals are not offered (`initialize`'s capabilities): say so.
            self.write(acp.writeError, .{ q.id, acp.method_not_found, "fizzy's chat does not offer this yet" });
        },
        .invalid => {},
    }
}

fn answered(self: *Chat, what: Pending, result: json.Value) void {
    switch (what) {
        .initialize => {
            if (field(field(result, "agentInfo"), "title") orelse field(field(result, "agentInfo"), "name")) |t| if (t == .string) {
                self.agent_title = self.gpa.dupe(u8, t.string) catch null;
            };
            self.openSession();
        },
        .session_new => {
            const id = field(result, "sessionId") orelse return self.fail("The agent opened no session.", .{});
            if (id != .string) return self.fail("The agent opened no session.", .{});
            self.session_id = self.gpa.dupe(u8, id.string) catch null;
            self.state = .ready;
            if (self.mcp_path != null) self.note("Connected. The agent can see and drive fizzy.", .{}) else self.note("Connected.", .{});
            if (self.queued) |q| {
                self.queued = null;
                defer self.gpa.free(q);
                self.prompt(q);
            }
        },
        .prompt => {
            self.state = .ready;
            self.cancelPermissions(false);
            if (field(result, "stopReason")) |reason| {
                if (reason == .string and !std.mem.eql(u8, reason.string, "end_turn")) self.note("Stopped: {s}.", .{reason.string});
            }
            // A turn is over: keep it.
            self.save() catch |err| self.fail("Could not save this chat: {t}", .{err});
        },
    }
}

fn refused(self: *Chat, what: Pending, err: []const u8) void {
    switch (what) {
        .initialize, .session_new => {
            // An agent that needs signing in says so here: its own CLI does that, once.
            self.fail("The agent refused to start: {s}", .{err});
            self.disconnect();
            self.unqueue();
        },
        .prompt => {
            self.state = .ready;
            self.fail("{s}", .{err});
        },
    }
}

/// `session/update`: what the agent is saying, thinking and doing.
fn update(self: *Chat, params: json.Value) void {
    const u = field(params, "update") orelse return;
    const kind = str(field(u, "sessionUpdate")) orelse return;
    if (std.mem.eql(u8, kind, "agent_message_chunk")) {
        self.appendText(.agent, field(u, "content"));
    } else if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
        self.appendText(.thought, field(u, "content"));
    } else if (std.mem.eql(u8, kind, "tool_call")) {
        const e = self.add(.tool) orelse return;
        e.tool_id = self.gpa.dupe(u8, str(field(u, "toolCallId")) orelse "") catch &.{};
        e.text.appendSlice(self.gpa, str(field(u, "title")) orelse "A tool") catch {};
        e.status = status(str(field(u, "status")));
    } else if (std.mem.eql(u8, kind, "tool_call_update")) {
        const e = self.toolEntry(str(field(u, "toolCallId")) orelse return) orelse return;
        if (str(field(u, "status"))) |s| e.status = status(s);
        if (str(field(u, "title"))) |t| {
            e.text.clearRetainingCapacity();
            e.text.appendSlice(self.gpa, t) catch {};
        }
    } else if (std.mem.eql(u8, kind, "plan")) {
        // The plan as it stands now: a fresh entry each time, so the conversation shows how it moved.
        const entries = field(u, "entries") orelse return;
        if (entries != .array) return;
        const e = self.add(.plan) orelse return;
        for (entries.array.items) |item| {
            const done = if (str(field(item, "status"))) |s| std.mem.eql(u8, s, "completed") else false;
            e.text.print(self.gpa, "{s} {s}\n", .{ if (done) "[x]" else "[ ]", str(field(item, "content")) orelse "" }) catch {};
        }
    }
}

/// Append a text content block to the conversation's last entry of `kind`, or a new one.
fn appendText(self: *Chat, kind: Entry.Kind, content: ?json.Value) void {
    const c = content orelse return;
    if (!std.mem.eql(u8, str(field(c, "type")) orelse "", "text")) return;
    const text = str(field(c, "text")) orelse return;
    const last = if (self.entries.items.len > 0) &self.entries.items[self.entries.items.len - 1] else null;
    const e = if (last != null and last.?.kind == kind) last.? else self.add(kind) orelse return;
    e.text.appendSlice(self.gpa, text) catch {};
    self.follow = true;
}

/// `session/request_permission`: shown in the conversation, the agent's own options its buttons.
fn askPermission(self: *Chat, id: json.Value, params: json.Value) void {
    const rid = RequestId.of(self.gpa, id) orelse return;
    const e = self.add(.permission) orelse return rid.deinit(self.gpa);
    e.request = rid;
    const call = field(params, "toolCall");
    const title = str(field(call orelse .null, "title")) orelse
        if (self.toolEntry(str(field(call orelse .null, "toolCallId")) orelse "")) |t| t.text.items else "use a tool";
    e.text.print(self.gpa, "The agent asks to {s}.", .{title}) catch {};
    const opts = field(params, "options") orelse return;
    if (opts != .array) return;
    var list: std.ArrayListUnmanaged(Option) = .empty;
    for (opts.array.items) |o| {
        const oid = str(field(o, "optionId")) orelse continue;
        const kind = str(field(o, "kind")) orelse "";
        list.append(self.gpa, .{
            .id = self.gpa.dupe(u8, oid) catch continue,
            .name = self.gpa.dupe(u8, str(field(o, "name")) orelse oid) catch continue,
            .allow = std.mem.startsWith(u8, kind, "allow"),
        }) catch {};
    }
    e.options = list.toOwnedSlice(self.gpa) catch &.{};
}

fn choose(self: *Chat, e: *Entry, option: Option) void {
    const rid = e.request orelse return;
    self.write(acp.writeResult, .{ rid.value(), .{ .outcome = .{ .outcome = "selected", .optionId = option.id } } });
    answer(self.gpa, e, option.name);
}

fn answer(gpa: std.mem.Allocator, e: *Entry, what: []const u8) void {
    e.answered = true;
    e.text.print(gpa, "\nAnswered: {s}", .{what}) catch {};
}

/// Answer every open permission request as cancelled (`send_answer`), or just close them.
fn cancelPermissions(self: *Chat, send_answer: bool) void {
    for (self.entries.items) |*e| {
        if (e.kind != .permission or e.answered) continue;
        if (send_answer) if (e.request) |rid| self.write(acp.writeResult, .{ rid.value(), .{ .outcome = .{ .outcome = "cancelled" } } });
        answer(self.gpa, e, "cancelled");
    }
}

// ---- the conversation -----------------------------------------------------------------------

fn add(self: *Chat, kind: Entry.Kind) ?*Entry {
    self.entries.append(self.gpa, .{ .kind = kind }) catch return null;
    self.follow = true;
    return &self.entries.items[self.entries.items.len - 1];
}

fn note(self: *Chat, comptime fmt: []const u8, args: anytype) void {
    const e = self.add(.note) orelse return;
    e.text.print(self.gpa, fmt, args) catch {};
}

fn fail(self: *Chat, comptime fmt: []const u8, args: anytype) void {
    const e = self.add(.failure) orelse return;
    e.text.print(self.gpa, fmt, args) catch {};
}

fn toolEntry(self: *Chat, id: []const u8) ?*Entry {
    var i = self.entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = &self.entries.items[i];
        if (e.kind == .tool and std.mem.eql(u8, e.tool_id, id)) return e;
    }
    return null;
}

fn field(v: ?json.Value, name: []const u8) ?json.Value {
    const o = v orelse return null;
    if (o != .object) return null;
    return o.object.get(name);
}

fn str(v: ?json.Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

fn status(s: ?[]const u8) ToolStatus {
    const t = s orelse return .pending;
    return std.meta.stringToEnum(ToolStatus, t) orelse .pending;
}

// ---- the panel ------------------------------------------------------------------------------

pub fn draw(self: *Chat) !dvui.App.Result {
    const theme = dvui.themeGet();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer col.deinit();

    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(6) });
        defer bar.deinit();
        // The region already titles the panel "Chat": name the agent once one says who it is.
        if (self.agent_title) |t| dvui.label(@src(), "{s}", .{t}, .{ .gravity_y = 0.5, .font = theme.font_heading });
        const what: []const u8 = switch (self.state) {
            .idle => "",
            .starting => "starting...",
            .ready => "ready",
            .prompting => "working...",
            .stopped => "stopped",
        };
        dvui.label(@src(), "{s}", .{what}, .{ .gravity_y = 0.5, .color_text = .{ .color = theme.color(.content, .text).opacity(0.6) } });
        const action: []const u8 = switch (self.state) {
            .idle, .stopped => "Start",
            .prompting => "Stop",
            .starting, .ready => "Restart",
        };
        if (dvui.button(@src(), action, .{}, .{ .gravity_x = 1, .gravity_y = 0.5 })) switch (self.state) {
            .prompting => self.cancel(),
            else => self.connect(),
        };
    }

    {
        // Wrapped to the panel's width, never wider: the conversation scrolls one way.
        var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both });
        defer scroll.deinit();
        // A text layout's minimum width is its text unwrapped (dvui's TextLayoutWidget), which
        // would widen the panel past its place instead of wrapping: cap each at the viewport.
        const width: ?f32 = if (scroll.si.viewport.w > 0) scroll.si.viewport.w else null;
        if (self.entries.items.len == 0) {
            var hint = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .max_size_content = if (width) |w| .{ .w = w - 20, .h = std.math.floatMax(f32) } else null,
                .padding = .all(10),
                .color_text = .{ .color = theme.color(.content, .text).opacity(0.6) },
            });
            hint.addText("Ask the agent anything: sending starts the one set in Settings > Chat.", .{});
            hint.deinit();
        }
        for (self.entries.items, 0..) |*e, i| self.drawEntry(e, i, width);
        if (self.follow) {
            self.follow = false;
            scroll.si.scrollToOffset(.vertical, std.math.floatMax(f32));
        }
    }

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(6) });
        defer row.deinit();
        const te = dvui.textEntry(@src(), .{
            .text = .{ .array_list = .{ .backing = &self.input, .allocator = self.gpa, .limit = 64 * 1024 } },
            .placeholder = "Ask the agent...",
        }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            // Narrow enough to fit any panel (dvui's default is a dozen M's wide), a line tall.
            .min_size_content = theme.font_body.sizeM(3, 1),
        });
        const enter = te.enter_pressed;
        te.deinit();
        const clicked = dvui.button(@src(), "Send", .{}, .{ .gravity_y = 0.5 });
        if ((enter or clicked) and self.send(self.input.items)) self.input.clearRetainingCapacity();
    }
    return .ok;
}

fn drawEntry(self: *Chat, e: *Entry, i: usize, width: ?f32) void {
    const theme = dvui.themeGet();
    const faded: dvui.Options = .{ .color_text = .{ .color = theme.color(.content, .text).opacity(0.6) } };
    const base: dvui.Options = .{
        .expand = .horizontal,
        .margin = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        .padding = .all(6),
        .id_extra = i,
        // Margins and padding outside the content: 16 + 12.
        .max_size_content = if (width) |w| .{ .w = @max(w - 28, 20), .h = std.math.floatMax(f32) } else null,
    };
    switch (e.kind) {
        .user, .agent, .thought, .plan, .note, .failure => {
            var opts = base;
            switch (e.kind) {
                .user => {
                    opts.background = true;
                    opts.color_fill = .{ .color = theme.color(.control, .fill) };
                    opts.corners = .all(6);
                },
                .thought, .note, .plan => opts = opts.override(faded),
                .failure => opts.color_text = .{ .color = theme.color(.err, .text) },
                else => {},
            }
            var tl = dvui.textLayout(@src(), .{}, opts);
            defer tl.deinit();
            tl.addText(e.text.items, .{});
        },
        .tool => {
            const mark: []const u8 = switch (e.status) {
                .pending => "waiting:",
                .in_progress => "running:",
                .completed => "done:",
                .failed => "failed:",
            };
            var tl = dvui.textLayout(@src(), .{}, base.override(faded));
            defer tl.deinit();
            tl.addText(mark, .{});
            tl.addText(" ", .{});
            tl.addText(e.text.items, .{});
        },
        .permission => {
            var box = dvui.box(@src(), .{ .dir = .vertical }, base.override(.{ .background = true, .corners = .all(6), .color_fill = .{ .color = theme.color(.highlight, .fill).opacity(0.15) } }));
            defer box.deinit();
            {
                var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
                defer tl.deinit();
                tl.addText(e.text.items, .{});
            }
            if (e.answered) return;
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer row.deinit();
            for (e.options, 0..) |o, n| {
                const style: dvui.Theme.Style.Name = if (o.allow) .highlight else .control;
                if (dvui.button(@src(), o.name, .{}, .{ .id_extra = n, .style = style })) self.choose(e, o);
            }
        },
    }
}
