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
const auth = @import("auth.zig");
const permission = @import("permission.zig");
const RequestId = permission.RequestId;
const Agent = @import("Agent.zig");
const Settings = @import("Settings.zig");
const json = std.json;

pub const client_id = "agent";
pub var settings: *const Settings = undefined;

var sessions: std.AutoArrayHashMapUnmanaged(api.ChatId, *Session) = .empty;

const State = enum { idle, starting, ready, prompting, stopped, signing_in };
const Pending = enum { initialize, session_new, session_resume, session_load, prompt, set_option, authenticate, logout };

/// One block of a prompt, as ACP writes it: text, an image's bytes, or a link to a file.
const Content = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    data: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

/// A message waiting for its session to open: its prompt, built once, in its own arena.
const Queued = struct {
    arena: std.heap.ArenaAllocator,
    content: []const Content,
};

/// What the person last chose for each setting (`chat_setting`), by its id: a new session starts
/// with the model and mode they were using.
var preferred: std.StringHashMapUnmanaged([]u8) = .empty;

/// An agent starting on a thread of its own: finding the command on the login shell's PATH and
/// spawning it take seconds the first time, which the UI thread must never wait on.
const Launch = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8 = &.{},
    cwd: []const u8 = "",
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: Agent.StartError!*Agent = error.SpawnFailed,

    fn run(self: *Launch, gpa: std.mem.Allocator) void {
        self.result = Agent.start(gpa, dvui.io, self.argv, self.cwd, wake);
        self.done.store(true, .release);
        wake();
    }

    /// Wait for the thread (a chat closed while its agent was starting) and stop what it started.
    fn abandon(self: *Launch, gpa: std.mem.Allocator) void {
        if (self.thread) |t| t.join();
        if (self.result) |a| a.stop() else |_| {}
        self.arena.deinit();
        gpa.destroy(self);
    }
};

const Session = struct {
    gpa: std.mem.Allocator,
    chat: api.ChatId,
    agent: ?*Agent = null,
    launch: ?*Launch = null,
    state: State = .idle,
    session_id: ?[]u8 = null,
    next_id: i64 = 1,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    /// What the person sent before the agent was ready: sent once the session opens.
    queued: ?Queued = null,
    /// The prompt the agent has, kept until it is taken: one refused for a sign-in is sent again
    /// after it.
    in_flight: ?Queued = null,
    /// The command line the agent was started with: a terminal sign-in runs it again. Owned.
    command_line: ?[]u8 = null,
    /// The chat's project folder, where the agent works; empty: the one fizzy has open.
    folder: ?[]u8 = null,
    has_mcp: bool = false,
    mcp_noted: bool = false,
    /// The agent session this chat had (what it saved with `chat.set_resume`), to pick up again
    /// rather than start over: the agent keeps its own memory of the conversation.
    resume_id: ?[]u8 = null,
    /// What `initialize` said the agent can do about an earlier session: continue it as it is
    /// (`session/resume`), or load it, replaying its history (`session/load`).
    can_resume: bool = false,
    can_load: bool = false,
    /// What `initialize` said the agent is called (`agentInfo`): the label its edits carry beside
    /// the person's (`sdk.Author`). Owned; null until it says.
    label: ?[]u8 = null,
    /// The agent's ways to sign in (`initialize`'s `authMethods`), in `auth_arena`, and whether it
    /// takes `logout`.
    methods: []const auth.Method = &.{},
    auth_arena: ?std.heap.ArenaAllocator = null,
    can_logout: bool = false,
    /// A sign-in under way, and the question showing its methods.
    sign_in: auth.Flow = .{},
    sign_in_question: ?api.QuestionId = null,
    /// A `session/load` is replaying the conversation: the chat has it already, so the replay is
    /// not shown again.
    replaying: bool = false,
    /// This turn's message, made when the agent first says or does something in it.
    turn: ?api.MessageId = null,
    /// The agent's `toolCallId`s, the steps they are in the chat (hidden ones have none) and
    /// their kind, which a later permission request about them may leave out.
    tools: std.StringHashMapUnmanaged(Known) = .empty,
    /// Questions asked for the agent's permission requests, and the request each answers.
    requests: permission.Requests = .{},

    fn deinit(self: *Session) void {
        // The chat is closed: its questions have nowhere to close, and the agent stops anyway.
        self.requests.deinit(self.gpa);
        self.requests = .{};
        self.disconnect();
        if (self.queued) |*q| q.arena.deinit();
        if (self.command_line) |c| self.gpa.free(c);
        if (self.resume_id) |r| self.gpa.free(r);
        if (self.folder) |f| self.gpa.free(f);
        if (self.label) |l| self.gpa.free(l);
        if (self.auth_arena) |*a| a.deinit();
        self.pending.deinit(self.gpa);
        var it = self.tools.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.tools.deinit(self.gpa);
    }

    fn disconnect(self: *Session) void {
        // Each request waiting is answered before the agent goes, and its buttons go: they
        // would answer nothing.
        dropRequests(self, true);
        if (self.launch) |l| l.abandon(self.gpa);
        self.launch = null;
        if (self.agent) |a| a.stop();
        self.agent = null;
        self.pending.clearRetainingCapacity();
        if (self.session_id) |s| self.gpa.free(s);
        self.session_id = null;
        if (self.in_flight) |*q| q.arena.deinit();
        self.in_flight = null;
        // A sign-in is for the agent that asked for it.
        self.sign_in = .{};
        self.sign_in_question = null;
        if (self.state != .idle) self.state = .stopped;
    }
};

