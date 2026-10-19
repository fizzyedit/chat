//! Signing in to an agent over ACP (agentclientprotocol.com/protocol/authentication), std-only.
//! The agent names its ways in (`authMethods`, in its `initialize` answer); a session start it
//! refuses with `auth_required` shows them to the person as buttons. An `agent` method is the
//! agent's own flow (it opens a browser, say), started with `authenticate`; a `terminal` method
//! is the agent's command run again, with the method's arguments and environment, in a terminal
//! the person types into, never sent to `authenticate`. Either way the agent keeps the
//! credentials: the chat never sees a token. `Flow` is what happens next at each step, so
//! `AcpClient.zig` only carries it out.
const std = @import("std");
const json = std.json;

/// The error code an agent refuses with until it is signed in.
pub const auth_required: i64 = -32000;

/// One way in, as the agent advertised it.
pub const Method = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    kind: Kind = .agent,
    /// A terminal method's arguments, after the agent's own command line.
    args: []const []const u8 = &.{},
    /// A terminal method's environment, over the one the agent runs with.
    env: []const Env = &.{},

    pub const Kind = enum { agent, terminal };
};

pub const Env = struct { name: []const u8, value: []const u8 };

/// The `authMethods` of an `initialize` answer, in `arena`. A method of a type this chat does not
/// know is left out: it could not carry it out.
pub fn methods(arena: std.mem.Allocator, init_result: json.Value) ![]const Method {
    const list = field(init_result, "authMethods") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayListUnmanaged(Method) = .empty;
    for (list.array.items) |m| {
        const id = str(field(m, "id")) orelse continue;
        // No type is an `agent` method.
        const kind = std.meta.stringToEnum(Method.Kind, str(field(m, "type")) orelse "agent") orelse continue;
        var method: Method = .{
            .id = try arena.dupe(u8, id),
            .name = try arena.dupe(u8, str(field(m, "name")) orelse id),
            .description = try arena.dupe(u8, str(field(m, "description")) orelse ""),
            .kind = kind,
        };
        if (kind == .terminal) {
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            if (field(m, "args")) |a| if (a == .array) for (a.array.items) |arg| {
                if (arg == .string) try args.append(arena, try arena.dupe(u8, arg.string));
            };
            var env: std.ArrayListUnmanaged(Env) = .empty;
            if (field(m, "env")) |e| if (e == .object) {
                var it = e.object.iterator();
                while (it.next()) |kv| if (kv.value_ptr.* == .string) try env.append(arena, .{
                    .name = try arena.dupe(u8, kv.key_ptr.*),
                    .value = try arena.dupe(u8, kv.value_ptr.string),
                });
            };
            method.args = args.items;
            method.env = env.items;
        }
        try out.append(arena, method);
    }
    return out.items;
}

/// Whether the agent takes `logout` (`agentCapabilities.auth.logout` present and not null).
pub fn canLogout(init_result: json.Value) bool {
    const v = field(field(field(init_result, "agentCapabilities"), "auth"), "logout") orelse return false;
    return v != .null;
}

