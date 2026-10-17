//! What a conversation holds: its messages, each a list of parts (blocks of content, tool steps,
//! questions), and the tool steps and questions by id (plans/CHAT_PLAN.md). The chat's commands
//! land here (`Commands.zig`); `View.zig` draws it; `save` and `load` keep it in a `.chat`
//! file. Everything here is owned by `gpa`: what the service is handed, it copies.
//!
//! Ids are indices: a message, tool step or question is only ever added, never removed, so its
//! index is its id for the life of the conversation, across saves and reloads.
//!
//! Each message has a `version`, bumped by anything that changes how it looks, which is what
//! `View` keys a message's kept height by: streaming text into the last message re-lays that one.
const Transcript = @This();

const std = @import("std");
const chat = @import("api.zig");

gpa: std.mem.Allocator,
messages: std.ArrayListUnmanaged(Message) = .empty,
tools: std.ArrayListUnmanaged(Tool) = .empty,
questions: std.ArrayListUnmanaged(Question) = .empty,
/// Bumped by every change: the chat saves when it has moved since the last save.
version: u64 = 0,

pub const Message = struct {
    author: chat.Author,
    parts: std.ArrayListUnmanaged(Part) = .empty,
    version: u32 = 0,

    pub const Part = union(enum) {
        block: Block,
        tool: chat.ToolId,
        question: chat.QuestionId,
    };
};

/// A block, owned. Text and thoughts grow as they stream in.
pub const Block = union(enum) {
    text: std.ArrayListUnmanaged(u8),
    thought: std.ArrayListUnmanaged(u8),
    code: struct { language: []u8, text: []u8 },
    image: Image,
    file: struct { path: []u8, line: u32, end_line: u32, title: []u8 },
    diff: struct { path: []u8, old: []u8, new: []u8 },
    plan: []PlanEntry,

    pub const Image = struct {
        mime: []u8,
        bytes: []u8,
        alt: []u8,
        /// Of the bytes: the image's name beside the transcript, and its texture's key.
        hash: u64,
    };
    pub const PlanEntry = struct { text: []u8, status: chat.PlanEntry.Status };

    pub fn copy(gpa: std.mem.Allocator, b: chat.Block) !Block {
        return switch (b) {
            .text => |t| .{ .text = try listOf(gpa, t) },
            .thought => |t| .{ .thought = try listOf(gpa, t) },
            .code => |c| .{ .code = .{ .language = try gpa.dupe(u8, c.language), .text = try gpa.dupe(u8, c.text) } },
            .image => |i| .{ .image = .{
                .mime = try gpa.dupe(u8, i.mime),
                .bytes = try gpa.dupe(u8, i.bytes),
                .alt = try gpa.dupe(u8, i.alt),
                .hash = std.hash.XxHash3.hash(0, i.bytes),
            } },
            .file => |f| .{ .file = .{ .path = try gpa.dupe(u8, f.path), .line = f.line, .end_line = f.end_line, .title = try gpa.dupe(u8, f.title) } },
            .diff => |d| .{ .diff = .{ .path = try gpa.dupe(u8, d.path), .old = try gpa.dupe(u8, d.old), .new = try gpa.dupe(u8, d.new) } },
            .plan => |entries| .{ .plan = try planOf(gpa, entries) },
        };
    }

    pub fn deinit(self: *Block, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text, .thought => |*t| t.deinit(gpa),
            .code => |c| {
                gpa.free(c.language);
                gpa.free(c.text);
            },
            .image => |i| {
                gpa.free(i.mime);
                gpa.free(i.bytes);
                gpa.free(i.alt);
            },
            .file => |f| {
                gpa.free(f.path);
                gpa.free(f.title);
            },
            .diff => |d| {
                gpa.free(d.path);
                gpa.free(d.old);
                gpa.free(d.new);
            },
            .plan => |p| freePlan(gpa, p),
        }
    }

    /// As the service names it, borrowing this block's bytes.
    pub fn view(self: *const Block) chat.Block {
        return switch (self.*) {
            .text => |t| .{ .text = t.items },
            .thought => |t| .{ .thought = t.items },
            .code => |c| .{ .code = .{ .language = c.language, .text = c.text } },
            .image => |i| .{ .image = .{ .mime = i.mime, .bytes = i.bytes, .alt = i.alt } },
            .file => |f| .{ .file = .{ .path = f.path, .line = f.line, .end_line = f.end_line, .title = f.title } },
            .diff => |d| .{ .diff = .{ .path = d.path, .old = d.old, .new = d.new } },
            .plan => &.{}, // not handed back: a plan is the chat's to draw
        };
    }
};

