# chat

Talk to an AI agent in a fizzy panel, and watch it work in fizzy.

One chat for any agent that speaks the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP): which agent runs is a setting, a command line, and the conversation looks the same for all
of them. The agent gets fizzy's own tools (the screen as text, input, commands, the profiler)
through the [agent plugin](https://github.com/fizzyedit/agent)'s `fizzy-mcp`, handed to it when a
session opens, so the agent you talk to is the one driving fizzy.

## Use it

```sh
zig build      # installs into fizzy's plugins directory (or FIZZY_PROFILE's)
```

Enable **Chat** (and **Agent**, for fizzy's tools) in fizzy's plugin settings, set
**Settings > Chat > Agent command**, open **Chats** from the sidebar, press **New Chat**, and
press Start in the chat's tab.

Each conversation is a document: a `.chat` transcript in `<fizzy config>/chats/`, opened in a
tab (several side by side, each with its own agent), saved as each turn ends, and listed in the
Chats sidebar newest first. A tab is named by the first thing asked in it.

Agent commands, as their projects publish them (check each for the current form):

| Agent | Command |
|---|---|
| Claude | `npx -y @agentclientprotocol/claude-agent-acp` |
| Codex | `npx -y @zed-industries/codex-acp` (reads `OPENAI_API_KEY` / `CODEX_API_KEY`) |
| Gemini CLI, GitHub Copilot, Goose, OpenCode, … | each agent's own ACP mode; see agentclientprotocol.com's list |

An agent that signs in through its own CLI works as it is. One that wants an API key in its
environment needs fizzy to pass it on, which comes later (the agents plan names the seam).

## What it does so far

- Starts the agent, opens a session in the project folder, and hands it `fizzy-mcp`.
- Streams the agent's messages and thoughts, its plan, and its tool calls as they run.
- Asks you before the agent acts when it requests permission, with the agent's own options.
- Reads files as fizzy's editor has them, unsaved edits included, and writes an open file as one
  undoable edit in the editor, so you watch it land and can undo it; a file that is not open is
  written to disk and shown in a preview tab. (The text plugin's `text.read` / `text.write`.)
- Shows each tool call's diff or output beneath it.
- Stops a turn (Stop), or the agent (Restart).

Next: terminals through the terminal plugin, several agents to pick from per chat, and resuming
the agent's own session when a chat is reopened.

## How it fits together

- `src/acp.zig`: the wire. JSON-RPC 2.0, one message per line on the agent's stdio. std-only,
  tested with `zig build test`.
- `src/Agent.zig`: the agent's process, spawned as fizzy spawns a language server (on macOS
  through `core.darwin_spawn`, found on the login shell's PATH), with a reader thread queueing
  lines for the UI thread.
- `src/Chat.zig`: a conversation, as a document: the ACP state machine on the UI thread, its
  transcript, and its tab's view.
- `src/Explorer.zig`: the Chats sidebar, listing transcripts without reading them whole (a
  transcript's first line is its title).
