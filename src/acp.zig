//! The Agent Client Protocol's wire, std-only: JSON-RPC 2.0, one message per line on the agent's
//! stdin and stdout, never a newline inside one (agentclientprotocol.com/protocol/transports).
//! What a message means is the chat's (`Chat.zig`); this file only frames, classifies and
//! splits.
const std = @import("std");
const json = std.json;

/// The protocol's major version, which `initialize` names.
pub const protocol_version = 1;

/// Write a request: `{"jsonrpc":"2.0","id":…,"method":…,"params":…}` and a newline.
pub fn writeRequest(w: *std.Io.Writer, id: i64, method: []const u8, params: anytype) !void {
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try json.Stringify.value(method, .{}, w);
    try w.writeAll(",\"params\":");
    try json.Stringify.value(params, .{ .emit_null_optional_fields = false }, w);
    try w.writeAll("}\n");
}

/// Write a notification: a request with no id, which gets no answer.
pub fn writeNotification(w: *std.Io.Writer, method: []const u8, params: anytype) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try json.Stringify.value(method, .{}, w);
    try w.writeAll(",\"params\":");
    try json.Stringify.value(params, .{ .emit_null_optional_fields = false }, w);
    try w.writeAll("}\n");
}

/// Answer the agent's request `id` (as the agent wrote it: a number or a string) with `result`.
pub fn writeResult(w: *std.Io.Writer, id: json.Value, result: anytype) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, w);
    try w.writeAll(",\"result\":");
    try json.Stringify.value(result, .{ .emit_null_optional_fields = false }, w);
    try w.writeAll("}\n");
}

/// Refuse the agent's request `id`.
pub fn writeError(w: *std.Io.Writer, id: json.Value, code: i64, message: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, w);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try json.Stringify.value(message, .{}, w);
    try w.writeAll("}}\n");
}

pub const method_not_found = -32601;

/// One message from the agent, by what it is.
pub const Inbound = union(enum) {
    /// An answer to one of ours.
    /// `code` is the error's (`auth.auth_required`, say), 0 with a result.
    response: struct { id: i64, result: ?json.Value, err: ?[]const u8, code: i64 = 0 },
    /// The agent asks something of us, and waits for `writeResult` / `writeError`.
    request: struct { id: json.Value, method: []const u8, params: json.Value },
    /// The agent tells us something (`session/update`).
    notification: struct { method: []const u8, params: json.Value },
    /// Not a message this protocol has.
    invalid,

    pub fn classify(v: json.Value) Inbound {
        const o = switch (v) {
            .object => |o| o,
            else => return .invalid,
        };
        const id = o.get("id");
        if (o.get("method")) |m| {
            const method = switch (m) {
                .string => |s| s,
                else => return .invalid,
            };
            const params = o.get("params") orelse .null;
            if (id) |i| return .{ .request = .{ .id = i, .method = method, .params = params } };
            return .{ .notification = .{ .method = method, .params = params } };
        }
        const n = switch (id orelse return .invalid) {
            .integer => |n| n,
            else => return .invalid,
        };
        if (o.get("error")) |e| {
            const message: []const u8 = if (e == .object) if (e.object.get("message")) |m| (if (m == .string) m.string else "error") else "error" else "error";
            const code: i64 = if (e == .object) if (e.object.get("code")) |c| (if (c == .integer) c.integer else 0) else 0 else 0;
            return .{ .response = .{ .id = n, .result = null, .err = message, .code = code } };
        }
        return .{ .response = .{ .id = n, .result = o.get("result") orelse .null, .err = null } };
    }
};

/// The longest line read from an agent: a tool call's diff of a large file still fits.
pub const max_line = 32 * 1024 * 1024;

/// The next line from `r`, without its newline, into `out` (cleared first). Null at the end of
/// the stream.
pub fn readLine(r: *std.Io.Reader, out: *std.Io.Writer.Allocating) !?[]const u8 {
    out.clearRetainingCapacity();
    _ = try r.streamDelimiterLimit(&out.writer, '\n', .limited(max_line));
    // At the end of the stream the buffer is empty; otherwise it starts with the newline.
    if (r.bufferedLen() == 0) {
        if (out.written().len == 0) return null;
    } else r.toss(1);
    return std.mem.trimEnd(u8, out.written(), "\r");
}

/// A command line as a person types it into a setting, split into arguments: spaces separate,
/// and "double" or 'single' quotes keep spaces in one argument.
pub fn splitCommand(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    var cur: std.ArrayListUnmanaged(u8) = .empty;
    var quote: ?u8 = null;
    var in_arg = false;
    for (line) |c| {
        if (quote) |q| {
            if (c == q) quote = null else try cur.append(arena, c);
            continue;
        }
        switch (c) {
            '"', '\'' => {
                quote = c;
                in_arg = true;
            },
            ' ', '\t', '\n', '\r' => if (in_arg) {
                try args.append(arena, try cur.toOwnedSlice(arena));
                in_arg = false;
            },
            else => {
                try cur.append(arena, c);
                in_arg = true;
            },
        }
    }
    if (in_arg) try args.append(arena, try cur.toOwnedSlice(arena));
    return args.items;
}

test "a command line splits on spaces, and quotes keep them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = try splitCommand(arena.allocator(), "  npx -y \"@scope/my agent\" --flag='a b'  ");
    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("npx", args[0]);
    try std.testing.expectEqualStrings("@scope/my agent", args[2]);
    try std.testing.expectEqualStrings("--flag=a b", args[3]);
    try std.testing.expectEqual(@as(usize, 0), (try splitCommand(arena.allocator(), "   ")).len);
}

test "a request is one line, its strings' newlines escaped" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRequest(&out.writer, 3, "session/prompt", .{
        .sessionId = "s1",
        .prompt = &[_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = "two\nlines" }},
    });
    const line = out.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    try std.testing.expect(std.mem.indexOf(u8, line, "two\\nlines") != null);
}

test "messages read as what they are" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn f(al: std.mem.Allocator, s: []const u8) !json.Value {
            return json.parseFromSliceLeaky(json.Value, al, s, .{});
        }
    }.f;
    const r = Inbound.classify(try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"x\"}}"));
    try std.testing.expectEqual(@as(i64, 1), r.response.id);
    const e = Inbound.classify(try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-1,\"message\":\"no\"}}"));
    try std.testing.expectEqualStrings("no", e.response.err.?);
    try std.testing.expectEqual(@as(i64, -1), e.response.code);
    const q = Inbound.classify(try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"method\":\"session/request_permission\",\"params\":{}}"));
    try std.testing.expectEqualStrings("session/request_permission", q.request.method);
    const n = Inbound.classify(try parse(a, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{}}"));
    try std.testing.expectEqualStrings("session/update", n.notification.method);
    try std.testing.expect(Inbound.classify(try parse(a, "[1]")) == .invalid);
}

test "lines come off a stream one at a time, the last without its newline" {
    var r: std.Io.Reader = .fixed("{\"a\":1}\r\n{\"b\":2}\n{\"c\":3}");
    var line: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();
    try std.testing.expectEqualStrings("{\"a\":1}", (try readLine(&r, &line)).?);
    try std.testing.expectEqualStrings("{\"b\":2}", (try readLine(&r, &line)).?);
    try std.testing.expectEqualStrings("{\"c\":3}", (try readLine(&r, &line)).?);
    try std.testing.expect((try readLine(&r, &line)) == null);
}