/// A tool call the agent started: its step in the chat (none for a hidden one), and its kind.
const Known = struct {
    tool: ?api.ToolId,
    kind: api.Tool.Kind,
    /// Whether its step shows content: a permission request adds the call's detail only to a step
    /// with none, rather than replace what is there.
    has_content: bool = false,
};

// ---- the chat's side ------------------------------------------------------------------------

pub fn register(host: *sdk.Host, owner: *sdk.Plugin) !void {
    inline for (.{
        .{ "chat_send", api.Send, onSend },
        .{ "chat_answer", api.Answer, onAnswer },
        .{ "chat_cancel", api.ChatOnly, onCancel },
        .{ "chat_closed", api.ChatOnly, onClosed },
        .{ "chat_resume", api.Resume, onResume },
        .{ "chat_setting", api.Choose, onSetting },
        .{ "chat_new", api.NewChat, onNew },
        .{ "terminal_done", auth.Exited, onTerminalDone },
    }) |entry| try host.registerCommand(.{
        .id = client_id ++ "." ++ entry[0],
        .owner = owner,
        .title = "Agent: " ++ entry[0],
        .visibility = .internal,
        .runWith = Handler(entry[1], entry[2]).run,
    });
    try host.registerCommand(.{
        .id = client_id ++ ".sign_out",
        .owner = owner,
        .title = "Chat: Sign Out of the Agent",
        .run = signOut,
        .isEnabled = canSignOut,
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
    if (s.folder == null and a.folder.len > 0) s.folder = s.gpa.dupe(u8, a.folder) catch null;
    if (s.state == .prompting) return;
    var q: Queued = .{ .arena = .init(s.gpa), .content = &.{} };
    q.content = promptOf(q.arena.allocator(), a) catch {
        q.arena.deinit();
        return fail(s, "Could not read what was attached.", .{});
    };
    if (s.queued) |*old| old.arena.deinit();
    s.queued = q;
    switch (s.state) {
        .ready => sendQueued(s),
        // Sent once signed in and the session opens.
        .prompting, .signing_in => {},
        .starting, .idle, .stopped => if (s.agent == null and s.launch == null) connect(s),
    }
}

/// The person's message as an ACP prompt: their text, each image's bytes, each file as a link.
fn promptOf(arena: std.mem.Allocator, a: api.Send) ![]const Content {
    var out: std.ArrayListUnmanaged(Content) = .empty;
    if (a.text.len > 0) try out.append(arena, .{ .type = "text", .text = a.text });
    for (a.attached) |b| switch (b) {
        .image => |img| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, img.path, arena, .limited(32 * 1024 * 1024));
            const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
            _ = std.base64.standard.Encoder.encode(encoded, bytes);
            try out.append(arena, .{ .type = "image", .mimeType = img.mime, .data = encoded });
        },
        .file => |f| try out.append(arena, .{
            .type = "resource_link",
            .uri = try std.fmt.allocPrint(arena, "file://{s}", .{f.path}),
            .name = std.fs.path.basename(f.path),
        }),
        else => {},
    };
    return out.items;
}

fn onSetting(a: api.Choose) void {
    const gpa = sdk.allocator();
    const value = gpa.dupe(u8, a.value) catch return;
    const gop = preferred.getOrPut(gpa, a.id) catch return gpa.free(value);
    if (gop.found_existing) gpa.free(gop.value_ptr.*) else gop.key_ptr.* = gpa.dupe(u8, a.id) catch {
        _ = preferred.remove(a.id);
        return gpa.free(value);
    };
    gop.value_ptr.* = value;
    const s = sessions.get(a.chat) orelse return;
    const session = s.session_id orelse return;
    request(s, .set_option, "session/set_config_option", .{ .sessionId = session, .configId = a.id, .value = a.value });
}

