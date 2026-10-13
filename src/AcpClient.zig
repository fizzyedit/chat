//! Agents over the Agent Client Protocol, as a client of the chat (`api.zig`): for now inside the
//! chat plugin, and moving to the agent plugin next (plans/CHAT_PLAN.md, step 3). It already talks
//! to the chat only through the chat's commands (`chat.post`, `chat.tool`, …) and is called back
//! only on its own (`agent.chat_send`, …), so the move is a file and a registration.
//!
//! One agent process per chat, started when the person first sends (`Agent.zig`). What the agent
//! says lands in one message per turn: its text and thinking streamed in, each tool call a line
//! with its diff or output, a permission request as buttons on the call it is about. Files the
//! agent reads and writes go through fizzy's open documents (`text.read`, `text.write`), so the
//! person's unsaved edits are read and an edit is one change they can undo. The agent gets fizzy's
//! own tools through `fizzy-mcp` (the agent plugin's), named in `session/new`.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const api = @import("api.zig");
const acp = @import("acp.zig");
const Agent = @import("Agent.zig");
const Settings = @import("Settings.zig");
const json = std.json;

pub const client_id = "agent";
pub var settings: *const Settings = undefined;

var sessions: std.AutoArrayHashMapUnmanaged(api.ChatId, *Session) = .empty;

const State = enum { idle, starting, ready, prompting, stopped };
const Pending = enum { initialize, session_new, prompt };

const Session = struct {
    gpa: std.mem.Allocator,
    chat: api.ChatId,
    agent: ?*Agent = null,
    state: State = .idle,
    session_id: ?[]u8 = null,
    next_id: i64 = 1,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    /// What the person sent before the agent was ready: sent once the session opens.
    queued: ?[]u8 = null,
    has_mcp: bool = false,
    /// This turn's message, made when the agent first says or does something in it.
    turn: ?api.MessageId = null,
    /// The agent's `toolCallId`s and the steps they are in the chat; hidden ones map to null.
    tools: std.StringHashMapUnmanaged(?api.ToolId) = .empty,
    /// Questions asked for the agent's permission requests, and the request to answer.
    requests: std.AutoHashMapUnmanaged(api.QuestionId, RequestId) = .empty,

    fn deinit(self: *Session) void {
        self.disconnect();
        if (self.queued) |q| self.gpa.free(q);
        self.pending.deinit(self.gpa);
        var it = self.tools.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.tools.deinit(self.gpa);
        self.requests.deinit(self.gpa);
    }

    fn disconnect(self: *Session) void {
        if (self.agent) |a| a.stop();
        self.agent = null;
        self.pending.clearRetainingCapacity();
        if (self.session_id) |s| self.gpa.free(s);
        self.session_id = null;
        var it = self.requests.valueIterator();
        while (it.next()) |r| r.deinit(self.gpa);
        self.requests.clearRetainingCapacity();
        if (self.state != .idle) self.state = .stopped;
    }
};

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

// ---- the chat's side ------------------------------------------------------------------------

pub fn register(host: *sdk.Host, owner: *sdk.Plugin) !void {
    inline for (.{
        .{ "chat_send", api.Send, onSend },
        .{ "chat_answer", api.Answer, onAnswer },
        .{ "chat_cancel", api.ChatOnly, onCancel },
        .{ "chat_closed", api.ChatOnly, onClosed },
        .{ "chat_new", api.Empty, onNew },
    }) |entry| try host.registerCommand(.{
        .id = client_id ++ "." ++ entry[0],
        .owner = owner,
        .title = "Agent: " ++ entry[0],
        .visibility = .internal,
        .runWith = Handler(entry[1], entry[2]).run,
    });
    _ = call("chat.register", api.Register{ .client = client_id, .title = "Agents" });
}

fn Handler(comptime Args: type, comptime f: fn (Args) void) type {
    return struct {
        fn run(_: *anyopaque, c: *sdk.Command.Call) anyerror!void {
            const args = api.parse(Args, c.arena, c.args) catch |err| {
                c.bad_args = true;
                return c.fail("expected {s}: {t}", .{ @typeName(Args), err });
            };
            f(args);
        }
    };
}

pub fn deinit(gpa: std.mem.Allocator) void {
    for (sessions.values()) |s| {
        s.deinit();
        gpa.destroy(s);
    }
    sessions.deinit(gpa);
}

