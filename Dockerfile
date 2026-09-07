# syntax=docker/dockerfile:1.7
# acp-vessel — disposable agent container. No identity, no secrets baked in.
# Harness is chosen at runtime: BUZZ_ACP_AGENT_COMMAND=claude-agent-acp | codex-acp

ARG SPRIG_REF=main
FROM ghcr.io/block/buzz-sprig:${SPRIG_REF} AS sprig

FROM node:24-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.263
ARG CLAUDE_AGENT_ACP_VERSION=0.75.1
ARG CODEX_ACP_VERSION=1.10.0
ARG KUBECTL_VERSION=v1.37.0
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/garlicKim21/acp-vessel" \
      org.opencontainers.image.description="Disposable agent container: Claude Code or Codex behind an ACP adapter, identity mounted from git" \
      acp-vessel.claude-code="${CLAUDE_CODE_VERSION}" \
      acp-vessel.claude-agent-acp="${CLAUDE_AGENT_ACP_VERSION}" \
      acp-vessel.codex-acp="${CODEX_ACP_VERSION}" \
      acp-vessel.kubectl="${KUBECTL_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling. openssh-client is for git over ssh only; no keys are ever baked in.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq less openssh-client procps python3 tini \
 && curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | bash \
 && apt-get install -y --no-install-recommends infisical \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod 0755 /usr/local/bin/kubectl \
 && ssh-keyscan -t ed25519,rsa,ecdsa github.com > /etc/ssh/ssh_known_hosts 2>/dev/null \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Harnesses and ACP adapters, pinned. codex-acp bundles @openai/codex (platform package picked per arch).
RUN npm install -g --no-fund --no-audit \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@agentclientprotocol/claude-agent-acp@${CLAUDE_AGENT_ACP_VERSION}" \
      "@agentclientprotocol/codex-acp@${CODEX_ACP_VERSION}" \
 && ln -s /usr/local/lib/node_modules/@agentclientprotocol/codex-acp/node_modules/.bin/codex /usr/local/bin/codex \
 && npm cache clean --force

# sprig: static multicall binary (buzz-acp and helpers). Personality is chosen by argv[0].
COPY --from=sprig /usr/local/bin/sprig /usr/local/bin/sprig
RUN for n in buzz-acp buzz buzz-agent buzz-dev-mcp rg tree git-credential-nostr git-sign-nostr; do \
      ln -s sprig "/usr/local/bin/$n"; done

# Non-root user "agent" (uid 1000). Replaces the image's default "node" user so host volumes map cleanly.
RUN userdel -r node 2>/dev/null || true \
 && useradd -m -u 1000 -s /bin/bash agent \
 && mkdir -p /identity /work /home/agent/.claude /home/agent/.codex /home/agent/.ssh \
 && chown -R agent:agent /identity /work /home/agent \
 && chmod 0700 /home/agent/.ssh

COPY --chmod=0755 entrypoint.sh /usr/local/bin/vessel-entrypoint

USER agent
WORKDIR /work
ENV HOME=/home/agent \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    CODEX_HOME=/home/agent/.codex \
    DISABLE_AUTOUPDATER=1 \
    BUZZ_ACP_AGENT_COMMAND=claude-agent-acp \
    BUZZ_ACP_AGENT_ARGS= \
    BUZZ_ACP_RESPOND_TO=owner-only

VOLUME ["/identity", "/work", "/home/agent/.codex"]
ENTRYPOINT ["tini", "--", "/usr/local/bin/vessel-entrypoint"]