pub const Tool = struct {
    message: chat.MessageId,
    kind: chat.Tool.Kind,
    title: std.ArrayListUnmanaged(u8) = .empty,
    status: chat.Tool.Status,
    content: std.ArrayListUnmanaged(Block) = .empty,
    /// The question asked about this step, drawn on its line.
    question: ?chat.QuestionId = null,
    /// Its content shown: diffs start open, everything else closed.
    open: bool = false,
};

pub const Question = struct {
    message: chat.MessageId,
    tool: ?chat.ToolId,
    text: []u8,
    options: []Option,
    /// The option chosen, once answered; `cancelled` when the turn ended first.
    answer: Answer = .open,

    pub const Option = struct { id: []u8, label: []u8, kind: chat.Question.Option.Kind };
    pub const Answer = union(enum) { open, chosen: u32, cancelled };
};

pub fn deinit(self: *Transcript) void {
    for (self.messages.items) |*m| {
        for (m.parts.items) |*p| if (p.* == .block) p.block.deinit(self.gpa);
        m.parts.deinit(self.gpa);
    }
    self.messages.deinit(self.gpa);
    for (self.tools.items) |*t| {
        t.title.deinit(self.gpa);
        for (t.content.items) |*b| b.deinit(self.gpa);
        t.content.deinit(self.gpa);
    }
    self.tools.deinit(self.gpa);
    for (self.questions.items) |q| freeQuestion(self.gpa, q);
    self.questions.deinit(self.gpa);
}

fn freeQuestion(gpa: std.mem.Allocator, q: Question) void {
    gpa.free(q.text);
    for (q.options) |o| {
        gpa.free(o.id);
        gpa.free(o.label);
    }
    gpa.free(q.options);
}

fn changed(self: *Transcript, id: chat.MessageId) void {
    self.version += 1;
    if (id < self.messages.items.len) self.messages.items[id].version +%= 1;
}

pub fn message(self: *Transcript, id: chat.MessageId) !*Message {
    if (id >= self.messages.items.len) return error.NoSuchMessage;
    return &self.messages.items[id];
}

// ---- what the service does ------------------------------------------------------------------

pub fn post(self: *Transcript, author: chat.Author, blocks: []const chat.Block) !chat.MessageId {
    try self.messages.append(self.gpa, .{ .author = author });
    const id: chat.MessageId = @intCast(self.messages.items.len - 1);
    for (blocks) |b| try self.append(id, b);
    self.changed(id);
    return id;
}

pub fn append(self: *Transcript, id: chat.MessageId, b: chat.Block) !void {
    const m = try self.message(id);
    var owned = try Block.copy(self.gpa, b);
    errdefer owned.deinit(self.gpa);
    try m.parts.append(self.gpa, .{ .block = owned });
    self.changed(id);
}

/// Extend the message's last part when it is text of `kind`; otherwise start a block.
pub fn appendText(self: *Transcript, id: chat.MessageId, kind: chat.TextKind, text: []const u8) !void {
    const m = try self.message(id);
    if (m.parts.items.len > 0) {
        const last = &m.parts.items[m.parts.items.len - 1];
        if (last.* == .block) switch (last.block) {
            .text => |*t| if (kind == .text) {
                try t.appendSlice(self.gpa, text);
                return self.changed(id);
            },
            .thought => |*t| if (kind == .thought) {
                try t.appendSlice(self.gpa, text);
                return self.changed(id);
            },
            else => {},
        };
    }
    try self.append(id, switch (kind) {
        .text => .{ .text = text },
        .thought => .{ .thought = text },
    });
}

