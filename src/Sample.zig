//! A scripted client, in Debug builds only: every kind of block the chat draws, answered through
//! the same commands any client uses (`api.zig`). What the chat looks like is checked against it
//! with no agent running (plans/CHAT_PLAN.md: the consumer that is not an agent).
//!
//! `chat.sample` opens a sample chat. Whatever the person sends, the reply shows thinking,
//! markdown, code, an image, a file link, a plan, and tool steps: read, an edit with its diff, a
//! run that failed, and one waiting on a question.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const api = @import("api.zig");

pub const client_id = "sample";
const png = @embedFile("sample.png");

pub fn register(host: *sdk.Host, owner: *sdk.Plugin) !void {
    inline for (.{
        .{ "chat_send", api.Send, onSend },
        .{ "chat_answer", api.Answer, onAnswer },
        .{ "chat_new", api.Empty, onNew },
    }) |entry| try host.registerCommand(.{
        .id = client_id ++ "." ++ entry[0],
        .owner = owner,
        .title = "Sample: " ++ entry[0],
        .visibility = .internal,
        .runWith = Handler(entry[1], entry[2]).run,
    });
    try host.registerCommand(.{
        .id = "chat.sample",
        .owner = owner,
        .title = "Open a Sample Chat",
        .run = runSample,
    });
    _ = call("chat.register", api.Register{ .client = client_id, .title = "Sample" });
}

fn Handler(comptime Args: type, comptime f: fn (Args) void) type {
    return struct {
        fn run(_: *anyopaque, c: *sdk.Command.Call) anyerror!void {
            f(api.parse(Args, c.arena, c.args) catch |err| return c.fail("{t}", .{err}));
        }
    };
}

fn call(comptime id: []const u8, args: anytype) ?[]const u8 {
    const host = sdk.host();
    const arena = host.arena();
    const zon = api.write(arena, args) catch return null;
    return switch (host.callCommand(id, zon, arena)) {
        .ok => |r| r orelse "",
        else => |o| {
            dvui.log.warn("sample: {s} refused: {any}", .{ id, o });
            return null;
        },
    };
}

fn runSample(_: *anyopaque) anyerror!void {
    onNew(.{});
}

fn onNew(_: api.Empty) void {
    const r = call("chat.open", api.Open{ .client = client_id, .title = "Sample chat" }) orelse return;
    const opened = api.parse(api.Opened, sdk.host().arena(), r) catch return;
    _ = call("chat.post", api.Post{ .chat = opened.chat, .blocks = &.{
        .{ .text = "Hi! I'm the **sample** client. Send anything and I'll answer with every kind of block the chat draws." },
    } });
}

fn onAnswer(a: api.Answer) void {
    const r = call("chat.post", api.Post{ .chat = a.chat, .author = .note, .blocks = &.{
        .{ .text = std.fmt.allocPrint(sdk.host().arena(), "Answered: {s}", .{a.option}) catch "Answered." },
    } });
    _ = r;
}

fn onSend(a: api.Send) void {
    const arena = sdk.host().arena();
    const m = blk: {
        const r = call("chat.post", api.Post{ .chat = a.chat }) orelse return;
        break :blk (api.parse(api.Posted, arena, r) catch return).message;
    };
    const ap = struct {
        fn text(chat: api.ChatId, msg: api.MessageId, kind: api.TextKind, t: []const u8) void {
            _ = call("chat.append_text", api.AppendText{ .chat = chat, .message = msg, .kind = kind, .text = t });
        }
        fn block(chat: api.ChatId, msg: api.MessageId, b: api.Block) void {
            _ = call("chat.append", api.Append{ .chat = chat, .message = msg, .block = b });
        }
        fn tool(chat: api.ChatId, msg: api.MessageId, t: api.Tool) ?api.ToolId {
            const r = call("chat.tool", api.AddTool{ .chat = chat, .message = msg, .tool = t }) orelse return null;
            return (api.parse(api.Added, sdk.host().arena(), r) catch return null).tool;
        }
    };
    ap.text(a.chat, m, .thought, "The person said something. Show them every block, in the order a real turn would use them.");
    ap.text(a.chat, m, .text, std.fmt.allocPrint(arena,
        \\You said: *{s}*
        \\
        \\Here is **markdown**: `inline code`, a [link](https://fizzyed.it), and
        \\
        \\- a list
        \\- with a second item
        \\
        \\> and a quote.
    , .{a.text}) catch "You said something.");
    _ = ap.tool(a.chat, m, .{ .kind = .read, .title = "Read build.zig", .status = .done, .content = &.{.{ .file = .{ .path = "build.zig", .line = 12 } }} });
    _ = ap.tool(a.chat, m, .{ .kind = .edit, .title = "Edit src/main.zig", .status = .done, .content = &.{.{ .diff = .{
        .path = "src/main.zig",
        .old = "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"hi\\n\", .{});\n}\n",
        .new = "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"hello, fizzy\\n\", .{});\n}\n",
    } }} });
    _ = ap.tool(a.chat, m, .{ .kind = .execute, .title = "Run zig build test", .status = .failed, .content = &.{.{ .text = "test 1/3 a... OK\ntest 2/3 b... FAIL\n  expected 2, found 3\ntest 3/3 c... OK\n1 failed" }} });
    if (ap.tool(a.chat, m, .{ .kind = .execute, .title = "Run zig build", .status = .pending })) |tid| {
        _ = call("chat.ask", api.Ask{ .chat = a.chat, .message = m, .question = .{ .text = "", .tool = tid, .options = &.{
            .{ .id = "allow", .label = "Allow", .kind = .allow },
            .{ .id = "always", .label = "Always", .kind = .allow_always },
            .{ .id = "deny", .label = "Deny", .kind = .deny },
        } } });
    }
    ap.block(a.chat, m, .{ .code = .{ .language = "zig", .text = "pub fn main() void {\n    std.debug.print(\"hello, fizzy\\n\", .{});\n}" } });
    if (imagePath(arena)) |path| ap.block(a.chat, m, .{ .image = .{ .path = path, .mime = "image/png", .alt = "A gradient" } });
    _ = call("chat.set_plan", api.SetPlan{ .chat = a.chat, .message = m, .entries = &.{
        .{ .text = "Read the build", .status = .completed },
        .{ .text = "Change the greeting", .status = .in_progress },
        .{ .text = "Run the tests" },
    } });
    ap.text(a.chat, m, .text, "That's everything. **Allow** or **Deny** the last step to see a question answered.");
}

/// The sample image, written where the chat can read it.
fn imagePath(arena: std.mem.Allocator) ?[]const u8 {
    const plugins = sdk.host().plugins_dir orelse return null;
    const dir = std.fs.path.join(arena, &.{ std.fs.path.dirname(plugins) orelse plugins, "chats", ".incoming" }) catch return null;
    std.Io.Dir.cwd().createDirPath(dvui.io, dir) catch {};
    const path = std.fs.path.join(arena, &.{ dir, "sample.png" }) catch return null;
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = png }) catch return null;
    return path;
}