/// One of the chat's commands, with `args`; its result as ZON, or null (logged) when it refused.
fn call(comptime id: []const u8, args: anytype) ?[]const u8 {
    const host = sdk.host();
    const arena = host.arena();
    const zon = api.write(arena, args) catch return null;
    return switch (host.callCommand(id, zon, arena)) {
        .ok => |r| r orelse "",
        else => |o| {
            dvui.log.warn("agent: {s} refused: {any}", .{ id, o });
            return null;
        },
    };
}

fn sessionFor(chat: api.ChatId) ?*Session {
    if (sessions.get(chat)) |s| return s;
    const gpa = sdk.allocator();
    const s = gpa.create(Session) catch return null;
    s.* = .{ .gpa = gpa, .chat = chat };
    sessions.put(gpa, chat, s) catch {
        gpa.destroy(s);
        return null;
    };
    return s;
}

fn onSend(a: api.Send) void {
    const s = sessionFor(a.chat) orelse return;
    switch (s.state) {
        .ready => prompt(s, a.text),
        .prompting => {},
        .starting, .idle, .stopped => {
            if (s.queued) |q| s.gpa.free(q);
            s.queued = s.gpa.dupe(u8, a.text) catch null;
            if (s.agent == null) connect(s);
        },
    }
}

fn onAnswer(a: api.Answer) void {
    const s = sessions.get(a.chat) orelse return;
    const rid = (s.requests.fetchRemove(a.question) orelse return).value;
    defer rid.deinit(s.gpa);
    write(s, acp.writeResult, .{ rid.value(), .{ .outcome = .{ .outcome = "selected", .optionId = a.option } } });
}

fn onCancel(a: api.ChatOnly) void {
    const s = sessions.get(a.chat) orelse return;
    cancel(s);
}

fn onClosed(a: api.ChatOnly) void {
    const kv = sessions.fetchSwapRemove(a.chat) orelse return;
    kv.value.deinit();
    sdk.allocator().destroy(kv.value);
}

fn onNew(_: api.Empty) void {
    _ = call("chat.open", api.Open{ .client = client_id });
}

/// What every agent sent since the last frame. Once a frame, from the plugin's `beginFrame`.
pub fn frame() void {
    for (sessions.values()) |s| frameSession(s);
}

// ---- talking to the chat --------------------------------------------------------------------

fn post(s: *Session, author: api.Author, blocks: []const api.Block) ?api.MessageId {
    const r = call("chat.post", api.Post{ .chat = s.chat, .author = author, .blocks = blocks }) orelse return null;
    return (api.parse(api.Posted, sdk.host().arena(), r) catch return null).message;
}

fn note(s: *Session, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(sdk.host().arena(), fmt, args) catch return;
    _ = post(s, .note, &.{.{ .text = text }});
}

/// This turn's message, made on first use.
fn turnMessage(s: *Session) ?api.MessageId {
    if (s.turn) |t| return t;
    s.turn = post(s, .other, &.{});
    return s.turn;
}

fn setBusy(s: *Session, busy: bool) void {
    _ = call("chat.set_busy", api.SetBusy{ .chat = s.chat, .busy = busy });
}

// ---- starting and stopping ------------------------------------------------------------------

fn wake() void {
    sdk.host().refresh();
}

fn connect(s: *Session) void {
    s.disconnect();
    const arena = sdk.host().arena();
    const line = std.mem.trim(u8, settings.agent_command.get(), " \t");
    if (line.len == 0) return fail(s, "No agent to run. Set one in Settings > Chat: a command line for an agent " ++
        "that speaks the Agent Client Protocol, such as `npx -y @agentclientprotocol/claude-agent-acp`.", .{});
    const argv = acp.splitCommand(arena, line) catch return fail(s, "Could not read the agent command.", .{});
    const host = sdk.host();
    const cwd = host.folder() orelse std.mem.span(std.c.getenv("HOME") orelse "/".ptr);
    s.agent = Agent.start(s.gpa, dvui.io, argv, cwd, wake) catch |err| switch (err) {
        error.SpawnFailed => return fail(s, "Could not start `{s}`. Is it installed, and on your shell's PATH?", .{argv[0]}),
        else => return fail(s, "Could not start the agent: {t}", .{err}),
    };
    s.state = .starting;
    note(s, "Starting `{s}`...", .{line});
    setBusy(s, true);
    request(s, .initialize, "initialize", .{
        .protocolVersion = acp.protocol_version,
        // Files go through fizzy's open documents (`readFile`, `writeFile`). Terminals come later.
        .clientCapabilities = .{ .fs = .{ .readTextFile = true, .writeTextFile = true }, .terminal = false },
        .clientInfo = .{ .name = "fizzy", .title = "Fizzy", .version = "0.1.0" },
    });
}