pub fn find(list: []const Method, id: []const u8) ?Method {
    for (list) |m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

/// A terminal method's command line: the agent's own, then the method's arguments. The method
/// never names a program; the agent is the one the person configured.
pub fn terminalArgv(arena: std.mem.Allocator, command: []const []const u8, m: Method) ![]const []const u8 {
    return std.mem.concat(arena, []const u8, &.{ command, m.args });
}

// ---- what goes on the wire ------------------------------------------------------------------

/// `initialize`'s `clientCapabilities`. Files go through fizzy's open documents; agents' own
/// shell commands stay theirs (`terminal/*` is not offered). `auth.terminal`: a terminal method
/// can be run here (some plugin offers `terminal_run`), so the agent may offer one.
pub const ClientCapabilities = struct {
    fs: struct { readTextFile: bool = true, writeTextFile: bool = true } = .{},
    terminal: bool = false,
    auth: struct { terminal: bool = false } = .{},
};

pub fn clientCapabilities(terminal: bool) ClientCapabilities {
    return .{ .auth = .{ .terminal = terminal } };
}

/// `authenticate`'s params. Only ever an `agent` method's id.
pub const Authenticate = struct { methodId: []const u8 };
/// `logout`'s params.
pub const Logout = struct {};

/// The seam a terminal plugin fills: `terminal_run` runs `argv` in a terminal the person types
/// into, in `cwd`, over the app's environment plus `env`, titled `title`; when it exits it calls
/// command `done` with `Exited{ .tag = tag, .code = … }`. A chat advertises terminal sign-in only
/// while some plugin registers it.
pub const terminal_run = "terminal.run";
pub const TerminalRun = struct {
    title: []const u8,
    argv: []const []const u8,
    env: []const Env = &.{},
    cwd: []const u8 = "",
    done: []const u8,
    tag: u64 = 0,
};
pub const Exited = struct { tag: u64 = 0, code: i32 };

// ---- what happens next ----------------------------------------------------------------------

/// One sign-in, from the refusal that needs it to the session it lets start.
pub const Flow = struct {
    step: Step = .none,

    pub const Step = enum { none, choosing, authenticating, in_terminal };

    pub const Action = union(enum) {
        /// Nothing to do.
        none,
        /// Not something signing in fixes: say why it refused.
        give_up,
        /// Show the methods as buttons.
        choose,
        /// Send `authenticate { methodId }` and wait.
        authenticate: []const u8,
        /// Run the method in a terminal, and wait for it to exit.
        run_terminal: Method,
        /// Signed in through the agent: start the session again.
        retry,
        /// Signed in through a terminal: the running agent did not see it; start it again.
        reconnect,
    };

    /// A session start (or a prompt) refused with `code`.
    pub fn refused(self: *Flow, code: i64, list: []const Method) Action {
        if (code != auth_required or list.len == 0) return .give_up;
        self.step = .choosing;
        return .choose;
    }

    /// The person picked method `id`.
    pub fn chose(self: *Flow, list: []const Method, id: []const u8) Action {
        if (self.step != .choosing) return .none;
        const m = find(list, id) orelse return .none;
        switch (m.kind) {
            .agent => {
                self.step = .authenticating;
                return .{ .authenticate = m.id };
            },
            .terminal => {
                self.step = .in_terminal;
                return .{ .run_terminal = m };
            },
        }
    }

    /// `authenticate` answered: signed in, or not.
    pub fn authenticated(self: *Flow, ok: bool) Action {
        if (self.step != .authenticating) return .none;
        if (!ok) {
            self.step = .choosing;
            return .choose;
        }
        self.step = .none;
        return .retry;
    }

    /// The terminal method exited with `code`.
    pub fn exited(self: *Flow, code: i32) Action {
        if (self.step != .in_terminal) return .none;
        if (code != 0) {
            self.step = .choosing;
            return .choose;
        }
        self.step = .none;
        return .reconnect;
    }
};

fn field(v: ?json.Value, name: []const u8) ?json.Value {
    const o = v orelse return null;
    if (o != .object) return null;
    return o.object.get(name);
}

fn str(v: ?json.Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const acp = @import("acp.zig");

const gemini_like =
    \\{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"auth":{"logout":{}}},
    \\ "authMethods":[
    \\  {"id":"oauth-personal","name":"Log in with Google","description":"Opens a browser"},
    \\  {"id":"api-key","name":"Use an API key","type":"agent"},
    \\  {"id":"cli-login","name":"Log in in a terminal","type":"terminal","args":["--login"],"env":{"LOGIN_MODE":"interactive"}},
    \\  {"id":"later","name":"Some future kind","type":"something_else"}
    \\ ]}
;

test "an agent's methods read from its initialize answer, unknown kinds left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a, gemini_like, .{});
    const list = try methods(a, v);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqual(Method.Kind.agent, list[0].kind);
    try testing.expectEqualStrings("Opens a browser", list[0].description);
    try testing.expectEqual(Method.Kind.agent, list[1].kind);
    const t = list[2];
    try testing.expectEqual(Method.Kind.terminal, t.kind);
    try testing.expectEqualStrings("--login", t.args[0]);
    try testing.expectEqualStrings("LOGIN_MODE", t.env[0].name);
    try testing.expectEqualStrings("interactive", t.env[0].value);
    try testing.expect(canLogout(v));

    const argv = try terminalArgv(a, &.{ "npx", "-y", "agent-acp" }, t);
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("--login", argv[3]);

    const bare = try json.parseFromSliceLeaky(json.Value, a, "{\"agentCapabilities\":{\"auth\":{\"logout\":null}}}", .{});
    try testing.expectEqual(@as(usize, 0), (try methods(a, bare)).len);
    try testing.expect(!canLogout(bare));
}

test "initialize offers terminal sign-in only when it can run one; authenticate and logout" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try acp.writeRequest(&out.writer, 1, "initialize", .{ .protocolVersion = acp.protocol_version, .clientCapabilities = clientCapabilities(true) });
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"auth\":{\"terminal\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"readTextFile\":true") != null);
    out.clearRetainingCapacity();
    try acp.writeRequest(&out.writer, 2, "authenticate", Authenticate{ .methodId = "oauth-personal" });
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"authenticate\",\"params\":{\"methodId\":\"oauth-personal\"}}\n", out.written());
    out.clearRetainingCapacity();
    try acp.writeRequest(&out.writer, 3, "logout", Logout{});
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"logout\",\"params\":{}}\n", out.written());
}

test "auth_required shows the methods; an agent method authenticates, then the session starts again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try methods(a, try json.parseFromSliceLeaky(json.Value, a, gemini_like, .{}));

    // The refusal as it comes off the wire.
    const refusal = acp.Inbound.classify(try json.parseFromSliceLeaky(json.Value, a,
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}
    , .{}));
    try testing.expectEqual(auth_required, refusal.response.code);

    var flow: Flow = .{};
    try testing.expect(flow.refused(refusal.response.code, list) == .choose);
    // A method it never offered does nothing.
    try testing.expect(flow.chose(list, "nope") == .none);
    try testing.expectEqualStrings("oauth-personal", flow.chose(list, "oauth-personal").authenticate);
    // Pressing again while it signs in does nothing.
    try testing.expect(flow.chose(list, "api-key") == .none);
    // Refused: the methods again; then it works, and the session starts again.
    try testing.expect(flow.authenticated(false) == .choose);
    try testing.expectEqualStrings("api-key", flow.chose(list, "api-key").authenticate);
    try testing.expect(flow.authenticated(true) == .retry);
    try testing.expect(flow.step == .none);

    // Any other refusal is not a sign-in's to fix, nor is auth_required with no methods.
    try testing.expect(flow.refused(-32603, list) == .give_up);
    try testing.expect(flow.refused(auth_required, &.{}) == .give_up);
}

test "a terminal method is run, never authenticated, and its exit decides" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try methods(a, try json.parseFromSliceLeaky(json.Value, a, gemini_like, .{}));
    var flow: Flow = .{};
    _ = flow.refused(auth_required, list);
    const run = flow.chose(list, "cli-login");
    try testing.expectEqualStrings("cli-login", run.run_terminal.id);
    try testing.expect(flow.authenticated(true) == .none);
    try testing.expect(flow.exited(1) == .choose);
    _ = flow.chose(list, "cli-login");
    try testing.expect(flow.exited(0) == .reconnect);
}
