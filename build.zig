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
    // The transcript and the contract's ZON: std-only too.
    const transcript_tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/Transcript.zig"),
    }) });
    const test_step = b.step("test", "Run the chat's tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(transcript_tests).step);
}
