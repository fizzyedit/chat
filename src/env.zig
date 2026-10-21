//! The environment an agent is launched with: one policy on every OS. A variable that carries an
//! API key never reaches the agent by default, so a stray `ANTHROPIC_API_KEY` in fizzy's own
//! environment cannot bill the person per token in place of their plan login. They opt in, by name
//! (Settings > Chat), and only the names they list are forwarded. Values are never read into a
//! message, a log or a setting: they go from this process's environment to the child's and nowhere
//! else.
//!
//! The filter is by name: `*_API_KEY` and `ANTHROPIC_AUTH_TOKEN`. A credential under another name
//! (`CLAUDE_CODE_OAUTH_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK`, `*_APIKEY`) still passes, and the
//! opt-in list may name any variable, `ANTHROPIC_AUTH_TOKEN` included.
const std = @import("std");
const builtin = @import("builtin");
const Map = std.process.Environ.Map;

const separators = ", ;\t";

/// Names stripped whatever their spelling elsewhere; any name ending `_API_KEY` is stripped too.
const secret_names = [_][]const u8{ "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY" };

/// What the person chose in Settings > Chat.
pub const Policy = struct {
    /// "Use API key from environment": off, nothing is forwarded whatever `vars` says.
    use_api_key: bool = false,
    /// The variables to forward when it is on, separated by commas.
    vars: []const u8 = "",

    /// The names to forward: none unless `use_api_key`.
    fn forwarded(self: Policy) std.mem.TokenIterator(u8, .any) {
        return std.mem.tokenizeAny(u8, if (self.use_api_key) self.vars else "", separators);
    }
};

/// True for a variable that carries a credential the agent would bill with. Case-insensitive,
/// since Windows names are.
pub fn isSecret(name: []const u8) bool {
    for (secret_names) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    return name.len >= "_API_KEY".len and
        std.ascii.eqlIgnoreCase(name[name.len - "_API_KEY".len ..], "_API_KEY");
}

/// A copy of `source` without its secret variables, plus the ones the policy names that `source`
/// has. `Map` compares names the way the platform does (ignoring case on Windows). The caller
/// calls `deinit` on the result.
pub fn child(gpa: std.mem.Allocator, source: *const Map, policy: Policy) !Map {
    var out = Map.init(gpa);
    errdefer out.deinit();
    var it = source.iterator();
    while (it.next()) |e| {
        if (!isSecret(e.key_ptr.*)) try out.put(e.key_ptr.*, e.value_ptr.*);
    }
    var wanted = policy.forwarded();
    while (wanted.next()) |name| {
        if (source.get(name)) |value| try out.put(name, value);
    }
    return out;
}

/// What the chat says about how the agent signs in: "plan login", or "API key: A, B forwarded"
/// naming the variables `source` has among those the policy forwards. Only names, never values.
/// The caller frees the result with `gpa`, except "plan login", which is a literal.
pub fn status(gpa: std.mem.Allocator, source: *const Map, policy: Policy) std.mem.Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var n: usize = 0;
    var wanted = policy.forwarded();
    while (wanted.next()) |name| {
        if (source.get(name) == null) continue;
        w.writer.writeAll(if (n == 0) "API key: " else ", ") catch return error.OutOfMemory;
        w.writer.writeAll(name) catch return error.OutOfMemory;
        n += 1;
    }
    if (n == 0) return "plan login";
    w.writer.writeAll(" forwarded") catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

/// Spawn `argv` in `cwd` with stdin, stdout and stderr piped and the environment `child` builds
/// from `source`: the one place the agent's environment is set.
pub fn spawn(gpa: std.mem.Allocator, io: std.Io, source: *const Map, policy: Policy, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    var child_env = try child(gpa, source, policy);
    defer child_env.deinit();
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &child_env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        // Windows only: a console agent from a windowed fizzy would otherwise pop up a console.
        .create_no_window = true,
    });
}

test "no API key reaches the child by default" {
    const gpa = std.testing.allocator;
    var source = Map.init(gpa);
    defer source.deinit();
    try source.put("PATH", "/bin");
    for ([_][]const u8{
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY",  "CODEX_API_KEY",     "GEMINI_API_KEY",
        "GOOGLE_API_KEY",    "MISTRAL_API_KEY", "anthropic_api_key", "ANTHROPIC_AUTH_TOKEN",
    }) |k| try source.put(k, "secret");

    var out = try child(gpa, &source, .{});
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 1), out.count());
    try std.testing.expectEqualStrings("/bin", out.get("PATH").?);
    var it = out.iterator();
    while (it.next()) |e| try std.testing.expect(!isSecret(e.key_ptr.*));
}

