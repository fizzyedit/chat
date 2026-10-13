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
view: View.State = .{},
/// The transcript's and the header's state when last written.
saved_version: u64 = 0,
header_dirty: bool = false,

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
        const dir = try self.imagesDir(gpa);
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

/// Where its images are kept: beside the transcript, in a folder of its name.
pub fn imagesDir(self: *const Chat, gpa: std.mem.Allocator) ![]u8 {
    const stem = if (std.mem.endsWith(u8, self.path, ".chat")) self.path[0 .. self.path.len - 5] else self.path;
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
    const dir = try self.imagesDir(self.gpa);
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
    self.view.deinit(self.gpa);
    self.transcript.deinit();
    self.input.deinit(self.gpa);
    self.title.deinit(self.gpa);
    self.gpa.free(self.resume_state);
    self.gpa.free(self.folder);
    self.gpa.free(self.client_id);
    self.gpa.free(self.path);
}

// ---- the person -----------------------------------------------------------------------------

/// What the person typed, to the chat's client: posted as theirs, then handed over. False when
/// there is nothing to send or no client to send it to (the text stays where it was typed).
pub fn send(self: *Chat, text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or !Commands.isRegistered(self.client_id)) return false;
    _ = self.transcript.post(.person, &.{.{ .text = trimmed }}) catch return false;
    // A chat is named by the first thing asked in it, unless its client names it.
    if (self.title.items.len == 0) {
        const line = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
        var buf: [64]u8 = undefined;
        const cut = if (line.len > 60) std.fmt.bufPrint(&buf, "{s}...", .{line[0..57]}) catch line[0..60] else line;
        self.setTitle(cut);
    }
    self.view.follow = true;
    Commands.callClient(self.client_id, "chat_send", chat.Send{ .chat = self.chat_id, .text = trimmed, .folder = self.folder });
    return true;
}

pub fn cancel(self: *Chat) void {
    Commands.callClient(self.client_id, "chat_cancel", chat.ChatOnly{ .chat = self.chat_id });
}

/// The person chose `option` of question `qid`.
pub fn choose(self: *Chat, qid: chat.QuestionId, option: u32) void {
    const option_id = self.transcript.answer(qid, option) orelse return;
    Commands.callClient(self.client_id, "chat_answer", chat.Answer{ .chat = self.chat_id, .question = qid, .option = option_id });
}
