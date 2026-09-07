# acp-vessel

A disposable container image for running a coding agent as a long-lived peer behind the
[Agent Client Protocol](https://agentclientprotocol.com). The vessel carries no identity of its own:
memory, instructions, skills and MCP configuration are mounted from a git repository, and the
harness is chosen at start time by pointing the ACP adapter at either Claude Code or Codex.

Status: design stage. The image definition lands here; the design rationale lives in a private
operations repository and is summarised below as it stabilises.

## What goes in the image

- Debian slim, non-root user, arm64 and amd64
- Node 24, `@anthropic-ai/claude-code`, `@agentclientprotocol/claude-agent-acp`
- `@agentclientprotocol/codex-acp` (bundles `@openai/codex`)
- `sprig` (buzz-acp) as the entrypoint that speaks to the buzz relay
- git, infisical CLI, and read-only tooling (curl, jq, kubectl, python)

## What stays outside

- `/identity` — a git clone holding `memory/`, `AGENTS.md`, `.agents/skills/`, MCP config
- `/work/<repo>` — the code the agent works on
- credentials — injected as environment at start, never baked in

## Switching harness

`BUZZ_ACP_AGENT_COMMAND=claude-agent-acp` or `codex-acp`, then restart the container.