/// The agent's settings (ACP `configOptions`: its model, its mode), by the chat's message box.
fn publishSettings(s: *Session, options: ?json.Value) void {
    const list = options orelse return;
    if (list != .array) return;
    const arena = sdk.host().arena();
    var out: std.ArrayListUnmanaged(api.Setting) = .empty;
    for (list.array.items) |o| {
        if (!std.mem.eql(u8, str(field(o, "type")) orelse "", "select")) continue;
        var choices: std.ArrayListUnmanaged(api.Setting.Choice) = .empty;
        if (field(o, "options")) |opts| if (opts == .array) for (opts.array.items) |c| {
            choices.append(arena, .{
                .value = str(field(c, "value")) orelse continue,
                .name = str(field(c, "name")) orelse str(field(c, "value")).?,
                .description = str(field(c, "description")) orelse "",
            }) catch {};
        };
        out.append(arena, .{
            .id = str(field(o, "id")) orelse continue,
            .name = str(field(o, "name")) orelse "",
            .current = str(field(o, "currentValue")) orelse "",
            .description = str(field(o, "description")) orelse "",
            .choices = choices.items,
        }) catch {};
    }
    _ = call("chat.set_settings", api.SetSettings{ .chat = s.chat, .settings = out.items });
}

/// A new session starts with what the person chose last: each setting they set differently is
/// set again.
fn applyPreferred(s: *Session, options: ?json.Value) void {
    const list = options orelse return;
    if (list != .array) return;
    const session = s.session_id orelse return;
    for (list.array.items) |o| {
        const id = str(field(o, "id")) orelse continue;
        const want = preferred.get(id) orelse continue;
        if (std.mem.eql(u8, str(field(o, "currentValue")) orelse "", want)) continue;
        request(s, .set_option, "session/set_config_option", .{ .sessionId = session, .configId = id, .value = want });
    }
}

fn onAnswer(a: api.Answer) void {
    const s = sessions.get(a.chat) orelse return;
    if (s.sign_in_question == a.question) {
        s.sign_in_question = null;
        return signIn(s, s.sign_in.chose(s.methods, a.option));
    }
    const rid = s.requests.take(a.question) orelse return;
    defer rid.deinit(s.gpa);
    write(s, acp.writeResult, .{ rid.value(), .{ .outcome = .{ .outcome = "selected", .optionId = a.option } } });
}

fn onCancel(a: api.ChatOnly) void {
    const s = sessions.get(a.chat) orelse return;
    // Stop while signing in (a browser left unanswered, a terminal left open): the agent stops
    // too, and the next message starts it again.
    if (s.state == .signing_in) {
        note(s, "Stopped signing in.", .{});
        s.disconnect();
        return setBusy(s, false);
    }
    cancel(s);
}

/// A chat of ours opened again (a restart, its tab reopened, this plugin reloaded), with the agent
/// session it had: the next message continues that session instead of starting one.
fn onResume(a: api.Resume) void {
    const s = sessionFor(a.chat) orelse return;
    if (s.agent != null or s.launch != null) return;
    if (s.resume_id) |r| s.gpa.free(r);
    s.resume_id = s.gpa.dupe(u8, a.state) catch null;
}

fn onClosed(a: api.ChatOnly) void {
    const kv = sessions.fetchSwapRemove(a.chat) orelse return;
    kv.value.deinit();
    sdk.allocator().destroy(kv.value);
}

/// A new chat, and its agent started now rather than at the first message: its settings (the
/// model, the mode) are by the message box before anything is asked, and the first answer comes
/// sooner.
fn onNew(a: api.NewChat) void {
    const r = call("chat.open", api.Open{ .client = client_id, .folder = a.folder }) orelse return;
    const opened = api.parse(api.Opened, sdk.host().arena(), r) catch return;
    const s = sessionFor(opened.chat) orelse return;
    if (a.folder.len > 0) s.folder = s.gpa.dupe(u8, a.folder) catch null;
    connect(s);
}

/// What every agent sent since the last frame. Once a frame, from the plugin's `beginFrame`.
pub fn frame() void {
    for (sessions.values()) |s| frameSession(s);
}

