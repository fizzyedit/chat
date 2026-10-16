//! One conversation: a document, opened in a tab like any file (plans/CHAT_PLAN.md). It belongs
//! to one client, the plugin on the other end (`Commands.zig`), named in its transcript and by the
//! folder it is kept in (`<config>/chats/<client>/`). What it holds is a `Transcript`; how it
//! looks is `View.zig`. The person's messages go to its client; the client's answers come back
//! through the chat's commands. A chat whose client is not loaded opens read-only and says so.
const Chat = @This();

const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const Transcript = @import("Transcript.zig");
const View = @import("View.zig");
const Commands = @import("Commands.zig");
const chat = @import("api.zig");

gpa: std.mem.Allocator,
host: *sdk.Host,
/// The document: fizzy's id for it, its transcript's path, and the pane it is in.
id: u64,
path: []u8,
grouping: u64 = 0,
/// The id clients name it by: stable across reloads, since it comes from where it is kept.
chat_id: chat.ChatId,
client_id: []u8,
/// The tab's name (`documentTitle`): what the client set, or the first thing asked, cut short.
title: std.ArrayListUnmanaged(u8) = .empty,
/// What the client last gave `setResume`, handed back to it when the chat is opened again.
resume_state: []u8 = &.{},
/// The project folder the chat was started in; empty for none. The list groups chats by it.
folder: []u8 = &.{},
/// The client was handed `resume_state` for this registration of it.
resumed: bool = false,
transcript: Transcript,
/// What the person is typing.
input: std.ArrayList(u8) = .empty,
/// A turn is running (`setBusy`): Stop is offered where Send was.
busy: bool = false,
/// What the client offers to set by the message box (`chat.set_settings`), in `settings_arena`.
settings: []chat.Setting = &.{},
settings_arena: ?std.heap.ArenaAllocator = null,
/// Files the person attached and has not sent yet: shown above the message box, sent with it.
attached: std.ArrayListUnmanaged(Attachment) = .empty,
/// What the person sent while a turn ran, oldest first: shown above the message box, and sent
/// together as the next message when the turn ends (`sendQueued`).
queued: std.ArrayListUnmanaged(Queued) = .empty,
view: View.State = .{},
/// The transcript's and the header's state when last written.
saved_version: u64 = 0,
header_dirty: bool = false,

/// A message waiting for the turn to end: its text and what was attached to it, owned.
pub const Queued = struct {
    text: []u8,
    attached: []Attachment,

    fn deinit(self: Queued, gpa: std.mem.Allocator) void {
        for (self.attached) |a| gpa.free(a.path);
        gpa.free(self.attached);
        gpa.free(self.text);
    }
};

pub const Attachment = struct {
    path: []u8,
    mime: []const u8,
    pub fn image(self: Attachment) bool {
        return std.mem.startsWith(u8, self.mime, "image/");
    }
};

/// The chat plugin itself, which owns every chat's `DocHandle` (set once, in `register`).
pub var owner: *sdk.Plugin = undefined;

/// A chat from its transcript on disk; a path with no file yet is a new, empty chat.
pub fn fromPath(path: []const u8) !Chat {
    const gpa = sdk.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return fromBytes(path, ""),
        else => return err,
    };
    defer gpa.free(bytes);
    return fromBytes(path, bytes);
}

pub fn fromBytes(path: []const u8, bytes: []const u8) !Chat {
    const gpa = sdk.allocator();
    var self: Chat = .{
        .gpa = gpa,
        .host = sdk.host(),
        .id = sdk.host().allocDocId(),
        .path = try gpa.dupe(u8, path),
        .chat_id = chatIdOf(path),
        .client_id = try gpa.dupe(u8, clientOfPath(path)),
        .transcript = .{ .gpa = gpa },
    };
    errdefer self.deinitFields();
    if (std.mem.trim(u8, bytes, " \t\r\n").len > 0) {
        const dir = try imagesDir(gpa, self.path);
        defer gpa.free(dir);
        if (self.transcript.load(bytes, dir, dvui.io)) |h| {
            defer gpa.free(h.client);
            defer gpa.free(h.title);
            if (h.client.len > 0) {
                gpa.free(self.client_id);
                self.client_id = try gpa.dupe(u8, h.client);
            }
            try self.title.appendSlice(gpa, h.title);
            self.resume_state = h.@"resume";
            self.folder = h.folder;
        } else |err| {
            // A transcript fizzy cannot read still opens: say so, and leave the file as it is.
            self.transcript.deinit();
            self.transcript = .{ .gpa = gpa };
            const msg = try std.fmt.allocPrint(gpa, "This conversation could not be read ({t}). Its file is unchanged.", .{err});
            defer gpa.free(msg);
            _ = try self.transcript.post(.note, &.{.{ .text = msg }});
        }
    }
    self.saved_version = self.transcript.version;
    return self;
}