pub fn tool(self: *Transcript, id: chat.MessageId, t: chat.Tool) !chat.ToolId {
    const m = try self.message(id);
    var owned: Tool = .{ .message = id, .kind = t.kind, .status = t.status };
    errdefer {
        owned.title.deinit(self.gpa);
        for (owned.content.items) |*b| b.deinit(self.gpa);
        owned.content.deinit(self.gpa);
    }
    try owned.title.appendSlice(self.gpa, t.title);
    for (t.content) |b| try owned.content.append(self.gpa, try Block.copy(self.gpa, b));
    owned.open = hasDiff(owned.content.items);
    try self.tools.append(self.gpa, owned);
    const tid: chat.ToolId = @intCast(self.tools.items.len - 1);
    try m.parts.append(self.gpa, .{ .tool = tid });
    self.changed(id);
    return tid;
}

pub fn updateTool(self: *Transcript, tid: chat.ToolId, u: chat.ToolUpdate) !void {
    if (tid >= self.tools.items.len) return error.NoSuchTool;
    const t = &self.tools.items[tid];
    if (u.title) |title| {
        t.title.clearRetainingCapacity();
        try t.title.appendSlice(self.gpa, title);
    }
    if (u.status) |s| t.status = s;
    if (u.content) |content| {
        for (t.content.items) |*b| b.deinit(self.gpa);
        t.content.clearRetainingCapacity();
        for (content) |b| try t.content.append(self.gpa, try Block.copy(self.gpa, b));
        if (hasDiff(t.content.items)) t.open = true;
    }
    self.changed(t.message);
}

fn hasDiff(blocks: []const Block) bool {
    for (blocks) |b| if (b == .diff) return true;
    return false;
}

/// The message's plan replaced in place, or added.
pub fn setPlan(self: *Transcript, id: chat.MessageId, entries: []const chat.PlanEntry) !void {
    const m = try self.message(id);
    const plan = try planOf(self.gpa, entries);
    for (m.parts.items) |*p| if (p.* == .block and p.block == .plan) {
        freePlan(self.gpa, p.block.plan);
        p.block.plan = plan;
        return self.changed(id);
    };
    errdefer freePlan(self.gpa, plan);
    try m.parts.append(self.gpa, .{ .block = .{ .plan = plan } });
    self.changed(id);
}

pub fn ask(self: *Transcript, id: chat.MessageId, q: chat.Question) !chat.QuestionId {
    const m = try self.message(id);
    if (q.tool) |tid| if (tid >= self.tools.items.len) return error.NoSuchTool;
    const options = try self.gpa.alloc(Question.Option, q.options.len);
    var made: usize = 0;
    errdefer {
        for (options[0..made]) |o| {
            self.gpa.free(o.id);
            self.gpa.free(o.label);
        }
        self.gpa.free(options);
    }
    for (q.options, 0..) |o, i| {
        const oid = try self.gpa.dupe(u8, o.id);
        errdefer self.gpa.free(oid);
        options[i] = .{ .id = oid, .label = try self.gpa.dupe(u8, o.label), .kind = o.kind };
        made += 1;
    }
    try self.questions.append(self.gpa, .{ .message = id, .tool = q.tool, .text = try self.gpa.dupe(u8, q.text), .options = options });
    const qid: chat.QuestionId = @intCast(self.questions.items.len - 1);
    if (q.tool) |tid| {
        self.tools.items[tid].question = qid;
        self.changed(self.tools.items[tid].message);
    } else try m.parts.append(self.gpa, .{ .question = qid });
    self.changed(id);
    return qid;
}

/// The person chose `option`; the option's id for the client, or null when it was not open.
pub fn answer(self: *Transcript, qid: chat.QuestionId, option: u32) ?[]const u8 {
    if (qid >= self.questions.items.len) return null;
    const q = &self.questions.items[qid];
    if (q.answer != .open or option >= q.options.len) return null;
    q.answer = .{ .chosen = option };
    self.changed(if (q.tool) |t| self.tools.items[t].message else q.message);
    return q.options[option].id;
}

/// Close every open question: the turn ended without them.
pub fn cancelQuestions(self: *Transcript) void {
    for (self.questions.items) |*q| if (q.answer == .open) {
        q.answer = .cancelled;
        self.changed(if (q.tool) |t| self.tools.items[t].message else q.message);
    };
}

fn listOf(gpa: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged(u8) {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(gpa, text);
    return l;
}

fn planOf(gpa: std.mem.Allocator, entries: []const chat.PlanEntry) ![]Block.PlanEntry {
    const out = try gpa.alloc(Block.PlanEntry, entries.len);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |e| gpa.free(e.text);
        gpa.free(out);
    }
    for (entries, 0..) |e, i| {
        out[i] = .{ .text = try gpa.dupe(u8, e.text), .status = e.status };
        made += 1;
    }
    return out;
}