/// Keep frames coming while an agent starts: its thread wakes the app when it is done, but the
/// typing indicator wants to move meanwhile.
pub fn starting() bool {
    for (sessions.values()) |s| if (s.launch != null) return true;
    return false;
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
    s.mcp_noted = false;
    const line = std.mem.trim(u8, settings.agent_command.get(), " \t");
    if (line.len == 0) return fail(s, "No agent to run. Set one in Settings > Chat: a command line for an agent " ++
        "that speaks the Agent Client Protocol, such as `npx -y @agentclientprotocol/claude-agent-acp`.", .{});
    const launch = s.gpa.create(Launch) catch return fail(s, "Could not start the agent: out of memory.", .{});
    launch.* = .{ .arena = .init(s.gpa) };
    const arena = launch.arena.allocator();
    launch.argv = acp.splitCommand(arena, line) catch {
        launch.abandon(s.gpa);
        return fail(s, "Could not read the agent command.", .{});
    };
    launch.cwd = arena.dupe(u8, workDir(s)) catch "/";
    launch.thread = std.Thread.spawn(.{}, Launch.run, .{ launch, s.gpa }) catch {
        launch.abandon(s.gpa);
        return fail(s, "Could not start the agent: no thread for it.", .{});
    };
    s.launch = launch;
    if (s.command_line) |c| s.gpa.free(c);
    s.command_line = s.gpa.dupe(u8, line) catch null;
    s.state = .starting;
    // Picking a session back up says so when it is open ("Picked up where you left off"); only a
    // new one is worth announcing as it starts.
    if (s.resume_id == null) note(s, "Starting `{s}`...", .{line});
    setBusy(s, true);
}

/// The agent's launch finished on its thread: on to `initialize`, or say why it did not start.
fn launched(s: *Session) void {
    const launch = s.launch orelse return;
    if (!launch.done.load(.acquire)) return;
    s.launch = null;
    if (launch.thread) |t| t.join();
    launch.thread = null;
    const argv0 = s.gpa.dupe(u8, if (launch.argv.len > 0) launch.argv[0] else "") catch "";
    defer if (argv0.len > 0) s.gpa.free(argv0);
    const result = launch.result;
    launch.result = error.SpawnFailed; // the agent is the session's now, not the launch's to stop
    launch.abandon(s.gpa);
    s.agent = result catch |err| return switch (err) {
        error.SpawnFailed => fail(s, "Could not start `{s}`. Is it installed, and on your shell's PATH?", .{argv0}),
        else => fail(s, "Could not start the agent: {t}", .{err}),
    };
    request(s, .initialize, "initialize", .{
        .protocolVersion = acp.protocol_version,
        .clientCapabilities = auth.clientCapabilities(sdk.host().hasCommand(auth.terminal_run)),
        .clientInfo = .{ .name = "fizzy", .title = "Fizzy", .version = "0.1.0" },
    });
}

/// Where the agent works: the chat's folder, else the one fizzy has open, else home.
fn workDir(s: *const Session) []const u8 {
    if (s.folder) |f| return f;
    return sdk.host().folder() orelse std.mem.span(std.c.getenv("HOME") orelse "/".ptr);
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
    } else if (!s.mcp_noted) note(s, "fizzy-mcp was not found, so the agent cannot see or drive fizzy. Install the agent plugin, " ++
        "or name fizzy-mcp in Settings > Chat.", .{});
    // Said once: a session started again after signing in need not say it twice.
    s.mcp_noted = true;
    const cwd = workDir(s);
    // Pick up the session this chat had, when the agent can: continuing it as it is if it can,
    // else loading it (its history replays, and is not shown twice).
    if (s.resume_id) |id| {
        if (s.can_resume) return request(s, .session_resume, "session/resume", .{ .sessionId = id, .cwd = cwd, .mcpServers = servers });
        if (s.can_load) {
            s.replaying = true;
            return request(s, .session_load, "session/load", .{ .sessionId = id, .cwd = cwd, .mcpServers = servers });
        }
    }
    request(s, .session_new, "session/new", .{ .cwd = cwd, .mcpServers = servers });
}

/// The session is open (new, resumed or loaded): send what was waiting.
fn sessionOpen(s: *Session, id: []const u8, how: []const u8) void {
    if (s.session_id) |old| s.gpa.free(old);
    s.session_id = s.gpa.dupe(u8, id) catch null;
    _ = call("chat.set_resume", api.SetResume{ .chat = s.chat, .state = id });
    s.state = .ready;
    s.replaying = false;
    if (s.has_mcp) note(s, "{s} The agent can see and drive fizzy.", .{how}) else note(s, "{s}", .{how});
    if (s.queued != null) sendQueued(s) else setBusy(s, false);
}