/// `<config>/chats/<client>/<name>.chat` → `<client>`; a transcript anywhere else is the agent's,
/// as every chat was before chats had clients.
pub fn clientOfPath(path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(path) orelse return "agent";
    const name = std.fs.path.basename(dir);
    return if (std.mem.eql(u8, name, "chats")) "agent" else name;
}

/// The chat's id: its client folder and file name, hashed. Never zero.
pub fn chatIdOf(path: []const u8) chat.ChatId {
    var h = std.hash.XxHash3.init(0x63686174);
    h.update(clientOfPath(path));
    h.update("/");
    h.update(std.fs.path.basename(path));
    return h.final() | 1;
}

/// Where the images of the transcript at `path` are kept: beside it, in a folder of its name.
pub fn imagesDir(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const stem = if (std.mem.endsWith(u8, path, ".chat")) path[0 .. path.len - 5] else path;
    return std.fmt.allocPrint(gpa, "{s}.images", .{stem});
}

pub fn handle(self: *Chat) sdk.DocHandle {
    return .{ .ptr = self, .id = self.id, .owner = owner };
}

/// Write the transcript if it changed. Its first line names the chat, so the list reads no
/// conversation whole.
pub fn save(self: *Chat) !void {
    if (self.transcript.version == self.saved_version and !self.header_dirty) return;
    try self.write();
}

pub fn write(self: *Chat) !void {
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    const dir = try imagesDir(self.gpa, self.path);
    defer self.gpa.free(dir);
    try self.transcript.save(&out.writer, .{ .client = self.client_id, .title = self.title.items, .folder = self.folder, .@"resume" = self.resume_state }, dir, dvui.io);
    if (std.fs.path.dirname(self.path)) |d| std.Io.Dir.cwd().createDirPath(dvui.io, d) catch {};
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = self.path, .data = out.written() });
    self.saved_version = self.transcript.version;
    self.header_dirty = false;
    @import("Explorer.zig").changed();
}

/// Read the transcript again from disk, in place of what the chat holds: what
/// `restoreDocumentState` puts back, since capturing it saved it (`plugin.zig`).
pub fn reloadTranscript(self: *Chat) !void {
    var fresh = try fromPath(self.path);
    defer fresh.deinitFields();
    std.mem.swap(Transcript, &self.transcript, &fresh.transcript);
    std.mem.swap(std.ArrayListUnmanaged(u8), &self.title, &fresh.title);
    std.mem.swap([]u8, &self.resume_state, &fresh.resume_state);
    std.mem.swap([]u8, &self.folder, &fresh.folder);
    self.saved_version = self.transcript.version;
    self.view.reset(self.gpa);
}

pub fn setTitle(self: *Chat, title: []const u8) void {
    self.title.clearRetainingCapacity();
    self.title.appendSlice(self.gpa, title) catch {};
    self.header_dirty = true;
    self.host.documentTitleChanged(self.handle());
}

pub fn setResume(self: *Chat, state: []const u8) void {
    const copy = self.gpa.dupe(u8, state) catch return;
    self.gpa.free(self.resume_state);
    self.resume_state = copy;
    self.header_dirty = true;
}

pub fn deinit(self: *Chat) void {
    self.save() catch {};
    self.deinitFields();
}

