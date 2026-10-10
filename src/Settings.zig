//! The chat's settings. Read a value with `.get()`.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

agent_command: settings.Value([]const u8, .{
    .description = "The agent to talk to, as a command line: any agent that speaks the Agent " ++
        "Client Protocol on its stdin and stdout. For example " ++
        "`npx -y @agentclientprotocol/claude-agent-acp`. The README lists more.",
}) = .init(""),

mcp_command: settings.Value([]const u8, .{
    .description = "fizzy-mcp, which hands the agent fizzy's tools. Empty: the one the agent " ++
        "plugin installs beside itself.",
}) = .init(""),
