//! An agent's `session/request_permission`, made something a person can judge: one line saying
//! what the agent wants to do (the command it would run, the file it would change and by how
//! much, the path it would read), with the call's detail behind the tool's disclosure. And the
//! requests still waiting for an answer, so that each gets one: the person's choice, or
//! `cancelled` when the turn, the agent or the session ends first (ACP: protocol/tool-calls,
//! "Requesting Permission"). std-only, tested with `zig build test`.
const std = @import("std");
const api = @import("api.zig");
const json = std.json;

/// What the question says, on one line, as plain text: "Run zig build test", "Edit src/a.zig: +3
/// −1". Each piece the agent wrote is cut to one short line, so a path or URL cannot add lines
/// of its own beside the buttons. `call` is
/// the request's `toolCall` (a `ToolCallUpdate`, so any field may be missing: `kind` falls back
/// to what the call was when it started), `title` the call's title as the chat shows it, and
/// paths inside `root` are written relative to it.
pub fn summary(arena: std.mem.Allocator, call: json.Value, kind: api.Tool.Kind, title: []const u8, root: []const u8) []const u8 {
    return summaryOf(arena, call, kind, title, root) catch title;
}

fn summaryOf(arena: std.mem.Allocator, call: json.Value, kind: api.Tool.Kind, title: []const u8, root: []const u8) ![]const u8 {
    const input = field(call, "rawInput");
    switch (kind) {
        .execute => if (command(arena, input)) |cmd| return std.fmt.allocPrint(arena, "Run {s}", .{try oneLine(arena, cmd)}),
        .edit => {
            var files: usize = 0;
            var added: usize = 0;
            var removed: usize = 0;
            var path: []const u8 = "";
            var created = false;
            if (field(call, "content")) |items| if (items == .array) for (items.array.items) |item| {
                if (!std.mem.eql(u8, str(field(item, "type")) orelse "", "diff")) continue;
                const old = str(field(item, "oldText"));
                const n = counts(old orelse "", str(field(item, "newText")) orelse "");
                added += n.added;
                removed += n.removed;
                files += 1;
                path = str(field(item, "path")) orelse path;
                created = old == null;
            };
            if (files == 1) return std.fmt.allocPrint(arena, "{s} {s}: +{d} \u{2212}{d}", .{ if (created) "Create" else "Edit", try oneLine(arena, relative(path, root)), added, removed });
            if (files > 1) return std.fmt.allocPrint(arena, "Edit {d} files: +{d} \u{2212}{d}", .{ files, added, removed });
            if (paths(arena, call, input, root)) |p| return std.fmt.allocPrint(arena, "Edit {s}", .{p});
        },
        .read => if (paths(arena, call, input, root)) |p| return std.fmt.allocPrint(arena, "Read {s}", .{p}),
        .delete => if (paths(arena, call, input, root)) |p| return std.fmt.allocPrint(arena, "Delete {s}", .{p}),
        .move => {
            const locs = field(call, "locations");
            if (locs != null and locs.? == .array and locs.?.array.items.len == 2) {
                const from = str(field(locs.?.array.items[0], "path")) orelse "";
                const to = str(field(locs.?.array.items[1], "path")) orelse "";
                return std.fmt.allocPrint(arena, "Move {s} to {s}", .{ try oneLine(arena, relative(from, root)), try oneLine(arena, relative(to, root)) });
            }
            if (paths(arena, call, input, root)) |p| return std.fmt.allocPrint(arena, "Move {s}", .{p});
        },
        .search => if (firstString(input, &.{ "pattern", "query" })) |q| {
            const where = paths(arena, call, input, root);
            return if (where) |w|
                std.fmt.allocPrint(arena, "Search for {s} in {s}", .{ try oneLine(arena, q), w })
            else
                std.fmt.allocPrint(arena, "Search for {s}", .{try oneLine(arena, q)});
        },
        .fetch => {
            if (firstString(input, &.{"url"})) |u| return std.fmt.allocPrint(arena, "Fetch {s}", .{try oneLine(arena, u)});
            if (firstString(input, &.{"query"})) |q| return std.fmt.allocPrint(arena, "Search the web for {s}", .{try oneLine(arena, q)});
        },
        .think, .other => {},
    }
    return title;
}

