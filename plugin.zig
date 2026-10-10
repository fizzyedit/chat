//! Talk to an AI agent in a fizzy panel (fizzyedit/plans, `plans/AGENTS_PLAN.md`, "The chat
//! plugin"). One chat for any agent: which one runs is a setting, a command line for an agent
//! that speaks the Agent Client Protocol, and everything shown is the same for all of them.
//!
//! The agent drives fizzy through the agent plugin's `fizzy-mcp`, handed to it when a session
//! opens; nothing here imports that plugin. Nothing runs until the person presses Start.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const Chat = @import("src/Chat.zig");
const Settings = @import("src/Settings.zig");

pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .beginFrame = beginFrame,
    .deinit = deinit,
};

const Schema = sdk.settings.Schema(Settings);

const State = struct {
    settings: Settings = .{},
    chat: Chat,
};

var state: State = undefined;

pub fn register(host: *sdk.Host) !void {
    state = .{ .chat = .{ .gpa = host.allocator, .host = host, .settings = &state.settings } };
    Schema.load(host, plugin_id, &state.settings);
    plugin.state = @ptrCast(&state);
    try host.registerPlugin(&plugin);
    try Schema.register(host, &plugin, .{ .title = "Chat", .value = &state.settings });
    try host.registerSurface(.{
        .id = "chat.conversation",
        .owner = &plugin,
        .icon = .{ .tvg = dvui.entypo.chat },
        .title = "Chat",
        .keywords = sdk.keywords.ide.sidebar,
        .draw = draw,
    });
}

fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
    return state.chat.draw();
}

fn beginFrame(_: *anyopaque) void {
    state.chat.frame();
}

fn deinit(_: *anyopaque) void {
    state.chat.deinit();
}
