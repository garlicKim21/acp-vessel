# syntax=docker/dockerfile:1.7
# acp-vessel — the stateless core of a disposable agent container:
#   AI harness (Claude Code | Codex) + ACP adapter + buzz-acp. Nothing else.
# Tools (kubectl, host diagnostics, secrets) live in sidecars on the agent's network, not here.

ARG SPRIG_REF=main
FROM ghcr.io/block/buzz-sprig:${SPRIG_REF} AS sprig

FROM node:24-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.263
ARG CLAUDE_AGENT_ACP_VERSION=0.75.1
ARG CODEX_ACP_VERSION=1.10.0

LABEL org.opencontainers.image.source="https://github.com/garlicKim21/acp-vessel" \
      org.opencontainers.image.description="Stateless agent core: Claude Code or Codex behind an ACP adapter, identity mounted from git" \
      acp-vessel.claude-code="${CLAUDE_CODE_VERSION}" \
      acp-vessel.claude-agent-acp="${CLAUDE_AGENT_ACP_VERSION}" \
      acp-vessel.codex-acp="${CODEX_ACP_VERSION}"

# git over HTTPS only (token from env). No ssh. curl is included (2026-09-08): it adds no capability node/python
# lack, and it lets the body run the same hand-check commands the host docs use. Interpreters: node (harness) and python3 (the agent's
# tool-making runtime — verify scripts and the like live in git, see README "tools"). Libraries are not baked in:
# the identity repo declares them (.agents/requirements.txt) and the entrypoint installs into a cache volume.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git tini curl python3 python3-pip python3-venv \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Harnesses and ACP adapters, pinned. codex-acp bundles @openai/codex, whose binary is a per-platform optional
# dependency (@openai/codex-linux-{x64,arm64}). Under buildx QEMU emulation npm dropped the arm64 one (2026-09-08,
# sha-c4ddd8c: amd64 had it, arm64 did not, `codex` threw "Missing optional dependency"), so pin the platform from
# buildx's TARGETARCH instead of trusting the emulated process.arch, and fail the build if the binary does not run.
ARG TARGETARCH
RUN case "${TARGETARCH}" in amd64) NPM_CPU=x64 ;; arm64) NPM_CPU=arm64 ;; *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; esac \
 && npm install -g --no-fund --no-audit --os=linux --cpu="${NPM_CPU}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@agentclientprotocol/claude-agent-acp@${CLAUDE_AGENT_ACP_VERSION}" \
      "@agentclientprotocol/codex-acp@${CODEX_ACP_VERSION}" \
 && ln -s /usr/local/lib/node_modules/@agentclientprotocol/codex-acp/node_modules/.bin/codex /usr/local/bin/codex \
 && npm cache clean --force \
 && codex --version \
 && claude --version

# sprig: static multicall binary (buzz-acp and helpers). Personality is chosen by argv[0].
COPY --from=sprig /usr/local/bin/sprig /usr/local/bin/sprig
RUN for n in buzz-acp buzz buzz-agent buzz-dev-mcp rg tree git-credential-nostr git-sign-nostr; do \
      ln -s sprig "/usr/local/bin/$n"; done

# Non-root user "agent" (uid 1000). Replaces the image's default "node" user so host volumes map cleanly.
RUN userdel -r node 2>/dev/null || true \
 && useradd -m -u 1000 -s /bin/bash agent \
 && mkdir -p /identity /work /home/agent/.claude /home/agent/.codex /home/agent/.local \
 && chown -R agent:agent /identity /work /home/agent

COPY --chmod=0755 entrypoint.sh /usr/local/bin/vessel-entrypoint
COPY --chmod=0755 render-mcp.js /usr/local/lib/vessel/render-mcp.js

USER agent
WORKDIR /work
ENV HOME=/home/agent \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    CODEX_HOME=/home/agent/.codex \
    DISABLE_AUTOUPDATER=1 \
    PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    BUZZ_ACP_AGENT_COMMAND=claude-agent-acp \
    BUZZ_ACP_AGENT_ARGS= \
    BUZZ_ACP_RESPOND_TO=owner-only

VOLUME ["/identity", "/work", "/home/agent/.codex", "/home/agent/.local"]
ENTRYPOINT ["tini", "--", "/usr/local/bin/vessel-entrypoint"]
