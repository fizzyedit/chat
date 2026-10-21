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

use_api_key: settings.Value(bool, .{
    .description = "Use an API key from fizzy's environment. Off: the agent signs in with your " ++
        "plan and no API key variable reaches it, so nothing is billed per token. On: the " ++
        "variables named below are forwarded to the agent, and only those. Not available on " ++
        "macOS yet.",
}) = .init(false),

api_key_vars: settings.Value([]const u8, .{
    .description = "The environment variables forwarded when \"Use API key from environment\" is " ++
        "on, separated by commas. Only names are stored here, never a key.",
}) = .init("ANTHROPIC_API_KEY,OPENAI_API_KEY,CODEX_API_KEY,GEMINI_API_KEY,GOOGLE_API_KEY"),