fn freePlan(gpa: std.mem.Allocator, plan: []Block.PlanEntry) void {
    for (plan) |e| gpa.free(e.text);
    gpa.free(plan);
}

// ---- on disk --------------------------------------------------------------------------------

/// A transcript as written: ZON, its first line a comment naming the chat so a listing reads no
/// conversation whole. Images are not in it but beside it, by hash (`images_dir`), so it stays
/// small text.
pub const Saved = struct {
    version: u32 = format_version,
    client: []const u8 = "",
    title: []const u8 = "",
    /// The project folder the chat was started in, by which the list groups it; empty for none.
    folder: []const u8 = "",
    @"resume": []const u8 = "",
    messages: []const SavedMessage = &.{},
    tools: []const SavedTool = &.{},
    questions: []const SavedQuestion = &.{},
};
pub const format_version = 2;

const SavedMessage = struct { author: chat.Author, parts: []const SavedPart = &.{} };
const SavedPart = union(enum) {
    text: []const u8,
    thought: []const u8,
    code: struct { language: []const u8 = "", text: []const u8 },
    image: struct { mime: []const u8, file: []const u8, alt: []const u8 = "" },
    file: struct { path: []const u8, line: u32 = 0, end_line: u32 = 0, title: []const u8 = "" },
    diff: struct { path: []const u8, old: []const u8, new: []const u8 },
    plan: []const struct { text: []const u8, status: chat.PlanEntry.Status = .pending },
    tool: u32,
    question: u32,
};
const SavedTool = struct {
    message: u32,
    kind: chat.Tool.Kind = .other,
    title: []const u8,
    status: chat.Tool.Status = .done,
    content: []const SavedPart = &.{},
    question: ?u32 = null,
};
const SavedQuestion = struct {
    message: u32,
    tool: ?u32 = null,
    text: []const u8,
    options: []const struct { id: []const u8, label: []const u8, kind: chat.Question.Option.Kind = .neutral } = &.{},
    /// The chosen option's index; null when it was never answered.
    chosen: ?u32 = null,
};

pub const Header = struct { client: []const u8, title: []const u8, folder: []const u8 = "", @"resume": []const u8 };

/// Write the transcript to `w`, and its images into `images_dir` (each once, by hash).
pub fn save(self: *const Transcript, w: *std.Io.Writer, header: Header, images_dir: []const u8, io: std.Io) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = try arena.alloc(SavedMessage, self.messages.items.len);
    for (self.messages.items, messages) |m, *out| {
        const parts = try arena.alloc(SavedPart, m.parts.items.len);
        for (m.parts.items, parts) |p, *sp| sp.* = switch (p) {
            .block => |*b| try savedBlock(arena, b, images_dir, io),
            .tool => |t| .{ .tool = t },
            .question => |q| .{ .question = q },
        };
        out.* = .{ .author = m.author, .parts = parts };
    }
    const tools = try arena.alloc(SavedTool, self.tools.items.len);
    for (self.tools.items, tools) |t, *out| {
        const content = try arena.alloc(SavedPart, t.content.items.len);
        for (t.content.items, content) |*b, *sp| sp.* = try savedBlock(arena, b, images_dir, io);
        out.* = .{ .message = t.message, .kind = t.kind, .title = t.title.items, .status = t.status, .content = content, .question = t.question };
    }
    const questions = try arena.alloc(SavedQuestion, self.questions.items.len);
    for (self.questions.items, questions) |q, *out| {
        const options = try arena.alloc(@typeInfo(@FieldType(SavedQuestion, "options")).pointer.child, q.options.len);
        for (q.options, options) |o, *so| so.* = .{ .id = o.id, .label = o.label, .kind = o.kind };
        out.* = .{ .message = q.message, .tool = q.tool, .text = q.text, .options = options, .chosen = switch (q.answer) {
            .chosen => |c| c,
            else => null,
        } };
    }
    // The first two lines are what the list reads (`Explorer`): the title, then the folder.
    const title = header.title;
    try w.print("// {s}\n// folder {s}\n", .{ title[0 .. std.mem.indexOfScalar(u8, title, '\n') orelse title.len], header.folder });
    try std.zon.stringify.serialize(Saved{
        .client = header.client,
        .title = header.title,
        .folder = header.folder,
        .@"resume" = header.@"resume",
        .messages = messages,
        .tools = tools,
        .questions = questions,
    }, .{}, w);
    try w.writeByte('\n');
}

