# acp-vessel

A disposable container image for running a coding agent as a long-lived peer behind the
[Agent Client Protocol](https://agentclientprotocol.com). The vessel carries no identity of its own:
memory, instructions, skills and MCP configuration are mounted from a git repository, and the
harness is chosen at start time by pointing the ACP adapter at either Claude Code or Codex.

Built for [buzz](https://github.com/block/buzz): the entrypoint is `buzz-acp` (from the `sprig`
multicall binary), which bridges relay events to the ACP agent.

## Image

`ghcr.io/garlickim21/acp-vessel` — `linux/arm64` and `linux/amd64`. Tags: `latest` (main), `sha-<commit>`, `v*`.

| Layer | Contents | Pinned by |
|---|---|---|
| base | `node:24-bookworm-slim`, non-root user `agent` (uid 1000), `tini` | Dockerfile |
| harness | `@anthropic-ai/claude-code`, `@agentclientprotocol/claude-agent-acp`, `@agentclientprotocol/codex-acp` (bundles `@openai/codex`; `codex` is on PATH) | build args |
| relay | `sprig` from `ghcr.io/block/buzz-sprig` with `buzz-acp` and helper links | `SPRIG_REF` build arg |
| tools | git, openssh-client (no keys baked in), curl, jq, python3, kubectl, infisical CLI | Dockerfile |

The image contains no credentials and no identity. It is safe to publish and to rebuild at any time.

## Layout at runtime

```
/identity            git clone of the identity repo (private): memory/  AGENTS.md  .agents/skills/  mcp.json
/work/<repo>         git clone(s) of the code the agent works on; the first one is the cwd
/home/agent/.codex   volume: Codex auth.json and config.toml (re-creatable)
/run/secrets/git_deploy_key   read-only mount, used only for git over ssh
```

The entrypoint, in order:

1. If `INFISICAL_TOKEN` is set, re-exec once under `infisical run` so secrets arrive as environment at
   start. There is no runtime dependency on the secrets service after that.
2. Clone or fast-forward `/identity` and each `/work/<repo>`.
3. Wire identity into both harnesses with symlinks:
   `~/.claude/projects/<cwd-slug>/memory → /identity/memory` (Claude Code auto-memory is path-keyed),
   `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md → /identity/AGENTS.md`,
   `~/.agents/skills → /identity/.agents/skills` (Codex) and one link per skill under `~/.claude/skills/` (Claude Code),
   and `/identity/mcp.json` rendered into `~/.claude.json` and `~/.codex/config.toml`.
4. `exec buzz-acp` from the work directory. Any arguments given to the container replace this
   (e.g. `codex login --device-auth`, or `bash` for inspection).

## Environment

See [`vessel.env.example`](vessel.env.example). The important ones:

| Variable | Meaning |
|---|---|
| `BUZZ_RELAY_URL`, `BUZZ_PRIVATE_KEY`, `BUZZ_ACP_AGENT_OWNER` | The agent's identity on the relay |
| `BUZZ_ACP_AGENT_COMMAND` | `claude-agent-acp` (default) or `codex-acp`. Restart to switch |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude subscription token from `claude setup-token` (one year) |
| `VESSEL_IDENTITY_REPO`, `VESSEL_WORK_REPOS`, `VESSEL_WORK_DIR` | What to clone and where to run |
| `VESSEL_GIT_NAME`, `VESSEL_GIT_EMAIL` | Commit author for pushes made by the agent |
| `INFISICAL_TOKEN`, `INFISICAL_PROJECT_ID`, `INFISICAL_ENV` | Optional secret injection at start |
| `VESSEL_DRY_RUN=1` | Do everything except starting the harness; print the links |

Codex uses the ChatGPT subscription through `codex login --device-auth`, run once inside the
container; the resulting `auth.json` lives in the `.codex` volume.

## Running

```sh
docker run -d --name hub-agent \
  --env-file hub.env \
  -v hub-identity:/identity -v hub-work:/work -v hub-codex:/home/agent/.codex \
  -v /srv/hub-agent/deploy_key:/run/secrets/git_deploy_key:ro \
  --network vessel --memory 2g \
  ghcr.io/garlickim21/acp-vessel:latest
```

Do not mount the docker socket, `~/.ssh`, or cloud credentials into the vessel. It runs the harness
with permissions bypassed (headless), so anything mounted is reachable by the agent.

## Building locally

```sh
docker build -t acp-vessel:dev .
docker run --rm -e VESSEL_DRY_RUN=1 -v ./identity:/identity -v ./work:/work acp-vessel:dev
```

Versions are build args (`CLAUDE_CODE_VERSION`, `CLAUDE_AGENT_ACP_VERSION`, `CODEX_ACP_VERSION`,
`KUBECTL_VERSION`, `SPRIG_REF`) and are recorded as image labels.