fn sendQueued(s: *Session) void {
    const q = s.queued orelse return;
    s.queued = null;
    if (s.in_flight) |*old| old.arena.deinit();
    s.in_flight = q;
    prompt(s, q.content);
}

/// The agent took the prompt (or refused it for good): it is not sent again.
fn dropInFlight(s: *Session) void {
    if (s.in_flight) |*q| q.arena.deinit();
    s.in_flight = null;
}

/// The setting's fizzy-mcp, else the one beside the agent plugin.
fn findMcp(arena: std.mem.Allocator) ?[]const u8 {
    const set = std.mem.trim(u8, settings.mcp_command.get(), " \t");
    if (set.len > 0) return set;
    const host = sdk.host();
    const dir = host.pluginInstallDir("agent") orelse return null;
    defer host.allocator.free(dir);
    const name = if (@import("builtin").target.os.tag == .windows) "fizzy-mcp.exe" else "fizzy-mcp";
    const path = std.fs.path.join(arena, &.{ dir, name }) catch return null;
    std.Io.Dir.accessAbsolute(dvui.io, path, .{ .execute = true }) catch return null;
    return path;
}

fn prompt(s: *Session, blocks: []const Content) void {
    const session = s.session_id orelse return;
    s.turn = null;
    request(s, .prompt, "session/prompt", .{ .sessionId = session, .prompt = blocks });
    s.state = .prompting;
    setBusy(s, true);
}

fn cancel(s: *Session) void {
    const session = s.session_id orelse return;
    if (s.state != .prompting) return;
    // ACP: a cancelled turn answers each permission request it left waiting `cancelled`.
    dropRequests(s, true);
    write(s, acp.writeNotification, .{ "session/cancel", .{ .sessionId = session } });
}

/// Every permission request still waiting, answered `cancelled` (unless the agent is gone:
/// `answer` false), its question closed in the chat.
fn dropRequests(s: *Session, answer: bool) void {
    while (s.requests.pop()) |e| {
        if (answer) write(s, acp.writeResult, .{ e.request.value(), .{ .outcome = .{ .outcome = "cancelled" } } });
        e.request.deinit(s.gpa);
        _ = call("chat.unask", api.Unask{ .chat = s.chat, .question = e.question });
    }
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
    launched(s);
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
        // Its requests went with it: nothing to answer, only buttons to take away.
        dropRequests(s, false);
        s.disconnect();
        setBusy(s, false);
        if (s.queued) |*q| {
            q.arena.deinit();
            s.queued = null;
        }
    }
}

