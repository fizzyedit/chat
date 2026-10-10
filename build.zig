//! The chat plugin: `zig build` installs it into fizzy's plugins directory (or `FIZZY_PROFILE`'s).
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    fizzy.plugin.install(b, plugin.lib, .{});

    // The ACP framing and command-line parsing are std-only: tested without a window.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/acp.zig"),
    }) });
    b.step("test", "Run the chat's tests").dependOn(&b.addRunArtifact(tests).step);
}