fn savedBlock(arena: std.mem.Allocator, b: *const Block, images_dir: []const u8, io: std.Io) !SavedPart {
    return switch (b.*) {
        .text => |t| .{ .text = t.items },
        .thought => |t| .{ .thought = t.items },
        .code => |c| .{ .code = .{ .language = c.language, .text = c.text } },
        .image => |i| blk: {
            const name = try std.fmt.allocPrint(arena, "{x:0>16}.{s}", .{ i.hash, extensionOf(i.mime) });
            const path = try std.fs.path.join(arena, &.{ images_dir, name });
            std.Io.Dir.cwd().access(io, path, .{}) catch {
                std.Io.Dir.cwd().createDirPath(io, images_dir) catch {};
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = i.bytes });
            };
            break :blk .{ .image = .{ .mime = i.mime, .file = name, .alt = i.alt } };
        },
        .file => |f| .{ .file = .{ .path = f.path, .line = f.line, .end_line = f.end_line, .title = f.title } },
        .diff => |d| .{ .diff = .{ .path = d.path, .old = d.old, .new = d.new } },
        .plan => |p| blk: {
            const entries = try arena.alloc(@typeInfo(@FieldType(SavedPart, "plan")).pointer.child, p.len);
            for (p, entries) |e, *se| se.* = .{ .text = e.text, .status = e.status };
            break :blk .{ .plan = entries };
        },
    };
}

fn extensionOf(mime: []const u8) []const u8 {
    const known = [_][2][]const u8{ .{ "image/png", "png" }, .{ "image/jpeg", "jpg" }, .{ "image/gif", "gif" }, .{ "image/bmp", "bmp" }, .{ "image/webp", "webp" } };
    for (known) |k| if (std.ascii.eqlIgnoreCase(mime, k[0])) return k[1];
    return "bin";
}

/// What `load` found in the header: owned by the caller's allocator.
pub const Loaded = struct { client: []u8, title: []u8, folder: []u8, @"resume": []u8 };

/// Read a transcript `save` wrote (or the first version's, converted). Images are read back from
/// `images_dir`; one that is missing is left out.
pub fn load(self: *Transcript, bytes: []const u8, images_dir: []const u8, io: std.Io) !Loaded {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try arena.dupeSentinel(u8, bytes, 0);
    const Probe = struct { version: u32 = 1 };
    var diag: std.zon.parse.Diagnostics = undefined;
    const probe = std.zon.parse.fromSlice(Probe, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diag, .ignore_unknown_fields = true }) catch Probe{};
    if (probe.version < format_version) return self.loadV1(arena, source);

    const saved = try std.zon.parse.fromSlice(Saved, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diag, .ignore_unknown_fields = true });
    for (saved.messages) |m| {
        try self.messages.append(self.gpa, .{ .author = m.author });
        const msg = &self.messages.items[self.messages.items.len - 1];
        for (m.parts) |p| switch (p) {
            .tool => |t| try msg.parts.append(self.gpa, .{ .tool = t }),
            .question => |q| try msg.parts.append(self.gpa, .{ .question = q }),
            else => if (try self.loadedBlock(arena, p, images_dir, io)) |b| try msg.parts.append(self.gpa, .{ .block = b }),
        };
    }
    for (saved.tools) |t| {
        var owned: Tool = .{ .message = t.message, .kind = t.kind, .status = t.status, .question = t.question };
        try owned.title.appendSlice(self.gpa, t.title);
        for (t.content) |p| if (try self.loadedBlock(arena, p, images_dir, io)) |b| try owned.content.append(self.gpa, b);
        owned.open = hasDiff(owned.content.items);
        try self.tools.append(self.gpa, owned);
    }
    for (saved.questions) |q| {
        const options = try self.gpa.alloc(Question.Option, q.options.len);
        for (q.options, options) |o, *out| out.* = .{ .id = try self.gpa.dupe(u8, o.id), .label = try self.gpa.dupe(u8, o.label), .kind = o.kind };
        try self.questions.append(self.gpa, .{
            .message = q.message,
            .tool = q.tool,
            .text = try self.gpa.dupe(u8, q.text),
            .options = options,
            // A question saved unanswered was never answered: its turn is over.
            .answer = if (q.chosen) |c| .{ .chosen = c } else .cancelled,
        });
    }
    try self.validate();
    return .{
        .client = try self.gpa.dupe(u8, saved.client),
        .title = try self.gpa.dupe(u8, saved.title),
        .folder = try self.gpa.dupe(u8, saved.folder),
        .@"resume" = try self.gpa.dupe(u8, saved.@"resume"),
    };
}