fn fail(s: *Session, comptime fmt: []const u8, args: anytype) void {
    note(s, fmt, args);
    if (s.state == .starting or s.state == .idle) setBusy(s, false);
}

fn openSession(s: *Session) void {
    const Env = struct { name: []const u8, value: []const u8 };
    const Server = struct { name: []const u8, command: []const u8, args: []const []const u8, env: []const Env };
    const host = sdk.host();
    const arena = host.arena();
    // fizzy-mcp finds this fizzy by its profile: the directory holding the plugins directory.
    var servers: []const Server = &.{};
    s.has_mcp = false;
    if (findMcp(arena)) |mcp| {
        if (host.plugins_dir) |plugins| {
            const profile = std.fs.path.dirname(plugins) orelse plugins;
            const args = arena.dupe([]const u8, &.{ "--profile", profile }) catch &.{};
            servers = arena.dupe(Server, &.{.{ .name = "fizzy", .command = mcp, .args = args, .env = &.{} }}) catch &.{};
            s.has_mcp = true;
        }
    } else note(s, "fizzy-mcp was not found, so the agent cannot see or drive fizzy. Install the agent plugin, " ++
        "or name fizzy-mcp in Settings > Chat.", .{});
    const cwd = host.folder() orelse std.mem.span(std.c.getenv("HOME") orelse "/".ptr);
    request(s, .session_new, "session/new", .{ .cwd = cwd, .mcpServers = servers });
}

/// The setting's fizzy-mcp, else the one beside the agent plugin.
fn findMcp(arena: std.mem.Allocator) ?[]const u8 {
    const set = std.mem.trim(u8, settings.mcp_command.get(), " \t");
    if (set.len > 0) return set;
    const host = sdk.host();
    const dir = host.pluginInstallDir("agent") orelse return null;
    defer host.allocator.free(dir);
    const name = if (@import("builtin").os.tag == .windows) "fizzy-mcp.exe" else "fizzy-mcp";
    const path = std.fs.path.join(arena, &.{ dir, name }) catch return null;
    std.Io.Dir.accessAbsolute(dvui.io, path, .{ .execute = true }) catch return null;
    return path;
}

fn prompt(s: *Session, text: []const u8) void {
    const session = s.session_id orelse return;
    const Block = struct { type: []const u8, text: []const u8 };
    s.turn = null;
    request(s, .prompt, "session/prompt", .{ .sessionId = session, .prompt = &[_]Block{.{ .type = "text", .text = text }} });
    s.state = .prompting;
    setBusy(s, true);
}

fn cancel(s: *Session) void {
    const session = s.session_id orelse return;
    if (s.state != .prompting) return;
    var it = s.requests.valueIterator();
    while (it.next()) |r| {
        write(s, acp.writeResult, .{ r.value(), .{ .outcome = .{ .outcome = "cancelled" } } });
        r.deinit(s.gpa);
    }
    s.requests.clearRetainingCapacity();
    write(s, acp.writeNotification, .{ "session/cancel", .{ .sessionId = session } });
}

fn request(s: *Session, what: Pending, method: []const u8, params: anytype) void {
    const id = s.next_id;
    s.next_id += 1;
    s.pending.put(s.gpa, id, what) catch return;
    write(s, acp.writeRequest, .{ id, method, params });
}

fn write(s: *Session, comptime writer: anytype, args: anytype) void {
    const agent = s.agent orelse return;
    var out: std.Io.Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    @call(.auto, writer, .{&out.writer} ++ args) catch return;
    agent.send(out.written()) catch fail(s, "Could not write to the agent.", .{});
}

// ---- what the agent sends -------------------------------------------------------------------

