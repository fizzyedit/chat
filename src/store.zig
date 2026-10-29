//! Writing a conversation down. A client that holds its own history (`api.History.client`) has
//! nothing written for it: no transcript, no images, no folder: the chat is only the window it
//! has loaded. std-only, so it is tested without a window.
const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const Transcript = @import("Transcript.zig");

/// Where the images of the transcript at `path` are kept: beside it, in a folder of its name.
pub fn imagesDir(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const stem = if (std.mem.endsWith(u8, path, ".chat")) path[0 .. path.len - 5] else path;
    return std.fmt.allocPrint(gpa, "{s}.images", .{stem});
}

/// Write `transcript` to `path` and its images beside it, unless the client keeps the history.
pub fn write(gpa: std.mem.Allocator, io: std.Io, history: api.History, path: []const u8, transcript: *const Transcript, header: Transcript.Header) !void {
    // The web has no disk either: whoever holds the history there is the client.
    if (builtin.os.tag == .freestanding or history == .client) return;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const images = try imagesDir(gpa, path);
    defer gpa.free(images);
    try transcript.save(&out.writer, header, images, io);
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

test "a chat is written where it is kept, and nowhere for a client that keeps its own history" {
    const gpa = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    const io = io_impl.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var t: Transcript = .{ .gpa = gpa };
    defer t.deinit();
    _ = try t.post(.person, &.{.{ .text = "Hello?" }});
    _ = try t.post(.other, &.{.{ .image = .{ .mime = "image/png", .bytes = "not really a png" } }});
    const header: Transcript.Header = .{ .client = "sample", .title = "Hello?", .@"resume" = "" };

    const kept = try std.fs.path.join(gpa, &.{ root, "chats", "sample", "a.chat" });
    defer gpa.free(kept);
    const held = try std.fs.path.join(gpa, &.{ root, "chats", "held", "a.chat" });
    defer gpa.free(held);

    try write(gpa, io, .client, held, &t, header);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "chats/held", .{}));

    try write(gpa, io, .chat, kept, &t, header);
    try tmp.dir.access(io, "chats/sample/a.chat", .{});
    try tmp.dir.access(io, "chats/sample/a.images", .{});
}