/// What the tool's disclosure adds to the call's own content and locations: the whole command,
/// for a call that runs one, or the call's input as the agent wrote it, for a call that says
/// nothing else about itself. Null when the content says it already.
pub fn detail(arena: std.mem.Allocator, call: json.Value, kind: api.Tool.Kind) ?api.Block {
    const input = field(call, "rawInput");
    if (kind == .execute) if (command(arena, input)) |cmd| return .{ .code = .{ .language = "sh", .text = cmd } };
    if (nonEmpty(field(call, "content")) or nonEmpty(field(call, "locations"))) return null;
    const v = input orelse return null;
    if (v == .null) return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    json.Stringify.value(v, .{ .whitespace = .indent_2 }, &out.writer) catch return null;
    var text = out.written();
    if (text.len > 4096) {
        var end: usize = 4096;
        while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
        text = std.fmt.allocPrint(arena, "{s}\n\u{2026}", .{text[0..end]}) catch text[0..end];
    }
    return .{ .code = .{ .language = "json", .text = text } };
}

/// Lines a diff adds and removes, past what both ends share (as the chat draws it).
pub fn counts(old_text: []const u8, new_text: []const u8) struct { added: usize, removed: usize } {
    // A file's last newline ends its last line rather than starting another.
    const old = if (std.mem.endsWith(u8, old_text, "\n")) old_text[0 .. old_text.len - 1] else old_text;
    const new = if (std.mem.endsWith(u8, new_text, "\n")) new_text[0 .. new_text.len - 1] else new_text;
    if (new_text.len == 0) return .{ .added = 0, .removed = if (old_text.len == 0) 0 else std.mem.count(u8, old, "\n") + 1 };
    const a = if (old.len == 0) 0 else std.mem.count(u8, old, "\n") + 1;
    const b = std.mem.count(u8, new, "\n") + 1;
    var ia: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, old, '\n');
    var ib: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, new, '\n');
    var pre: usize = 0;
    if (a > 0) while (pre < a and pre < b) : (pre += 1) if (!std.mem.eql(u8, ia.next().?, ib.next().?)) break;
    var ra: std.mem.SplitBackwardsIterator(u8, .scalar) = std.mem.splitBackwardsScalar(u8, old, '\n');
    var rb: std.mem.SplitBackwardsIterator(u8, .scalar) = std.mem.splitBackwardsScalar(u8, new, '\n');
    var suf: usize = 0;
    if (a > 0) while (suf < a - pre and suf < b - pre) : (suf += 1) if (!std.mem.eql(u8, ra.next().?, rb.next().?)) break;
    return .{ .added = b - pre - suf, .removed = a - pre - suf };
}

/// The command a call would run: `rawInput.command` (a string, or argv), else `rawInput.cmd`.
fn command(arena: std.mem.Allocator, input: ?json.Value) ?[]const u8 {
    for ([_][]const u8{ "command", "cmd" }) |name| {
        const v = field(input, name) orelse continue;
        switch (v) {
            .string => |s| if (s.len > 0) return s,
            .array => |list| {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                for (list.items, 0..) |item, i| {
                    if (item != .string) continue;
                    if (i > 0) out.append(arena, ' ') catch return null;
                    out.appendSlice(arena, item.string) catch return null;
                }
                if (out.items.len > 0) return out.items;
            },
            else => {},
        }
    }
    return null;
}

/// `text` as one short line: its first line, cut at 100 bytes, saying when there is more.
fn oneLine(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n');
    var first = trimmed[0 .. nl orelse trimmed.len];
    var cut = nl != null;
    if (first.len > 100) {
        var end: usize = 100;
        while (end > 0 and (first[end] & 0xc0) == 0x80) end -= 1;
        first = first[0..end];
        cut = true;
    }
    if (!cut) return first;
    return std.fmt.allocPrint(arena, "{s}\u{2026}{s}", .{ first, if (nl != null) " (more lines)" else "" });
}

/// The paths a call is about: its locations, else the path in its input. "a.zig and 2 more".
fn paths(arena: std.mem.Allocator, call: json.Value, input: ?json.Value, root: []const u8) ?[]const u8 {
    if (field(call, "locations")) |locs| if (locs == .array and locs.array.items.len > 0) {
        const l = locs.array.items[0];
        const p = oneLine(arena, relative(str(field(l, "path")) orelse return null, root)) catch return null;
        const line: ?i64 = if (field(l, "line")) |n| (if (n == .integer and n.integer > 0) n.integer else null) else null;
        const more = locs.array.items.len - 1;
        const at = if (line) |n| std.fmt.allocPrint(arena, "{s}:{d}", .{ p, n }) catch return null else p;
        return if (more == 0) at else std.fmt.allocPrint(arena, "{s} and {d} more", .{ at, more }) catch null;
    };
    const p = firstString(input, &.{ "file_path", "path", "notebook_path" }) orelse return null;
    return oneLine(arena, relative(p, root)) catch null;
}

fn relative(path: []const u8, root: []const u8) []const u8 {
    const r = std.mem.trimEnd(u8, root, "/");
    if (r.len == 0 or !std.mem.startsWith(u8, path, r)) return path;
    if (path.len > r.len and path[r.len] == '/') return path[r.len + 1 ..];
    return path;
}

