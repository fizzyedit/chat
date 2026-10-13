//! The chat's contract with its clients, as the ZON its commands take and return
//! (plans/CHAT_PLAN.md, "The contract"). std-only, and meant to be copied: a client keeps these
//! types on its side and writes and reads the same ZON, so nothing here is in fizzy's SDK or its
//! fingerprint. Bump `version` when a shape changes in a way an older client would misread.
//!
//! **What a client calls** (all `visibility = .internal`):
//! `chat.register` `{ client, title, version }`, `chat.unregister` `{ client }`,
//! `chat.open` `{ client, title }` → `{ chat }`, `chat.post` `{ chat, author, blocks }` →
//! `{ message }`, `chat.append_text` `{ chat, message, kind, text }`, `chat.append`
//! `{ chat, message, block }`, `chat.tool` `{ chat, message, tool }` → `{ tool }`,
//! `chat.update_tool` `{ chat, tool, update }`, `chat.set_plan` `{ chat, message, entries }`,
//! `chat.ask` `{ chat, message, question }` → `{ question }`, `chat.set_busy` `{ chat, busy }`,
//! `chat.set_title` `{ chat, title }`, `chat.set_resume` `{ chat, state }`, `chat.focus`
//! `{ chat }`.
//!
//! **What the chat calls on a client**, `<client>.<name>`, when the client registered it:
//! `chat_send` `{ chat, text }`, `chat_answer` `{ chat, question, option }`, `chat_cancel`
//! `{ chat }`, `chat_closed` `{ chat }`, `chat_resume` `{ chat, state }`, `chat_new` `{}`.
const std = @import("std");

/// The contract's version, which `chat.register` names.
pub const version: u32 = 1;

/// A conversation. Zero is never one.
pub const ChatId = u64;
/// A message within a conversation, a tool step within it, a question asked in it: each an
/// index, stable for the life of the conversation.
pub const MessageId = u32;
pub const ToolId = u32;
pub const QuestionId = u32;

/// Who a message is from: the person at fizzy (drawn on the right; only from their typing, never
/// posted by a client), the client's side (left), or a note about the conversation (centered and
/// quiet: "Connected", "The agent stopped").
pub const Author = enum(u8) { person, other, note };

/// A piece of a message.
pub const Block = union(enum) {
    /// Markdown (CommonMark and GFM), drawn as fizzy draws markdown.
    text: []const u8,
    /// Reasoning, shown as one quiet line that opens to show it.
    thought: []const u8,
    /// Code, highlighted by whichever plugin knows `language` (a fence's name: "zig").
    code: Code,
    /// An image: a file the chat reads and keeps beside the transcript (`path`), so no image
    /// bytes cross as ZON. PNG, JPEG, GIF, BMP or TGA.
    image: Image,
    /// A file, shown as a link that opens it.
    file: File,
    /// A change to a file, shown as a diff.
    diff: Diff,
    /// A checklist, updated in place (`chat.set_plan`).
    plan: []const PlanEntry,

    pub const Code = struct { language: []const u8 = "", text: []const u8 };
    pub const Image = struct {
        path: []const u8 = "",
        mime: []const u8 = "",
        alt: []const u8 = "",
        /// The image's bytes, read from `path` by the chat; a client leaves it empty.
        bytes: []const u8 = "",
    };
    pub const File = struct {
        path: []const u8,
        /// From 1; 0 for none.
        line: u32 = 0,
        end_line: u32 = 0,
        title: []const u8 = "",
    };
    pub const Diff = struct { path: []const u8, old: []const u8, new: []const u8 };
};

pub const PlanEntry = struct {
    text: []const u8,
    status: Status = .pending,
    pub const Status = enum(u8) { pending, in_progress, completed };
};