fn frameSession(s: *Session) void {
    const agent = s.agent orelse return;
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer lines.deinit(s.gpa);
    const exited = agent.take(&lines);
    for (lines.items) |line| {
        defer s.gpa.free(line);
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const v = json.parseFromSliceLeaky(json.Value, arena_state.allocator(), line, .{}) catch continue;
        handle(s, acp.Inbound.classify(v));
    }
    if (exited and s.agent != null) {
        var buf: [600]u8 = undefined;
        const why = std.mem.trim(u8, agent.stderrTail(&buf), " \t\r\n");
        if (why.len > 0) note(s, "The agent stopped:\n\n```\n{s}\n```", .{why}) else note(s, "The agent stopped.", .{});
        s.disconnect();
        setBusy(s, false);
        if (s.queued) |q| {
            s.gpa.free(q);
            s.queued = null;
        }
    }
}

fn handle(s: *Session, msg: acp.Inbound) void {
    switch (msg) {
        .response => |r| {
            const what = (s.pending.fetchRemove(r.id) orelse return).value;
            if (r.err) |err| return refused(s, what, err);
            answered(s, what, r.result orelse .null);
        },
        .notification => |n| if (std.mem.eql(u8, n.method, "session/update")) update(s, n.params),
        .request => |q| {
            if (std.mem.eql(u8, q.method, "session/request_permission")) return askPermission(s, q.id, q.params);
            if (std.mem.eql(u8, q.method, "fs/read_text_file")) return readFile(s, q.id, q.params);
            if (std.mem.eql(u8, q.method, "fs/write_text_file")) return writeFile(s, q.id, q.params);
            write(s, acp.writeError, .{ q.id, acp.method_not_found, "fizzy's chat does not offer this yet" });
        },
        .invalid => {},
    }
}

fn answered(s: *Session, what: Pending, result: json.Value) void {
    switch (what) {
        .initialize => openSession(s),
        .session_new => {
            const id = str(field(result, "sessionId")) orelse return fail(s, "The agent opened no session.", .{});
            s.session_id = s.gpa.dupe(u8, id) catch null;
            _ = call("chat.set_resume", api.SetResume{ .chat = s.chat, .state = id });
            s.state = .ready;
            if (s.has_mcp) note(s, "Connected. The agent can see and drive fizzy.", .{}) else note(s, "Connected.", .{});
            if (s.queued) |q| {
                s.queued = null;
                defer s.gpa.free(q);
                prompt(s, q);
            } else setBusy(s, false);
        },
        .prompt => {
            s.state = .ready;
            s.turn = null;
            if (str(field(result, "stopReason"))) |reason| {
                if (!std.mem.eql(u8, reason, "end_turn")) note(s, "Stopped: {s}.", .{reason});
            }
            setBusy(s, false);
        },
    }
}

fn refused(s: *Session, what: Pending, err: []const u8) void {
    switch (what) {
        .initialize, .session_new => {
            // An agent that needs signing in says so here: its own CLI does that, once.
            note(s, "The agent refused to start: {s}", .{err});
            s.disconnect();
            setBusy(s, false);
        },
        .prompt => {
            s.state = .ready;
            note(s, "{s}", .{err});
            setBusy(s, false);
        },
    }
}

/// `session/update`: what the agent is saying, thinking and doing.
fn update(s: *Session, params: json.Value) void {
    const u = field(params, "update") orelse return;
    const kind = str(field(u, "sessionUpdate")) orelse return;
    if (std.mem.eql(u8, kind, "agent_message_chunk")) {
        content(s, field(u, "content"), .text);
    } else if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
        content(s, field(u, "content"), .thought);
    } else if (std.mem.eql(u8, kind, "tool_call")) {
        toolCall(s, u);
    } else if (std.mem.eql(u8, kind, "tool_call_update")) {
        toolUpdate(s, u);
    } else if (std.mem.eql(u8, kind, "plan")) {
        const items = field(u, "entries") orelse return;
        if (items != .array) return;
        const arena = sdk.host().arena();
        var entries: std.ArrayListUnmanaged(api.PlanEntry) = .empty;
        for (items.array.items) |item| entries.append(arena, .{
            .text = str(field(item, "content")) orelse "",
            .status = std.meta.stringToEnum(api.PlanEntry.Status, str(field(item, "status")) orelse "") orelse .pending,
        }) catch {};
        const m = turnMessage(s) orelse return;
        _ = call("chat.set_plan", api.SetPlan{ .chat = s.chat, .message = m, .entries = entries.items });
    }
}