fn handle(s: *Session, msg: acp.Inbound) void {
    switch (msg) {
        .response => |r| {
            const what = (s.pending.fetchRemove(r.id) orelse return).value;
            if (r.err) |err| return refused(s, what, err, r.code);
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
        .initialize => {
            const caps = field(result, "agentCapabilities");
            s.can_load = if (field(caps, "loadSession")) |v| v == .bool and v.bool else false;
            s.can_resume = field(field(caps, "sessionCapabilities"), "resume") != null;
            const info = field(result, "agentInfo");
            if (str(field(info, "title")) orelse str(field(info, "name"))) |name| {
                if (s.label) |l| s.gpa.free(l);
                s.label = s.gpa.dupe(u8, name) catch null;
            }
            if (s.auth_arena) |*old| old.deinit();
            s.auth_arena = .init(s.gpa);
            s.methods = auth.methods(s.auth_arena.?.allocator(), result) catch &.{};
            s.can_logout = auth.canLogout(result);
            openSession(s);
        },
        .session_new => {
            const id = str(field(result, "sessionId")) orelse return fail(s, "The agent opened no session.", .{});
            sessionOpen(s, id, "Connected.");
            publishSettings(s, field(result, "configOptions"));
            applyPreferred(s, field(result, "configOptions"));
        },
        // A resumed or loaded session keeps its id; the answer may not repeat it.
        .session_resume, .session_load => {
            sessionOpen(s, s.resume_id orelse "", "Picked up where you left off.");
            publishSettings(s, field(result, "configOptions"));
        },
        .set_option => publishSettings(s, field(result, "configOptions")),
        .authenticate => {
            note(s, "Signed in to {s}.", .{agentName(s)});
            signIn(s, s.sign_in.authenticated(true));
        },
        .logout => note(s, "Signed out of {s}. Its next session asks you to sign in again.", .{agentName(s)}),
        .prompt => {
            dropInFlight(s);
            s.state = .ready;
            s.turn = null;
            if (str(field(result, "stopReason"))) |reason| {
                if (!std.mem.eql(u8, reason, "end_turn")) note(s, "Stopped: {s}.", .{reason});
            }
            setBusy(s, false);
        },
    }
}

fn refused(s: *Session, what: Pending, err: []const u8, code: i64) void {
    // A session start (or, after a sign-out, a prompt) the agent wants a sign-in for: its ways in,
    // as buttons.
    switch (what) {
        .session_new, .session_resume, .session_load, .prompt => if (s.sign_in.refused(code, s.methods) == .choose) {
            s.replaying = false;
            if (what == .prompt) {
                s.turn = null;
                // Sent again once signed in, unless the person has written something since.
                if (s.queued == null) {
                    s.queued = s.in_flight;
                    s.in_flight = null;
                } else dropInFlight(s);
            }
            return signIn(s, .choose);
        },
        else => {},
    }
    switch (what) {
        .session_resume, .session_load => {
            // The agent no longer has it (another machine, cleared, too old): start over, and say
            // so, since it will not remember what came before.
            note(s, "The agent could not pick up where this left off ({s}). Starting a new session: it will not remember what came before.", .{err});
            s.replaying = false;
            if (s.resume_id) |r| s.gpa.free(r);
            s.resume_id = null;
            openSession(s);
        },
        .initialize, .session_new => {
            // Not a sign-in this chat can offer: a refusal of `initialize` (its methods come in
            // its answer), or an agent with no methods.
            note(s, "The agent refused to start: {s}", .{err});
            s.disconnect();
            setBusy(s, false);
        },
        .prompt => {
            dropInFlight(s);
            s.state = .ready;
            note(s, "{s}", .{err});
            setBusy(s, false);
        },
        .set_option => note(s, "The agent did not take that setting: {s}", .{err}),
        .authenticate => {
            note(s, "{s} did not sign in: {s}", .{ agentName(s), err });
            signIn(s, s.sign_in.authenticated(false));
        },
        .logout => note(s, "{s} did not sign out: {s}", .{ agentName(s), err }),
    }
}

// ---- signing in -----------------------------------------------------------------------------

fn agentName(s: *const Session) []const u8 {
    return s.label orelse "The agent";
}

/// Carry out what the sign-in flow says comes next.
fn signIn(s: *Session, action: auth.Flow.Action) void {
    switch (action) {
        .none, .give_up => {},
        .choose => {
            s.state = .signing_in;
            // Not busy while the person chooses (which also closes what was asked before).
            setBusy(s, false);
            const arena = sdk.host().arena();
            var options: std.ArrayListUnmanaged(api.Question.Option) = .empty;
            var text: std.Io.Writer.Allocating = .init(arena);
            text.writer.print("{s} needs you to sign in.", .{agentName(s)}) catch {};
            // A terminal method only while a terminal can be opened for it.
            const terminal = sdk.host().hasCommand(auth.terminal_run);
            for (s.methods) |m| {
                if (m.kind == .terminal and !terminal) continue;
                options.append(arena, .{ .id = m.id, .label = m.name, .kind = .allow }) catch {};
                if (m.description.len > 0) text.writer.print("\n{s}: {s}", .{ m.name, m.description }) catch {};
            }
            s.sign_in_question = askSignIn(s, text.written(), options.items);
            if (s.sign_in_question == null) {
                note(s, "{s} needs you to sign in, in a way this chat cannot offer here. Sign in with its own CLI, then send again.", .{agentName(s)});
                s.disconnect();
            }
        },
        .authenticate => |id| {
            note(s, "Waiting for {s} to sign in...", .{agentName(s)});
            setBusy(s, true);
            request(s, .authenticate, "authenticate", auth.Authenticate{ .methodId = id });
        },
        .run_terminal => |m| runTerminal(s, m),
        // A prompt refused after a sign-out has its session still: it is ready again.
        .retry => if (s.session_id != null) {
            s.state = .ready;
            if (s.queued != null) sendQueued(s) else {
                note(s, "Send your message again.", .{});
                setBusy(s, false);
            }
        } else openSession(s),
        .reconnect => connect(s),
    }
}

/// The methods as buttons in the conversation; null when there are none, or they could not be
/// shown.
fn askSignIn(s: *Session, text: []const u8, options: []const api.Question.Option) ?api.QuestionId {
    if (options.len == 0) return null;
    const msg = post(s, .other, &.{}) orelse return null;
    const r = call("chat.ask", api.Ask{ .chat = s.chat, .message = msg, .question = .{ .text = text, .options = options } }) orelse return null;
    return (api.parse(api.Asked, sdk.host().arena(), r) catch return null).question;
}

/// A terminal method: the agent's own command with the method's arguments and environment, in a
/// terminal the person types into. Its exit comes back as `agent.terminal_done`.
fn runTerminal(s: *Session, m: auth.Method) void {
    const arena = sdk.host().arena();
    const command = acp.splitCommand(arena, s.command_line orelse "") catch &.{};
    const argv = auth.terminalArgv(arena, command, m) catch &.{};
    const run: auth.TerminalRun = .{
        .title = std.fmt.allocPrint(arena, "Sign in: {s}", .{m.name}) catch m.name,
        .argv = argv,
        .env = m.env,
        .cwd = workDir(s),
        .done = client_id ++ ".terminal_done",
        .tag = s.chat,
    };
    if (command.len == 0 or call(auth.terminal_run, run) == null) {
        note(s, "Could not open a terminal to sign in to {s}.", .{agentName(s)});
        return signIn(s, s.sign_in.exited(-1));
    }
    note(s, "Sign in to {s} in the terminal. The chat starts it again when that finishes.", .{agentName(s)});
    setBusy(s, true);
}

fn onTerminalDone(a: auth.Exited) void {
    const s = sessions.get(a.tag) orelse return;
    if (a.code != 0) note(s, "The sign-in ended without signing in (exit {d}).", .{a.code});
    signIn(s, s.sign_in.exited(a.code));
}

/// Whether an agent running in some chat takes `logout`.
fn canSignOut(_: *anyopaque) bool {
    for (sessions.values()) |s| if (s.agent != null and s.can_logout) return true;
    return false;
}

/// Sign out of every running agent that takes it: signing out is the agent's, not one
/// conversation's, and each chat runs its own agent.
fn signOut(_: *anyopaque) anyerror!void {
    for (sessions.values()) |s| if (s.agent != null and s.can_logout) request(s, .logout, "logout", auth.Logout{});
}

/// `session/update`: what the agent is saying, thinking and doing.
fn update(s: *Session, params: json.Value) void {
    // A loaded session replays its history first: the chat shows it already.
    if (s.replaying) return;
    const u = field(params, "update") orelse return;
    const kind = str(field(u, "sessionUpdate")) orelse return;
    if (std.mem.eql(u8, kind, "agent_message_chunk")) {
        content(s, field(u, "content"), .text);
    } else if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
        content(s, field(u, "content"), .thought);
    } else if (std.mem.eql(u8, kind, "tool_call")) {
        _ = toolCall(s, u);
    } else if (std.mem.eql(u8, kind, "tool_call_update")) {
        toolUpdate(s, u);
    } else if (std.mem.eql(u8, kind, "config_option_update")) {
        publishSettings(s, field(u, "configOptions"));
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

/// A tool call's step in the chat, made now; a call the chat has already is updated instead
/// (a permission request can come before its `tool_call`, which then repeats it).
fn toolCall(s: *Session, u: json.Value) ?Known {
    const id = str(field(u, "toolCallId")) orelse return null;
    if (s.tools.get(id)) |known| {
        toolUpdate(s, u);
        return known;
    }
    const title = str(field(u, "title")) orelse "A tool";
    const kind = toolKind(str(field(u, "kind")));
    const arena = sdk.host().arena();
    const given = toolContent(arena, u) orelse &.{};
    const key = s.gpa.dupe(u8, id) catch return null;
    if (hidden(title)) {
        s.tools.put(s.gpa, key, .{ .tool = null, .kind = kind }) catch s.gpa.free(key);
        return null;
    }
    const m = turnMessage(s) orelse {
        s.gpa.free(key);
        return null;
    };
    const added: ?api.Added = if (call("chat.tool", api.AddTool{ .chat = s.chat, .message = m, .tool = .{
        .kind = kind,
        .title = readable(arena, title),
        .status = toolStatus(str(field(u, "status"))) orelse .pending,
        .content = given,
    } })) |r| api.parse(api.Added, arena, r) catch null else null;
    const known: Known = .{ .tool = (added orelse {
        s.gpa.free(key);
        return null;
    }).tool, .kind = kind, .has_content = given.len > 0 };
    s.tools.put(s.gpa, key, known) catch s.gpa.free(key);
    return known;
}

fn toolUpdate(s: *Session, u: json.Value) void {
    const known = s.tools.getPtr(str(field(u, "toolCallId")) orelse return) orelse return;
    if (str(field(u, "kind"))) |k| known.kind = toolKind(k);
    const tid = known.tool orelse return;
    const arena = sdk.host().arena();
    const given = toolContent(arena, u);
    if (given) |c| known.has_content = c.len > 0;
    _ = call("chat.update_tool", api.UpdateTool{ .chat = s.chat, .tool = tid, .update = .{
        .title = if (str(field(u, "title"))) |t| readable(arena, t) else null,
        .status = toolStatus(str(field(u, "status"))),
        .content = given,
    } });
}

/// `session/request_permission`: buttons on the tool call it is about, the agent's own options,
/// and one line saying what the call would do (the command, the file and how much of it, the
/// path), with the detail behind the step's disclosure. A call the chat has not seen yet becomes
/// a step now, so the request always has one to show.
fn askPermission(s: *Session, id: json.Value, params: json.Value) void {
    const rid = RequestId.of(s.gpa, id) orelse return;
    const arena = sdk.host().arena();
    const callv = field(params, "toolCall") orelse .null;
    const tcid = str(field(callv, "toolCallId")) orelse "";
    const before: ?*Known = s.tools.getPtr(tcid);
    // A call the chat has not seen is made a step now, with what the request says of it.
    const known: ?Known = if (before) |k| k.* else toolCall(s, callv);
    const kind = if (str(field(callv, "kind"))) |k| toolKind(k) else if (known) |k| k.kind else .other;
    const title = readable(arena, str(field(callv, "title")) orelse "use a tool");
    // The step's disclosure, in one update: the content the request gives (an empty list never
    // wipes what the step shows), and the whole command or the call's input where the step would
    // otherwise say nothing about it.
    if (known) |k| if (k.tool) |tid| {
        const given = toolContent(arena, callv) orelse &.{};
        const extra = if (given.len > 0 or !k.has_content) permission.detail(arena, callv, kind) else null;
        var blocks: std.ArrayListUnmanaged(api.Block) = .empty;
        // A step made just now has the given content already.
        if (before != null) blocks.appendSlice(arena, given) catch {};
        if (extra) |e| blocks.append(arena, e) catch {};
        if (blocks.items.len > 0) {
            if (before == null) blocks.insertSlice(arena, 0, given) catch {};
            _ = call("chat.update_tool", api.UpdateTool{ .chat = s.chat, .tool = tid, .update = .{
                .title = if (before != null and str(field(callv, "title")) != null) title else null,
                .content = blocks.items,
            } });
            if (s.tools.getPtr(tcid)) |p| p.has_content = true;
        }
    };
    var options: std.ArrayListUnmanaged(api.Question.Option) = .empty;
    if (field(params, "options")) |opts| if (opts == .array) for (opts.array.items) |o| {
        const oid = str(field(o, "optionId")) orelse continue;
        const okind = str(field(o, "kind")) orelse "";
        options.append(arena, .{
            .id = oid,
            .label = str(field(o, "name")) orelse oid,
            .kind = if (std.mem.eql(u8, okind, "allow_once")) .allow else if (std.mem.eql(u8, okind, "allow_always")) .allow_always else if (std.mem.eql(u8, okind, "reject_once")) .deny else if (std.mem.eql(u8, okind, "reject_always")) .deny_always else .neutral,
        }) catch {};
    };
    // Paths are written relative to a project folder only: relative to home they would mislead.
    const project = s.folder orelse sdk.host().folder() orelse "";
    const line = permission.summary(arena, callv, kind, title, project);
    const tool: ?api.ToolId = if (known) |k| k.tool else null;
    const m = turnMessage(s) orelse return rid.deinit(s.gpa);
    const r = call("chat.ask", api.Ask{
        .chat = s.chat,
        .message = m,
        .question = .{
            // On its step's line a summary that only repeats the title says nothing more; on its
            // own the question says it is one.
            .text = if (!std.mem.eql(u8, line, title)) line else if (tool != null) "" else std.fmt.allocPrint(arena, "The agent asks to {s}.", .{title}) catch title,
            .options = options.items,
            .tool = tool,
        },
    }) orelse return rid.deinit(s.gpa);
    const asked = api.parse(api.Asked, arena, r) catch return rid.deinit(s.gpa);
    s.requests.put(s.gpa, asked.question, rid);
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
    if (host.docFromPath(path) != null) {
        // The edit is this chat's agent's, not the person's: its step carries the agent's name.
        const outer = host.act(.{ .kind = .agent, .plugin = "chat", .session = s.chat, .label = s.label orelse "An agent" });
        const written = callText(arena, "text.write", .{ .path = path, .text = text });
        host.endAct(outer);
        if (written != null) return write(s, acp.writeResult, .{ id, .{} });
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