/// A step the other side takes in a turn, drawn as one compact line in its message, its content
/// behind a disclosure (diffs open).
pub const Tool = struct {
    kind: Kind = .other,
    title: []const u8,
    status: Status = .pending,
    content: []const Block = &.{},

    pub const Kind = enum(u8) { read, edit, delete, move, search, execute, think, fetch, other };
    pub const Status = enum(u8) { pending, running, done, failed };
};

/// A change to a tool step: each field given replaces what it had.
pub const ToolUpdate = struct {
    title: ?[]const u8 = null,
    status: ?Tool.Status = null,
    content: ?[]const Block = null,
};

/// A question with buttons: a permission request, a choice. Drawn on the tool step `tool` names,
/// else in the message; answered through the client's `chat_answer`.
pub const Question = struct {
    text: []const u8,
    options: []const Option,
    tool: ?ToolId = null,

    pub const Option = struct {
        id: []const u8,
        label: []const u8,
        kind: Kind = .neutral,
        pub const Kind = enum(u8) { allow, allow_always, deny, deny_always, neutral };
    };
};

/// Which streamed text a `chat.append_text` extends.
pub const TextKind = enum(u8) { text, thought };

// ---- the commands' arguments and results ----------------------------------------------------

pub const Register = struct { client: []const u8, title: []const u8, version: u32 = version };
pub const Unregister = struct { client: []const u8 };
pub const Open = struct { client: []const u8, title: []const u8 = "" };
pub const Opened = struct { chat: ChatId };
pub const Post = struct { chat: ChatId, author: Author = .other, blocks: []const Block = &.{} };
pub const Posted = struct { message: MessageId };
pub const AppendText = struct { chat: ChatId, message: MessageId, kind: TextKind = .text, text: []const u8 };
pub const Append = struct { chat: ChatId, message: MessageId, block: Block };
pub const AddTool = struct { chat: ChatId, message: MessageId, tool: Tool };
pub const Added = struct { tool: ToolId };
pub const UpdateTool = struct { chat: ChatId, tool: ToolId, update: ToolUpdate };
pub const SetPlan = struct { chat: ChatId, message: MessageId, entries: []const PlanEntry };
pub const Ask = struct { chat: ChatId, message: MessageId, question: Question };
pub const Asked = struct { question: QuestionId };
pub const SetBusy = struct { chat: ChatId, busy: bool };
pub const SetTitle = struct { chat: ChatId, title: []const u8 };
pub const SetResume = struct { chat: ChatId, state: []const u8 };
pub const Focus = struct { chat: ChatId };

/// To a client.
pub const Send = struct { chat: ChatId, text: []const u8 };
pub const Answer = struct { chat: ChatId, question: QuestionId, option: []const u8 };
pub const ChatOnly = struct { chat: ChatId };
pub const Resume = struct { chat: ChatId, state: []const u8 };
pub const Resumed = struct { resumed: bool };
/// A command that takes nothing (`chat_new`).
pub const Empty = struct {};

/// Parse a command's arguments, in `arena`.
pub fn parse(comptime T: type, arena: std.mem.Allocator, zon: []const u8) !T {
    const src = try arena.dupeZ(u8, std.mem.trim(u8, zon, " \t\r\n"));
    return std.zon.parse.fromSliceAlloc(T, arena, src, null, .{ .ignore_unknown_fields = true });
}

/// Write a command's arguments.
pub fn write(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(value, .{ .whitespace = false, .emit_default_optional_fields = false }, &out.writer);
    return out.written();
}

test "a post round-trips as ZON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zon = try write(arena, Post{ .chat = 7, .blocks = &.{
        .{ .text = "**hi**" },
        .{ .code = .{ .language = "zig", .text = "const a = 1;" } },
        .{ .plan = &.{.{ .text = "one", .status = .completed }} },
    } });
    const back = try parse(Post, arena, zon);
    try std.testing.expectEqual(@as(ChatId, 7), back.chat);
    try std.testing.expectEqualStrings("zig", back.blocks[1].code.language);
    try std.testing.expectEqual(PlanEntry.Status.completed, back.blocks[2].plan[0].status);
}