fn firstString(v: ?json.Value, names: []const []const u8) ?[]const u8 {
    for (names) |n| if (str(field(v, n))) |s| if (s.len > 0) return s;
    return null;
}

fn nonEmpty(v: ?json.Value) bool {
    const a = v orelse return false;
    return a == .array and a.array.items.len > 0;
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

// ---- the requests waiting ------------------------------------------------------------------

/// An agent's request id, kept to answer it: a number or a string, as the agent wrote it.
pub const RequestId = union(enum) {
    int: i64,
    str: []u8,

    pub fn of(gpa: std.mem.Allocator, v: json.Value) ?RequestId {
        return switch (v) {
            .integer => |n| .{ .int = n },
            .string => |s| .{ .str = gpa.dupe(u8, s) catch return null },
            else => null,
        };
    }
    pub fn value(self: RequestId) json.Value {
        return switch (self) {
            .int => |n| .{ .integer = n },
            .str => |s| .{ .string = s },
        };
    }
    pub fn deinit(self: RequestId, gpa: std.mem.Allocator) void {
        if (self == .str) gpa.free(self.str);
    }
};

/// The questions asked for permission requests the agent is waiting on, and the request each
/// answers.
pub const Requests = struct {
    open: std.AutoArrayHashMapUnmanaged(api.QuestionId, RequestId) = .empty,

    pub const Entry = struct { question: api.QuestionId, request: RequestId };

    pub fn deinit(self: *Requests, gpa: std.mem.Allocator) void {
        for (self.open.values()) |r| r.deinit(gpa);
        self.open.deinit(gpa);
    }

    /// Wait on `request` for `question`'s answer; on failure the request is freed.
    pub fn put(self: *Requests, gpa: std.mem.Allocator, question: api.QuestionId, request: RequestId) void {
        self.open.put(gpa, question, request) catch request.deinit(gpa);
    }

    /// The request `question` answers, no longer waiting; the caller frees it.
    pub fn take(self: *Requests, question: api.QuestionId) ?RequestId {
        return (self.open.fetchSwapRemove(question) orelse return null).value;
    }

    /// A request still waiting, no longer: to answer `cancelled` and its question to close.
    /// Called until null, it empties them all; the caller frees each request.
    pub fn pop(self: *Requests) ?Entry {
        const kv = self.open.pop() orelse return null;
        return .{ .question = kv.key, .request = kv.value };
    }
};

// ---- tests ----------------------------------------------------------------------------------

fn parsed(arena: std.mem.Allocator, text: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, arena, text, .{});
}

test "a command to run reads as the command" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = try parsed(arena,
        \\{"toolCallId":"t1","title":"Run tests","kind":"execute","rawInput":{"command":"zig build test\n--summary all","description":"Run tests"}}
    );
    try std.testing.expectEqualStrings("Run zig build test\u{2026} (more lines)", summary(arena, call, .execute, "Run tests", "/p"));
    const d = detail(arena, call, .execute).?;
    try std.testing.expectEqualStrings("zig build test\n--summary all", d.code.text);
    const argv = try parsed(arena,
        \\{"toolCallId":"t2","rawInput":{"command":["rm","-rf","zig-out"]}}
    );
    try std.testing.expectEqualStrings("Run rm -rf zig-out", summary(arena, argv, .execute, "Bash", ""));
}

test "an edit reads as its file and its size" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const one = try parsed(arena,
        \\{"toolCallId":"t","kind":"edit","content":[{"type":"diff","path":"/p/src/a.zig","oldText":"a\nb\nc","newText":"a\nB\nB2\nc"}]}
    );
    try std.testing.expectEqualStrings("Edit src/a.zig: +2 \u{2212}1", summary(arena, one, .edit, "Edit", "/p"));
    try std.testing.expect(detail(arena, one, .edit) == null);
    const created = try parsed(arena,
        \\{"toolCallId":"t","content":[{"type":"diff","path":"/q/new.zig","newText":"x\ny\n"}]}
    );
    try std.testing.expectEqualStrings("Create /q/new.zig: +2 \u{2212}0", summary(arena, created, .edit, "Write", "/p"));
    const two = try parsed(arena,
        \\{"toolCallId":"t","content":[{"type":"diff","path":"/p/a","oldText":"x","newText":"y"},{"type":"diff","path":"/p/b","oldText":"x","newText":"x\nz"}]}
    );
    try std.testing.expectEqualStrings("Edit 2 files: +2 \u{2212}1", summary(arena, two, .edit, "Edit", "/p"));
    const bare = try parsed(arena,
        \\{"toolCallId":"t","rawInput":{"file_path":"/p/c.zig"}}
    );
    try std.testing.expectEqualStrings("Edit c.zig", summary(arena, bare, .edit, "Edit", "/p"));
}