fn deinitFields(self: *Chat) void {
    if (self.settings_arena) |*a| a.deinit();
    for (self.attached.items) |a| self.gpa.free(a.path);
    self.attached.deinit(self.gpa);
    for (self.queued.items) |q| q.deinit(self.gpa);
    self.queued.deinit(self.gpa);
    self.view.deinit(self.gpa);
    self.transcript.deinit();
    self.input.deinit(self.gpa);
    self.title.deinit(self.gpa);
    self.gpa.free(self.resume_state);
    self.gpa.free(self.folder);
    self.gpa.free(self.client_id);
    self.gpa.free(self.path);
}

/// The settings the client offers, copied: replacing any it offered before.
pub fn setSettings(self: *Chat, settings: []const chat.Setting) !void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const out = try a.alloc(chat.Setting, settings.len);
    for (settings, out) |s, *o| {
        const choices = try a.alloc(chat.Setting.Choice, s.choices.len);
        for (s.choices, choices) |c, *oc| oc.* = .{ .value = try a.dupe(u8, c.value), .name = try a.dupe(u8, c.name), .description = try a.dupe(u8, c.description) };
        o.* = .{ .id = try a.dupe(u8, s.id), .name = try a.dupe(u8, s.name), .current = try a.dupe(u8, s.current), .description = try a.dupe(u8, s.description), .choices = choices };
    }
    if (self.settings_arena) |*old| old.deinit();
    self.settings_arena = arena;
    self.settings = out;
}

/// The person chose `value` for setting `id`: shown at once, and told to the client, which
/// answers with what it is now.
pub fn chooseSetting(self: *Chat, id: []const u8, value: []const u8) void {
    for (self.settings) |*s| if (std.mem.eql(u8, s.id, id)) {
        for (s.choices) |c| if (std.mem.eql(u8, c.value, value)) {
            s.current = c.value;
        };
    };
    Commands.callClient(self.client_id, "chat_setting", chat.Choose{ .chat = self.chat_id, .id = id, .value = value });
}

/// A file to send with the next message.
pub fn attach(self: *Chat, path: []const u8) void {
    for (self.attached.items) |a| if (std.mem.eql(u8, a.path, path)) return;
    const owned = self.gpa.dupe(u8, path) catch return;
    self.attached.append(self.gpa, .{ .path = owned, .mime = mimeOf(path) }) catch self.gpa.free(owned);
}

pub fn detach(self: *Chat, index: usize) void {
    if (index >= self.attached.items.len) return;
    self.gpa.free(self.attached.orderedRemove(index).path);
}

fn mimeOf(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const known = [_][2][]const u8{ .{ ".png", "image/png" }, .{ ".jpg", "image/jpeg" }, .{ ".jpeg", "image/jpeg" }, .{ ".gif", "image/gif" }, .{ ".webp", "image/webp" }, .{ ".bmp", "image/bmp" } };
    for (known) |k| if (std.ascii.eqlIgnoreCase(ext, k[0])) return k[1];
    return "text/plain";
}

// ---- the person -----------------------------------------------------------------------------

/// What the person typed, to the chat's client: posted as theirs, then handed over. False when
/// there is nothing to send or no client to send it to (the text stays where it was typed).
pub fn send(self: *Chat, text: []const u8) bool {
    if (!self.sendWith(text, self.attached.items)) return false;
    for (self.attached.items) |a| self.gpa.free(a.path);
    self.attached.clearRetainingCapacity();
    return true;
}

fn sendWith(self: *Chat, text: []const u8, attached: []const Attachment) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if ((trimmed.len == 0 and attached.len == 0) or !Commands.isRegistered(self.client_id)) return false;
    // The message as the person sees it: their text, the images they attached shown, the files as
    // links. The client gets the same, by path.
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shown: std.ArrayListUnmanaged(chat.Block) = .empty;
    var sent: std.ArrayListUnmanaged(chat.Block) = .empty;
    if (trimmed.len > 0) shown.append(arena, .{ .text = trimmed }) catch return false;
    for (attached) |a| {
        if (a.image()) {
            const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, a.path, arena, .limited(32 * 1024 * 1024)) catch continue;
            shown.append(arena, .{ .image = .{ .mime = a.mime, .bytes = bytes, .alt = std.fs.path.basename(a.path) } }) catch {};
            sent.append(arena, .{ .image = .{ .path = a.path, .mime = a.mime } }) catch {};
        } else {
            shown.append(arena, .{ .file = .{ .path = a.path } }) catch {};
            sent.append(arena, .{ .file = .{ .path = a.path } }) catch {};
        }
    }
    _ = self.transcript.post(.person, shown.items) catch return false;
    // A chat is named by the first thing asked in it, unless its client names it.
    if (self.title.items.len == 0) {
        const line = if (trimmed.len > 0) trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len] else std.fs.path.basename(attached[0].path);
        var buf: [64]u8 = undefined;
        const cut = if (line.len > 60) std.fmt.bufPrint(&buf, "{s}...", .{line[0..57]}) catch line[0..60] else line;
        self.setTitle(cut);
    }
    self.view.follow = true;
    Commands.callClient(self.client_id, "chat_send", chat.Send{ .chat = self.chat_id, .text = trimmed, .folder = self.folder, .attached = sent.items });
    return true;
}