test "names listed while the setting is off forward nothing" {
    const gpa = std.testing.allocator;
    var source = Map.init(gpa);
    defer source.deinit();
    try source.put("ANTHROPIC_API_KEY", "a");
    var out = try child(gpa, &source, .{ .use_api_key = false, .vars = "ANTHROPIC_API_KEY" });
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 0), out.count());
}

test "only the named variables are forwarded" {
    const gpa = std.testing.allocator;
    var source = Map.init(gpa);
    defer source.deinit();
    try source.put("PATH", "/bin");
    try source.put("ANTHROPIC_API_KEY", "a");
    try source.put("OPENAI_API_KEY", "b");

    var out = try child(gpa, &source, .{ .use_api_key = true, .vars = "ANTHROPIC_API_KEY, GEMINI_API_KEY" });
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 2), out.count());
    try std.testing.expect(out.get("ANTHROPIC_API_KEY") != null);
    try std.testing.expect(out.get("OPENAI_API_KEY") == null);
}

test "a name is found in whatever case the platform's environment uses" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var source = Map.init(gpa);
    defer source.deinit();
    try source.put("Anthropic_Api_Key", "a");
    var out = try child(gpa, &source, .{ .use_api_key = true, .vars = "ANTHROPIC_API_KEY" });
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 1), out.count());
}

test "status names the variables forwarded, never a value" {
    const gpa = std.testing.allocator;
    var source = Map.init(gpa);
    defer source.deinit();
    try source.put("ANTHROPIC_API_KEY", "sk-secret");
    try std.testing.expectEqualStrings("plan login", try status(gpa, &source, .{}));
    try std.testing.expectEqualStrings("plan login", try status(gpa, &source, .{ .use_api_key = true, .vars = "OPENAI_API_KEY" }));
    try std.testing.expectEqualStrings("plan login", try status(gpa, &source, .{ .vars = "ANTHROPIC_API_KEY" }));
    const s = try status(gpa, &source, .{ .use_api_key = true, .vars = "ANTHROPIC_API_KEY,OPENAI_API_KEY" });
    defer gpa.free(s);
    try std.testing.expectEqualStrings("API key: ANTHROPIC_API_KEY forwarded", s);
}

test "status is not cut short by a long list" {
    const gpa = std.testing.allocator;
    var source = Map.init(gpa);
    defer source.deinit();
    var vars: std.Io.Writer.Allocating = .init(gpa);
    defer vars.deinit();
    for (0..40) |i| {
        var name: [40]u8 = undefined;
        const k = try std.fmt.bufPrint(&name, "SOME_LONG_VENDOR_{d}_API_KEY", .{i});
        try source.put(k, "x");
        try vars.writer.print("{s},", .{k});
    }
    const s = try status(gpa, &source, .{ .use_api_key = true, .vars = vars.written() });
    defer gpa.free(s);
    try std.testing.expect(std.mem.endsWith(u8, s, " forwarded"));
}

test "spawn gives the child the built environment, not the parent's" {
    const gpa = std.testing.allocator;
    var source = try std.testing.environ.createMap(gpa);
    defer source.deinit();
    try source.put("CHAT_TEST_MARKER", "present");
    try source.put("CHAT_TEST_API_KEY", "must-not-reach-child");
    try source.put("CHAT_TEST_FORWARDED_API_KEY", "does-reach-child");

    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/c", "set" }
    else
        &.{"env"};
    const policy: Policy = .{ .use_api_key = true, .vars = "CHAT_TEST_FORWARDED_API_KEY" };
    var proc = try spawn(gpa, std.testing.io, &source, policy, argv, ".");
    var buf: [4096]u8 = undefined;
    var r = proc.stdout.?.readerStreaming(std.testing.io, &buf);
    const out = try r.interface.allocRemaining(gpa, .limited(1 << 20));
    defer gpa.free(out);
    _ = try proc.wait(std.testing.io);

    // The marker exists only in `source`, not in this process's environment: seeing it in the
    // child shows `environ_map` was passed.
    try std.testing.expect(std.mem.indexOf(u8, out, "CHAT_TEST_MARKER=present") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "must-not-reach-child") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "CHAT_TEST_FORWARDED_API_KEY=does-reach-child") != null);
}