test "reads, deletes, moves, searches and fetches say what they touch" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const read = try parsed(arena,
        \\{"toolCallId":"t","locations":[{"path":"/p/a.zig","line":12},{"path":"/p/b.zig"}]}
    );
    try std.testing.expectEqualStrings("Read a.zig:12 and 1 more", summary(arena, read, .read, "Read", "/p/"));
    const del = try parsed(arena,
        \\{"toolCallId":"t","locations":[{"path":"/etc/hosts"}]}
    );
    try std.testing.expectEqualStrings("Delete /etc/hosts", summary(arena, del, .delete, "Delete", "/p"));
    const move = try parsed(arena,
        \\{"toolCallId":"t","locations":[{"path":"/p/a"},{"path":"/p/b"}]}
    );
    try std.testing.expectEqualStrings("Move a to b", summary(arena, move, .move, "Move", "/p"));
    const search = try parsed(arena,
        \\{"toolCallId":"t","rawInput":{"pattern":"fn main","path":"/p/src"}}
    );
    try std.testing.expectEqualStrings("Search for fn main in src", summary(arena, search, .search, "Grep", "/p"));
    // What the agent wrote cannot add lines beside the buttons.
    const sneaky = try parsed(arena,
        \\{"toolCallId":"t","rawInput":{"file_path":"/p/notes.md\n\n(read-only, safe to allow)"}}
    );
    try std.testing.expectEqualStrings("Edit notes.md\u{2026} (more lines)", summary(arena, sneaky, .edit, "Edit", "/p"));
    const web = try parsed(arena,
        \\{"toolCallId":"t","rawInput":{"query":"zig allocators"}}
    );
    try std.testing.expectEqualStrings("Search the web for zig allocators", summary(arena, web, .fetch, "Web", ""));
    const fetch = try parsed(arena,
        \\{"toolCallId":"t","rawInput":{"url":"https://ziglang.org"}}
    );
    try std.testing.expectEqualStrings("Fetch https://ziglang.org", summary(arena, fetch, .fetch, "Fetch", ""));
}

test "a call that says nothing else shows its input" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const other = try parsed(arena,
        \\{"toolCallId":"t","title":"mcp__fizzy__fizzy_call","rawInput":{"id":"pixi.fill"}}
    );
    try std.testing.expectEqualStrings("Fizzy call", summary(arena, other, .other, "Fizzy call", ""));
    const d = detail(arena, other, .other).?;
    try std.testing.expectEqualStrings("json", d.code.language);
    try std.testing.expect(std.mem.indexOf(u8, d.code.text, "\"pixi.fill\"") != null);
    // Nothing to show: no block, and the title stands.
    const none = try parsed(arena,
        \\{"toolCallId":"t"}
    );
    try std.testing.expect(detail(arena, none, .think) == null);
    try std.testing.expectEqualStrings("Think", summary(arena, none, .execute, "Think", ""));
}

test "requests still waiting are all handed back once, to be cancelled" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r: Requests = .{};
    defer r.deinit(gpa);
    r.put(gpa, 3, .{ .int = 7 });
    r.put(gpa, 4, RequestId.of(gpa, .{ .string = "req-8" }).?);
    r.put(gpa, 5, .{ .int = 9 });
    const answered = r.take(5).?;
    try std.testing.expectEqual(@as(i64, 9), answered.int);
    var left: std.ArrayListUnmanaged(Requests.Entry) = .empty;
    defer left.deinit(gpa);
    while (r.pop()) |e| try left.append(gpa, e);
    defer for (left.items) |e| e.request.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), left.items.len);
    var questions = [_]api.QuestionId{ left.items[0].question, left.items[1].question };
    std.mem.sort(api.QuestionId, &questions, {}, std.sort.asc(api.QuestionId));
    try std.testing.expectEqual([_]api.QuestionId{ 3, 4 }, questions);
    try std.testing.expect(r.take(3) == null);
    try std.testing.expect(r.pop() == null);
}

test "a diff's size skips what both ends share" {
    const n = counts("a\nb\nc", "a\nx\nc");
    try std.testing.expectEqual(@as(usize, 1), n.added);
    try std.testing.expectEqual(@as(usize, 1), n.removed);
    const fresh = counts("", "one\ntwo\n");
    try std.testing.expectEqual(@as(usize, 2), fresh.added);
    try std.testing.expectEqual(@as(usize, 0), fresh.removed);
    const emptied = counts("one\ntwo\n", "");
    try std.testing.expectEqual(@as(usize, 0), emptied.added);
    try std.testing.expectEqual(@as(usize, 2), emptied.removed);
}