/// While a turn runs: what the person typed, and what they attached, wait for it to end. ACP
/// takes one prompt at a time (`session/prompt` answers when the turn is over), and so does every
/// client here, so the chat keeps the queue, the same for all of them. False when there is
/// nothing to queue.
pub fn queue(self: *Chat, text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 and self.attached.items.len == 0) return false;
    const owned = self.gpa.dupe(u8, trimmed) catch return false;
    const attached = self.attached.toOwnedSlice(self.gpa) catch {
        self.gpa.free(owned);
        return false;
    };
    self.queued.append(self.gpa, .{ .text = owned, .attached = attached }) catch {
        (Queued{ .text = owned, .attached = attached }).deinit(self.gpa);
        return false;
    };
    return true;
}

pub fn unqueue(self: *Chat, index: usize) void {
    if (index >= self.queued.items.len) return;
    self.queued.orderedRemove(index).deinit(self.gpa);
}

/// The turn is over: what queued goes as one message, its texts in the order they were written,
/// as a person who kept typing would have sent them. Called at the top of each frame, never from
/// inside a client's own call.
pub fn sendQueued(self: *Chat) void {
    if (self.busy or self.queued.items.len == 0) return;
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    var attached: std.ArrayListUnmanaged(Attachment) = .empty;
    for (self.queued.items) |q| {
        if (q.text.len > 0) {
            if (text.items.len > 0) text.appendSlice(arena, "\n\n") catch return;
            text.appendSlice(arena, q.text) catch return;
        }
        attached.appendSlice(arena, q.attached) catch return;
    }
    if (!self.sendWith(text.items, attached.items)) return;
    for (self.queued.items) |q| q.deinit(self.gpa);
    self.queued.clearRetainingCapacity();
}

/// Stop: the turn ends and what queued is not sent unasked. It goes back into the message box,
/// ahead of what is being typed, to send or not.
pub fn cancel(self: *Chat) void {
    self.unsendQueued();
    Commands.callClient(self.client_id, "chat_cancel", chat.ChatOnly{ .chat = self.chat_id });
}

fn unsendQueued(self: *Chat) void {
    if (self.queued.items.len == 0) return;
    var text: std.ArrayList(u8) = .empty;
    for (self.queued.items) |q| {
        if (q.text.len > 0) {
            text.appendSlice(self.gpa, q.text) catch return text.deinit(self.gpa);
            text.appendSlice(self.gpa, "\n\n") catch return text.deinit(self.gpa);
        }
    }
    text.appendSlice(self.gpa, self.input.items) catch return text.deinit(self.gpa);
    self.input.deinit(self.gpa);
    self.input = text;
    for (self.queued.items) |q| {
        for (q.attached) |a| self.attached.append(self.gpa, a) catch self.gpa.free(a.path);
        self.gpa.free(q.attached);
        self.gpa.free(q.text);
    }
    self.queued.clearRetainingCapacity();
}

/// The person chose `option` of question `qid`.
pub fn choose(self: *Chat, qid: chat.QuestionId, option: u32) void {
    const option_id = self.transcript.answer(qid, option) orelse return;
    Commands.callClient(self.client_id, "chat_answer", chat.Answer{ .chat = self.chat_id, .question = qid, .option = option_id });
}
