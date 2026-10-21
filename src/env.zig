//! The environment an agent is launched with: one policy on every OS. A variable that carries an
//! API key never reaches the agent by default, so a stray `ANTHROPIC_API_KEY` in fizzy's own
//! environment cannot bill the person per token in place of their plan login. They opt in, by name
//! (Settings > Chat), and only the names they list are forwarded. Values are never read into a
//! message, a log or a setting: they go from this process's environment to the child's and nowhere
//! else.
const std = @import("std");
const Map = std.process.Environ.Map;

/// Names stripped whatever their spelling elsewhere; any name ending `_API_KEY` is stripped too.
const secret_names = [_][]const u8{ "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY" };

/// True for a variable that carries a credential the agent would bill with. Case-insensitive,
/// since Windows names are.
pub fn isSecret(name: []const u8) bool {
    for (secret_names) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    return name.len >= "_API_KEY".len and
        std.ascii.eqlIgnoreCase(name[name.len - "_API_KEY".len ..], "_API_KEY");
}

/// The names in a comma, semicolon or space separated setting.
pub fn names(list: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, list, ", ;\t");
}

/// A copy of `source` without its secret variables, plus the ones named in `forward` that
/// `source` has. The caller calls `deinit` on the result.
pub fn child(gpa: std.mem.Allocator, source: *const Map, forward: []const u8) !Map {
    var out = Map.init(gpa);
    errdefer out.deinit();
    var it = source.iterator();
    while (it.next()) |e| {
        if (!isSecret(e.key_ptr.*)) try out.put(e.key_ptr.*, e.value_ptr.*);
    }
    var wanted = names(forward);
    while (wanted.next()) |name| {
        if (source.get(name)) |value| try out.put(name, value);
    }
    return out;
}

/// What the chat says about how the agent signs in: "plan login", or "API key: A, B forwarded"
/// naming the variables `source` has among `forward`. Only names, never values.
pub fn status(buf: []u8, source: *const Map, forward: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var n: usize = 0;
    var wanted = names(forward);
    while (wanted.next()) |name| {
        if (source.get(name) == null) continue;
        w.writeAll(if (n == 0) "API key: " else ", ") catch break;
        w.writeAll(name) catch break;
        n += 1;
    }
    if (n == 0) return "plan login";
    w.writeAll(" forwarded") catch {};
    return w.buffered();
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

    var out = try child(gpa, &source, "");
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 1), out.count());
    try std.testing.expectEqualStrings("/bin", out.get("PATH").?);
    var it = out.iterator();
    while (it.next()) |e| try std.testing.expect(!isSecret(e.key_ptr.*));
}

test "only the named variables are forwarded" {
    const gpa = std.testing.allocator;
    var source = Map.init(gpa);
    defer source.deinit();
    try source.put("PATH", "/bin");
    try source.put("ANTHROPIC_API_KEY", "a");
    try source.put("OPENAI_API_KEY", "b");

    var out = try child(gpa, &source, "ANTHROPIC_API_KEY, GEMINI_API_KEY");
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 2), out.count());
    try std.testing.expect(out.get("ANTHROPIC_API_KEY") != null);
    try std.testing.expect(out.get("OPENAI_API_KEY") == null);
}

test "status names the variables forwarded, never a value" {
    const gpa = std.testing.allocator;
    var source = Map.init(gpa);
    defer source.deinit();
    try source.put("ANTHROPIC_API_KEY", "sk-secret");
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("plan login", status(&buf, &source, ""));
    try std.testing.expectEqualStrings("plan login", status(&buf, &source, "OPENAI_API_KEY"));
    const s = status(&buf, &source, "ANTHROPIC_API_KEY,OPENAI_API_KEY");
    try std.testing.expectEqualStrings("API key: ANTHROPIC_API_KEY forwarded", s);
    try std.testing.expect(std.mem.indexOf(u8, s, "sk-secret") == null);
}