/// A content block the agent sent into its message: text streamed in, anything else a block.
fn content(s: *Session, c: ?json.Value, kind: api.TextKind) void {
    const v = c orelse return;
    const m = turnMessage(s) orelse return;
    if (std.mem.eql(u8, str(field(v, "type")) orelse "", "text")) {
        _ = call("chat.append_text", api.AppendText{ .chat = s.chat, .message = m, .kind = kind, .text = str(field(v, "text")) orelse "" });
        return;
    }
    if (blockOf(sdk.host().arena(), v)) |b| _ = call("chat.append", api.Append{ .chat = s.chat, .message = m, .block = b });
}

/// An ACP content block as the chat's: images to a file the chat copies, links to files.
fn blockOf(arena: std.mem.Allocator, v: json.Value) ?api.Block {
    const t = str(field(v, "type")) orelse return null;
    if (std.mem.eql(u8, t, "text")) return .{ .text = str(field(v, "text")) orelse "" };
    if (std.mem.eql(u8, t, "image")) {
        const data = str(field(v, "data")) orelse return null;
        const mime = str(field(v, "mimeType")) orelse "image/png";
        const path = imageFile(arena, data, mime) orelse return null;
        return .{ .image = .{ .path = path, .mime = mime } };
    }
    if (std.mem.eql(u8, t, "resource_link")) {
        const uri = str(field(v, "uri")) orelse return null;
        if (std.mem.startsWith(u8, uri, "file://")) return .{ .file = .{ .path = uri["file://".len..], .title = str(field(v, "name")) orelse "" } };
        return .{ .text = std.fmt.allocPrint(arena, "[{s}]({s})", .{ str(field(v, "name")) orelse uri, uri }) catch return null };
    }
    if (std.mem.eql(u8, t, "resource")) {
        const r = field(v, "resource") orelse return null;
        const text = str(field(r, "text")) orelse return null;
        return .{ .code = .{ .text = text } };
    }
    return null;
}

/// An image the agent sent, decoded to a file for the chat to copy beside the transcript.
fn imageFile(arena: std.mem.Allocator, b64: []const u8, mime: []const u8) ?[]const u8 {
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(b64) catch return null;
    const bytes = arena.alloc(u8, n) catch return null;
    decoder.decode(bytes, b64) catch return null;
    const host = sdk.host();
    const plugins = host.plugins_dir orelse return null;
    const dir = std.fs.path.join(arena, &.{ std.fs.path.dirname(plugins) orelse plugins, "chats", ".incoming" }) catch return null;
    std.Io.Dir.cwd().createDirPath(dvui.io, dir) catch {};
    const ext = if (std.mem.endsWith(u8, mime, "jpeg")) "jpg" else if (std.mem.endsWith(u8, mime, "gif")) "gif" else "png";
    const path = std.fmt.allocPrint(arena, "{s}/{x:0>16}.{s}", .{ dir, std.hash.XxHash3.hash(0, bytes), ext }) catch return null;
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = bytes }) catch return null;
    return path;
}

/// Steps an adapter takes for itself, not for the person: never shown.
fn hidden(title: []const u8) bool {
    return std.mem.eql(u8, title, "ToolSearch");
}