/// Every id a part names is one the transcript has, so drawing never checks again.
fn validate(self: *Transcript) !void {
    for (self.messages.items) |m| for (m.parts.items) |p| switch (p) {
        .tool => |t| if (t >= self.tools.items.len) return error.BadTranscript,
        .question => |q| if (q >= self.questions.items.len) return error.BadTranscript,
        .block => {},
    };
    for (self.tools.items) |t| {
        if (t.message >= self.messages.items.len) return error.BadTranscript;
        if (t.question) |q| if (q >= self.questions.items.len) return error.BadTranscript;
    }
    for (self.questions.items) |q| {
        if (q.message >= self.messages.items.len) return error.BadTranscript;
        if (q.tool) |t| if (t >= self.tools.items.len) return error.BadTranscript;
        if (q.answer == .chosen and q.answer.chosen >= q.options.len) return error.BadTranscript;
    }
}

fn loadedBlock(self: *Transcript, arena: std.mem.Allocator, p: SavedPart, images_dir: []const u8, io: std.Io) !?Block {
    return switch (p) {
        .text => |t| try Block.copy(self.gpa, .{ .text = t }),
        .thought => |t| try Block.copy(self.gpa, .{ .thought = t }),
        .code => |c| try Block.copy(self.gpa, .{ .code = .{ .language = c.language, .text = c.text } }),
        .image => |i| blk: {
            const path = try std.fs.path.join(arena, &.{ images_dir, std.fs.path.basename(i.file) });
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch break :blk null;
            break :blk try Block.copy(self.gpa, .{ .image = .{ .mime = i.mime, .bytes = bytes, .alt = i.alt } });
        },
        .file => |f| try Block.copy(self.gpa, .{ .file = .{ .path = f.path, .line = f.line, .end_line = f.end_line, .title = f.title } }),
        .diff => |d| try Block.copy(self.gpa, .{ .diff = .{ .path = d.path, .old = d.old, .new = d.new } }),
        .plan => |entries| blk: {
            const list = try arena.alloc(chat.PlanEntry, entries.len);
            for (entries, list) |e, *out| out.* = .{ .text = e.text, .status = e.status };
            break :blk try Block.copy(self.gpa, .{ .plan = list });
        },
        .tool, .question => null,
    };
}

/// The first version's transcripts: one flat list of entries, every chat an agent's. Read into
/// messages so the person's chats survive the redesign.
fn loadV1(self: *Transcript, arena: std.mem.Allocator, source: [:0]const u8) !Loaded {
    const Kind = enum { user, agent, thought, tool, plan, permission, note, failure };
    const Status = enum { pending, in_progress, completed, failed };
    const V1 = struct {
        title: []const u8 = "",
        entries: []const struct { kind: Kind, text: []const u8, status: Status = .pending, detail: []const u8 = "" } = &.{},
    };
    var diag: std.zon.parse.Diagnostics = undefined;
    const old = try std.zon.parse.fromSlice(V1, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diag, .ignore_unknown_fields = true });
    var current: ?chat.MessageId = null;
    for (old.entries) |e| switch (e.kind) {
        .user => current = try self.post(.person, &.{.{ .text = e.text }}),
        .note, .failure => {
            _ = try self.post(.note, &.{.{ .text = e.text }});
            current = null;
        },
        else => {
            if (current == null or self.messages.items[current.?].author != .other) current = try self.post(.other, &.{});
            const m = current.?;
            switch (e.kind) {
                .agent => try self.appendText(m, .text, e.text),
                .thought => try self.appendText(m, .thought, e.text),
                .tool => _ = try self.tool(m, .{
                    .title = e.text,
                    .status = switch (e.status) {
                        .pending => .pending,
                        .in_progress => .running,
                        .completed => .done,
                        .failed => .failed,
                    },
                    .content = if (e.detail.len > 0) &.{.{ .code = .{ .text = e.detail } }} else &.{},
                }),
                .plan => try self.append(m, .{ .text = e.text }),
                .permission => try self.append(m, .{ .text = e.text }),
                else => {},
            }
        },
    };
    return .{ .client = try self.gpa.dupe(u8, "agent"), .title = try self.gpa.dupe(u8, old.title), .folder = try self.gpa.dupe(u8, ""), .@"resume" = try self.gpa.dupe(u8, "") };
}

