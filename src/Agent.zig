//! The agent's process: spawned as fizzy's LSP client spawns a language server
//! (`core/lsp/Client.zig`), so the same platform rules hold. On macOS it goes through
//! `core.darwin_spawn`, never `std.process.spawn` (see that file). It is found on the login
//! shell's PATH (`core.shell_env`), since a GUI-launched fizzy does not inherit it.
//!
//! A reader thread takes lines off the agent's stdout and queues them; the UI thread takes them
//! (`take`) in the plugin's `beginFrame`, woken by `wake` (`Host.refresh`, safe from any thread).
//! Another thread keeps the tail of the agent's stderr, which says why when it dies. Nothing here
//! touches dvui. Writes (`send`) come from the UI thread only.
const Agent = @This();

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const acp = @import("acp.zig");
const Io = std.Io;

gpa: std.mem.Allocator,
io: Io,
wake: *const fn () void,
child: std.process.Child,
reader: ?std.Thread = null,
errs: ?std.Thread = null,
/// Under `lock`: lines read and not yet taken (each owned by `gpa`), whether stdout has closed,
/// and stderr's last bytes.
lock: Io.Mutex = .init,
inbox: std.ArrayListUnmanaged([]u8) = .empty,
exited: bool = false,
stderr_tail: [2048]u8 = undefined,
stderr_len: usize = 0,

pub const StartError = error{ NoCommand, SpawnFailed, OutOfMemory };

/// Spawn `argv` in `cwd` and start reading it. The caller owns the result and calls `stop`.
pub fn start(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8, wake: *const fn () void) StartError!*Agent {
    if (argv.len == 0) return error.NoCommand;
    const resolved = resolveExecutable(gpa, io, argv[0]);
    defer if (resolved) |r| gpa.free(r);
    const full = try gpa.alloc([]const u8, argv.len);
    defer gpa.free(full);
    @memcpy(full, argv);
    if (resolved) |r| full[0] = r;

    const child = spawn(gpa, io, full, cwd) catch return error.SpawnFailed;
    const self = try gpa.create(Agent);
    self.* = .{ .gpa = gpa, .io = io, .wake = wake, .child = child };
    self.reader = std.Thread.spawn(.{}, readStdout, .{self}) catch null;
    self.errs = std.Thread.spawn(.{}, readStderr, .{self}) catch null;
    if (self.reader == null) {
        self.stop();
        return error.SpawnFailed;
    }
    return self;
}

fn spawn(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    if (comptime builtin.os.tag == .macos) {
        return core.darwin_spawn.spawn(gpa, .{
            .argv = argv,
            .cwd = cwd,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }, core.shell_env.path(gpa, io));
    }
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        // Windows only: a console agent from a windowed fizzy would otherwise pop up a console.
        .create_no_window = true,
    });
}

/// Write one message (a whole line, newline included). UI thread only.
pub fn send(self: *Agent, line: []const u8) !void {
    const stdin = self.child.stdin orelse return error.Closed;
    var buf: [4096]u8 = undefined;
    // Streaming, not positional: a pipe cannot seek (see `core/lsp/Client.zig`'s `send`).
    var w = stdin.writerStreaming(self.io, &buf);
    try w.interface.writeAll(line);
    try w.interface.flush();
}

/// Move the lines read so far into `out`; true once the agent's stdout has closed.
pub fn take(self: *Agent, out: *std.ArrayListUnmanaged([]u8)) bool {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    out.appendSlice(self.gpa, self.inbox.items) catch {};
    self.inbox.clearRetainingCapacity();
    return self.exited;
}

/// The last of what the agent wrote to stderr, copied into `buf`.
pub fn stderrTail(self: *Agent, buf: []u8) []const u8 {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    const n = @min(buf.len, self.stderr_len);
    @memcpy(buf[0..n], self.stderr_tail[self.stderr_len - n .. self.stderr_len]);
    return buf[0..n];
}

/// Kill the agent, wait for the threads, and free everything.
pub fn stop(self: *Agent) void {
    self.child.kill(self.io);
    if (self.reader) |t| t.join();
    if (self.errs) |t| t.join();
    for (self.inbox.items) |l| self.gpa.free(l);
    self.inbox.deinit(self.gpa);
    self.gpa.destroy(self);
}

fn readStdout(self: *Agent) void {
    const stdout = self.child.stdout orelse return self.finish();
    const buf = self.gpa.alloc(u8, 1 << 16) catch return self.finish();
    defer self.gpa.free(buf);
    var r = stdout.readerStreaming(self.io, buf);
    var line: Io.Writer.Allocating = .init(self.gpa);
    defer line.deinit();
    while (true) {
        const got = acp.readLine(&r.interface, &line) catch |err| switch (err) {
            // A line past `acp.max_line` is dropped, not the agent.
            error.StreamTooLong => {
                _ = r.interface.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            else => break,
        } orelse break;
        if (got.len == 0) continue;
        const owned = self.gpa.dupe(u8, got) catch continue;
        self.lock.lockUncancelable(self.io);
        self.inbox.append(self.gpa, owned) catch self.gpa.free(owned);
        self.lock.unlock(self.io);
        self.wake();
    }
    self.finish();
}

fn finish(self: *Agent) void {
    self.lock.lockUncancelable(self.io);
    self.exited = true;
    self.lock.unlock(self.io);
    self.wake();
}

fn readStderr(self: *Agent) void {
    const stderr = self.child.stderr orelse return;
    // The reader's own buffer, and a separate one to read into: one buffer for both had the
    // reader copy it onto itself (`@memcpy arguments alias`) once enough arrived at once.
    var read_buf: [1024]u8 = undefined;
    var buf: [1024]u8 = undefined;
    var r = stderr.readerStreaming(self.io, &read_buf);
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch return;
        if (n == 0) return;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const keep = self.stderr_tail.len;
        if (self.stderr_len + n > keep) {
            const drop = @min(self.stderr_len, self.stderr_len + n - keep);
            std.mem.copyForwards(u8, self.stderr_tail[0 .. self.stderr_len - drop], self.stderr_tail[drop..self.stderr_len]);
            self.stderr_len -= drop;
        }
        const take_n = @min(n, keep - self.stderr_len);
        @memcpy(self.stderr_tail[self.stderr_len..][0..take_n], buf[n - take_n .. n]);
        self.stderr_len += take_n;
    }
}

/// `name` on this process's PATH, then the login shell's; null for a path or when not found
/// (the spawn then fails with the name as given). As `core/lsp/Client.zig`'s `resolveExecutable`.
fn resolveExecutable(gpa: std.mem.Allocator, io: Io, name: []const u8) ?[]u8 {
    if (comptime builtin.os.tag == .windows) return null;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
    const inherited: ?[]const u8 = if (std.c.getenv("PATH")) |p| std.mem.span(p) else null;
    if (findInPath(gpa, io, inherited, name)) |found| return found;
    return findInPath(gpa, io, core.shell_env.path(gpa, io), name);
}

fn findInPath(gpa: std.mem.Allocator, io: Io, path_value: ?[]const u8, name: []const u8) ?[]u8 {
    var it = std.mem.splitScalar(u8, path_value orelse return null, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
        Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch {
            gpa.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}