/// `mcp__fizzy__fizzy_screen` → "Fizzy screen": an MCP tool's name, as a person reads it.
fn readable(arena: std.mem.Allocator, title: []const u8) []const u8 {
    var name = title;
    if (std.mem.startsWith(u8, name, "mcp__")) {
        const rest = name["mcp__".len..];
        if (std.mem.indexOf(u8, rest, "__")) |i| name = rest[i + 2 ..];
    } else if (std.mem.indexOfScalar(u8, name, ' ') != null) return title;
    const out = arena.dupe(u8, name) catch return title;
    for (out) |*ch| if (ch.* == '_') {
        ch.* = ' ';
    };
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

fn toolKind(s: ?[]const u8) api.Tool.Kind {
    return std.meta.stringToEnum(api.Tool.Kind, s orelse "") orelse .other;
}

fn toolStatus(s: ?[]const u8) ?api.Tool.Status {
    const t = s orelse return null;
    if (std.mem.eql(u8, t, "pending")) return .pending;
    if (std.mem.eql(u8, t, "in_progress")) return .running;
    if (std.mem.eql(u8, t, "completed")) return .done;
    if (std.mem.eql(u8, t, "failed")) return .failed;
    return null;
}

/// A tool call's content and locations, as the chat's blocks.
fn toolContent(arena: std.mem.Allocator, u: json.Value) ?[]const api.Block {
    var out: std.ArrayListUnmanaged(api.Block) = .empty;
    var any = false;
    if (field(u, "content")) |items| if (items == .array) {
        any = true;
        for (items.array.items) |item| {
            const kind = str(field(item, "type")) orelse continue;
            if (std.mem.eql(u8, kind, "diff")) {
                out.append(arena, .{ .diff = .{ .path = str(field(item, "path")) orelse "", .old = str(field(item, "oldText")) orelse "", .new = str(field(item, "newText")) orelse "" } }) catch {};
            } else if (std.mem.eql(u8, kind, "content")) {
                if (blockOf(arena, field(item, "content") orelse continue)) |b| out.append(arena, b) catch {};
            }
        }
    };
    if (field(u, "locations")) |locs| if (locs == .array) {
        any = true;
        for (locs.array.items) |l| {
            const path = str(field(l, "path")) orelse continue;
            const line: u32 = if (field(l, "line")) |n| (if (n == .integer and n.integer > 0) @intCast(n.integer) else 0) else 0;
            out.append(arena, .{ .file = .{ .path = path, .line = line } }) catch {};
        }
    };
    return if (any) out.items else null;
}

fn toolCall(s: *Session, u: json.Value) void {
    const id = str(field(u, "toolCallId")) orelse return;
    const title = str(field(u, "title")) orelse "A tool";
    const key = s.gpa.dupe(u8, id) catch return;
    if (hidden(title)) {
        s.tools.put(s.gpa, key, null) catch s.gpa.free(key);
        return;
    }
    const m = turnMessage(s) orelse return s.gpa.free(key);
    const arena = sdk.host().arena();
    const r = call("chat.tool", api.AddTool{ .chat = s.chat, .message = m, .tool = .{
        .kind = toolKind(str(field(u, "kind"))),
        .title = readable(arena, title),
        .status = toolStatus(str(field(u, "status"))) orelse .pending,
        .content = toolContent(arena, u) orelse &.{},
    } }) orelse return s.gpa.free(key);
    const added = api.parse(api.Added, arena, r) catch return s.gpa.free(key);
    s.tools.put(s.gpa, key, added.tool) catch s.gpa.free(key);
}

fn toolUpdate(s: *Session, u: json.Value) void {
    const tid = (s.tools.get(str(field(u, "toolCallId")) orelse return) orelse return) orelse return;
    const arena = sdk.host().arena();
    _ = call("chat.update_tool", api.UpdateTool{ .chat = s.chat, .tool = tid, .update = .{
        .title = if (str(field(u, "title"))) |t| readable(arena, t) else null,
        .status = toolStatus(str(field(u, "status"))),
        .content = toolContent(arena, u),
    } });
}

/// `session/request_permission`: buttons on the tool call it is about, the agent's own options.
fn askPermission(s: *Session, id: json.Value, params: json.Value) void {
    const rid = RequestId.of(s.gpa, id) orelse return;
    const arena = sdk.host().arena();
    const callv = field(params, "toolCall");
    const tid: ?api.ToolId = if (str(field(callv, "toolCallId"))) |tc| (s.tools.get(tc) orelse null) orelse null else null;
    var options: std.ArrayListUnmanaged(api.Question.Option) = .empty;
    if (field(params, "options")) |opts| if (opts == .array) for (opts.array.items) |o| {
        const oid = str(field(o, "optionId")) orelse continue;
        const kind = str(field(o, "kind")) orelse "";
        options.append(arena, .{
            .id = oid,
            .label = str(field(o, "name")) orelse oid,
            .kind = if (std.mem.eql(u8, kind, "allow_once")) .allow else if (std.mem.eql(u8, kind, "allow_always")) .allow_always else if (std.mem.eql(u8, kind, "reject_once")) .deny else if (std.mem.eql(u8, kind, "reject_always")) .deny_always else .neutral,
        }) catch {};
    };
    const title = str(field(callv, "title")) orelse "use a tool";
    const m = turnMessage(s) orelse return rid.deinit(s.gpa);
    const r = call("chat.ask", api.Ask{ .chat = s.chat, .message = m, .question = .{
        // On its tool's line the call says what; on its own the question does.
        .text = if (tid != null) "" else std.fmt.allocPrint(arena, "The agent asks to {s}.", .{readable(arena, title)}) catch "",
        .options = options.items,
        .tool = tid,
    } }) orelse return rid.deinit(s.gpa);
    const asked = api.parse(api.Asked, arena, r) catch return rid.deinit(s.gpa);
    s.requests.put(s.gpa, asked.question, rid) catch rid.deinit(s.gpa);
}

// ---- files ----------------------------------------------------------------------------------

/// `fs/read_text_file`: a document open in fizzy is read as the editor has it, unsaved edits
/// included (`text.read`); anything else from disk. `line` (from 1) and `limit` pick lines.
fn readFile(s: *Session, id: json.Value, params: json.Value) void {
    const path = str(field(params, "path")) orelse return write(s, acp.writeError, .{ id, -32602, "no path" });
    const line: u32 = if (field(params, "line")) |l| (if (l == .integer and l.integer > 0) @intCast(l.integer) else 1) else 1;
    const limit: u32 = if (field(params, "limit")) |l| (if (l == .integer and l.integer > 0) @intCast(l.integer) else 0) else 0;
    const host = sdk.host();
    const arena = host.arena();
    if (host.docFromPath(path) != null) {
        if (callText(arena, "text.read", .{ .path = path, .from_line = line, .to_line = if (limit == 0) 0 else line + limit - 1 })) |zon| {
            const Read = struct { text: []const u8 };
            if (api.parse(Read, arena, zon)) |r| return write(s, acp.writeResult, .{ id, .{ .content = r.text } }) else |_| {}
        }
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, arena, .limited(64 * 1024 * 1024)) catch |err|
        return write(s, acp.writeError, .{ id, -32603, @errorName(err) });
    write(s, acp.writeResult, .{ id, .{ .content = linesOf(bytes, line, limit) } });
}

/// `fs/write_text_file`: a document open in fizzy takes it as one undoable edit over what differs
/// (`text.write`), so the person sees it land and can undo it; anything else is written to disk
/// and opened as a preview tab, so it is seen without tabs piling up.
fn writeFile(s: *Session, id: json.Value, params: json.Value) void {
    const path = str(field(params, "path")) orelse return write(s, acp.writeError, .{ id, -32602, "no path" });
    const text = str(field(params, "content")) orelse return write(s, acp.writeError, .{ id, -32602, "no content" });
    const host = sdk.host();
    const arena = host.arena();
    if (host.docFromPath(path) != null and callText(arena, "text.write", .{ .path = path, .text = text }) != null) {
        return write(s, acp.writeResult, .{ id, .{} });
    }
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(dvui.io, dir) catch {};
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = text }) catch |err|
        return write(s, acp.writeError, .{ id, -32603, @errorName(err) });
    _ = host.openFile(.{ .path = path, .mode = .preview }) catch {};
    write(s, acp.writeResult, .{ id, .{} });
}

fn callText(arena: std.mem.Allocator, id: []const u8, args: anytype) ?[]const u8 {
    const zon = api.write(arena, args) catch return null;
    return switch (sdk.host().callCommand(id, zon, arena)) {
        .ok => |r| r orelse "",
        else => null,
    };
}

fn linesOf(text: []const u8, line: u32, limit: u32) []const u8 {
    var start: usize = 0;
    var n: u32 = 1;
    while (n < line) : (n += 1) start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return "") + 1;
    if (limit == 0) return text[start..];
    var end = start;
    var taken: u32 = 0;
    while (taken < limit) : (taken += 1) end = (std.mem.indexOfScalarPos(u8, text, end, '\n') orelse return text[start..]) + 1;
    return text[start..end];
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

test "an MCP tool's name reads as words" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("Fizzy screen", readable(arena, "mcp__fizzy__fizzy_screen"));
    try std.testing.expectEqualStrings("Read a.zig", readable(arena, "Read a.zig"));
    try std.testing.expect(hidden("ToolSearch"));
}