test "a transcript saves and loads back as it was" {
    const gpa = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    const io = io_impl.io();
    var t: Transcript = .{ .gpa = gpa };
    defer t.deinit();
    const ask_id = try t.post(.person, &.{.{ .text = "Hello?" }});
    _ = ask_id;
    const m = try t.post(.other, &.{});
    try t.appendText(m, .thought, "Think");
    try t.appendText(m, .thought, "ing.");
    try t.appendText(m, .text, "**Hi**");
    const tid = try t.tool(m, .{ .kind = .edit, .title = "Edit a.zig", .content = &.{.{ .diff = .{ .path = "a.zig", .old = "a", .new = "b" } }} });
    const q = try t.ask(m, .{ .text = "Allow?", .tool = tid, .options = &.{ .{ .id = "y", .label = "Allow", .kind = .allow }, .{ .id = "n", .label = "Deny", .kind = .deny } } });
    try std.testing.expectEqualStrings("y", t.answer(q, 0).?);
    try t.setPlan(m, &.{ .{ .text = "one", .status = .completed }, .{ .text = "two" } });
    try t.setPlan(m, &.{.{ .text = "only", .status = .in_progress }});
    try std.testing.expect(t.tools.items[tid].open);
    try std.testing.expectEqual(@as(usize, 4), t.messages.items[m].parts.items.len);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try t.save(&out.writer, .{ .client = "sample", .title = "Hello?", .folder = "/p", .@"resume" = "session-1" }, "unused-images", io);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "// Hello?\n// folder /p\n"));

    var back: Transcript = .{ .gpa = gpa };
    defer back.deinit();
    const h = try back.load(out.written(), "unused-images", io);
    defer {
        gpa.free(h.client);
        gpa.free(h.title);
        gpa.free(h.folder);
        gpa.free(h.@"resume");
    }
    try std.testing.expectEqualStrings("sample", h.client);
    try std.testing.expectEqualStrings("session-1", h.@"resume");
    try std.testing.expectEqualStrings("/p", h.folder);
    try std.testing.expectEqual(@as(usize, 2), back.messages.items.len);
    const parts = back.messages.items[1].parts.items;
    try std.testing.expectEqualStrings("Thinking.", parts[0].block.thought.items);
    try std.testing.expectEqualStrings("**Hi**", parts[1].block.text.items);
    try std.testing.expectEqual(@as(?chat.QuestionId, 0), back.tools.items[0].question);
    try std.testing.expectEqual(Question.Answer{ .chosen = 0 }, back.questions.items[0].answer);
    try std.testing.expectEqualStrings("only", parts[3].block.plan[0].text);
}

test "a first-version transcript reads as messages" {
    const gpa = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var t: Transcript = .{ .gpa = gpa };
    defer t.deinit();
    const h = try t.load(
        \\// Hi
        \\.{ .title = "Hi", .entries = .{
        \\    .{ .kind = .note, .text = "Connected." },
        \\    .{ .kind = .user, .text = "Hi" },
        \\    .{ .kind = .tool, .text = "Look", .status = .completed, .detail = "out" },
        \\    .{ .kind = .agent, .text = "Hello" },
        \\} }
    , "x", io_impl.io());
    defer {
        gpa.free(h.client);
        gpa.free(h.title);
        gpa.free(h.folder);
        gpa.free(h.@"resume");
    }
    try std.testing.expectEqualStrings("agent", h.client);
    try std.testing.expectEqual(@as(usize, 3), t.messages.items.len);
    try std.testing.expectEqual(chat.Author.other, t.messages.items[2].author);
    try std.testing.expectEqual(chat.Tool.Status.done, t.tools.items[0].status);
}
