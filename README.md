# acp-vessel

The stateless core of a disposable agent container: an AI harness (Claude Code or Codex), the
[Agent Client Protocol](https://agentclientprotocol.com) adapter for it, and the buzz relay bridge.
Nothing else. The vessel carries no identity and no tools: memory, instructions, skills and MCP
configuration come from a git repository mounted at `/identity`; tools that need credentials
(Kubernetes, host diagnostics, secrets) run as sidecars on the agent's network and are reached over MCP.

Built for [buzz](https://github.com/block/buzz): the entrypoint is `buzz-acp` (from the `sprig`
multicall binary), which bridges relay events to the ACP agent.

## Image

`ghcr.io/garlickim21/acp-vessel` — `linux/arm64` and `linux/amd64`. Tags: `latest` (main), `sha-<commit>`, `v*`.

| Layer | Contents | Pinned by |
|---|---|---|
| base | `node:24-bookworm-slim`, non-root user `agent` (uid 1000), `tini` | Dockerfile |
| harness | `@anthropic-ai/claude-code`, `@agentclientprotocol/claude-agent-acp`, `@agentclientprotocol/codex-acp` (bundles `@openai/codex`; `codex` is on PATH) | build args |
| relay | `sprig` from `ghcr.io/block/buzz-sprig` with `buzz-acp` and helper links | `SPRIG_REF` build arg |
| plumbing | git (HTTPS only), `tini` | Dockerfile |

The image contains no credentials, no identity and no operational tooling. It is safe to publish and to rebuild at any time.
What is deliberately not in the image, and where it goes instead:

| Not here | Instead |
|---|---|
| kubectl, cloud CLIs | a sidecar MCP server on the agent's network that holds the kubeconfig; the vessel never sees it |
| secrets client (Infisical etc.) | the host renders the env file and hands plain environment to the container |
| ssh | git over HTTPS with a scoped token; host diagnostics via a sidecar, not a shell |
| python, curl, jq | not needed by the entrypoint; the harness brings its own tools |

## Layout at runtime

```
/identity            git clone of the identity repo (private): memory/  AGENTS.md  .agents/skills/  mcp.json
/identity/common     git clone of the shared user layer (private, optional): USER.md  memory/ — gitignored by the identity repo
/work/<repo>         git clone(s) of the code the agent works on; the first one is the cwd
/home/agent/.codex   volume: Codex auth.json and config.toml (re-creatable)
```

The entrypoint, in order:

1. Store the git token (`VESSEL_GIT_TOKEN`) for HTTPS access, 0600 inside the container.
2. Clone or fast-forward `/identity` and each `/work/<repo>`.
3. Wire identity into both harnesses:
   memory — `autoMemoryDirectory: /identity/memory` in `~/.claude/settings.json` (plus the cwd-slug symlink as a fallback); Codex is told by AGENTS.md to read and write the same files, and its own Memories feature is rendered off,
   instructions — `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` are one rendered file: `/identity/common/USER.md` (if present) followed by `/identity/AGENTS.md` (Codex has no import syntax),
   skills — `~/.agents/skills → /identity/.agents/skills` (Codex) and one link per skill under `~/.claude/skills/` (Claude Code); repo-level skills live in each work repo's `.agents/skills/` with `.claude/skills/<name>` symlinks committed alongside,
   MCP — `/identity/mcp.json` rendered into `~/.claude.json` and `~/.codex/config.toml`.
4. Run `buzz-acp` from the work directory, with a memory autosave backstop: if `/identity` or `/identity/common` is dirty it is committed and pushed every `VESSEL_AUTOSAVE_INTERVAL` seconds (default 600) and on SIGTERM. The agent is still expected to commit its own memory at session wrap-up; this only prevents loss on recycle. Any arguments given to the container replace this
   (e.g. `codex login --device-auth`, or `bash` for inspection).

## Environment

See [`vessel.env.example`](vessel.env.example). The important ones:

| Variable | Meaning |
|---|---|
| `BUZZ_RELAY_URL`, `BUZZ_PRIVATE_KEY`, `BUZZ_ACP_AGENT_OWNER` | The agent's identity on the relay |
| `BUZZ_ACP_AGENT_COMMAND` | `claude-agent-acp` (default) or `codex-acp`. Restart to switch |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude subscription token from `claude setup-token` (one year) |
| `VESSEL_IDENTITY_REPO`, `VESSEL_COMMON_REPO`, `VESSEL_WORK_REPOS`, `VESSEL_WORK_DIR` | What to clone and where to run (`VESSEL_COMMON_REPO` optional) |
| `VESSEL_GIT_NAME`, `VESSEL_GIT_EMAIL` | Commit author for pushes made by the agent |
| `VESSEL_GIT_TOKEN`, `VESSEL_GIT_HOST` | Fine-grained token scoped to the identity and work repos |
| `VESSEL_DRY_RUN=1` | Do everything except starting the harness; print the links |

Codex uses the ChatGPT subscription through `codex login --device-auth`, run once inside the
container; the resulting `auth.json` lives in the `.codex` volume.

## Running

```sh
docker run -d --name hub-agent \
  --env-file hub.env \
  -v hub-identity:/identity -v hub-work:/work -v hub-codex:/home/agent/.codex \
  --network vessel --memory 2g \
  ghcr.io/garlickim21/acp-vessel:latest
```

Do not mount the docker socket, ssh keys, kubeconfigs or cloud credentials into the vessel. It runs the
harness with permissions bypassed (headless), so anything mounted is reachable by the agent. Give those
to a sidecar and expose it over MCP (`/identity/mcp.json`) instead, one sidecar instance per agent network.

## Building locally

```sh
docker build -t acp-vessel:dev .
docker run --rm -e VESSEL_DRY_RUN=1 -v ./identity:/identity -v ./work:/work acp-vessel:dev
```

Versions are build args (`CLAUDE_CODE_VERSION`, `CLAUDE_AGENT_ACP_VERSION`, `CODEX_ACP_VERSION`,
`SPRIG_REF`) and are recorded as image labels.
