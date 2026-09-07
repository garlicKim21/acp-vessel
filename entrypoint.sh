#!/usr/bin/env bash
# acp-vessel entrypoint. Order:
#   1. git      — HTTPS token from env (VESSEL_GIT_TOKEN), identity + work repos clone or ff-pull
#   2. identity — both harnesses read the same memory, instructions (common user layer + identity), skills, MCP config
#   3. run      — buzz-acp from the work directory (or any command given as arguments), with memory autosave backstop
# Secrets arrive as plain environment: the host injects them (compose env_file, Infisical on the host). Nothing here talks to a vault.
set -euo pipefail

log() { printf '[vessel] %s\n' "$*" >&2; }

# ---- 1. git -----------------------------------------------------------------
# Token-based HTTPS auth for every repo on VESSEL_GIT_HOST (default github.com). Stored 0600 inside the container only.
if [[ -n "${VESSEL_GIT_TOKEN:-}" ]]; then
  umask 077
  printf 'https://%s:%s@%s\n' "${VESSEL_GIT_USER:-x-access-token}" "$VESSEL_GIT_TOKEN" "${VESSEL_GIT_HOST:-github.com}" > "$HOME/.git-credentials"
  umask 022
  git config --global credential.helper store
fi
[[ -n "${VESSEL_GIT_NAME:-}"  ]] && git config --global user.name  "$VESSEL_GIT_NAME"
[[ -n "${VESSEL_GIT_EMAIL:-}" ]] && git config --global user.email "$VESSEL_GIT_EMAIL"
git config --global --add safe.directory '*'

sync_repo() {  # sync_repo <url> <dir>
  local url="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then
    if git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      git -C "$dir" pull -q --ff-only || log "warn: ff-pull failed in $dir (keeping local state)"
    fi
  elif [[ -n "$url" ]]; then
    git clone -q "$url" "$dir"
  else
    log "warn: $dir is empty and no url given"
  fi
}

# Identity repo → /identity. Common user layer (shared by every agent) → /identity/common, which the identity
# repo gitignores so it is a separate clone, not untracked content. Work repos → /work/<name>; first one is the cwd.
sync_repo "${VESSEL_IDENTITY_REPO:-}" /identity
[[ -n "${VESSEL_COMMON_REPO:-}" ]] && sync_repo "$VESSEL_COMMON_REPO" /identity/common
WORK_DIR="${VESSEL_WORK_DIR:-}"
for url in ${VESSEL_WORK_REPOS:-}; do
  name="$(basename "${url%.git}")"
  sync_repo "$url" "/work/$name"
  [[ -z "$WORK_DIR" ]] && WORK_DIR="/work/$name"
done
WORK_DIR="${WORK_DIR:-/work}"

# ---- 2. identity ------------------------------------------------------------
# Memory: git-backed in /identity/memory, shared by both harnesses. Claude Code is pointed there with the
# `autoMemoryDirectory` setting (user scope); the cwd-slug symlink is kept as a belt-and-braces fallback for
# older harness versions. Codex has no per-fact memory: AGENTS.md tells it to read MEMORY.md and write the same files.
# Codex's own "Memories" (background transcript summaries, global, in ~/.codex) stays off — it is not curated and not git.
mkdir -p /identity/memory
node -e '
const fs=require("fs"),p=process.argv[1];let c={};try{c=JSON.parse(fs.readFileSync(p,"utf8"))}catch{}
c.autoMemoryDirectory="/identity/memory";fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n")' "$CLAUDE_CONFIG_DIR/settings.json"
slug="${WORK_DIR//\//-}"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug"
ln -sfn /identity/memory "$CLAUDE_CONFIG_DIR/projects/$slug/memory"

# Instructions: one rendered file = common user layer (USER.md, if present) + identity AGENTS.md. Codex has no
# import syntax, so both harnesses get the concatenation: ~/.claude/CLAUDE.md and $CODEX_HOME/AGENTS.md.
if [[ -f /identity/AGENTS.md ]]; then
  {
    if [[ -f /identity/common/USER.md ]]; then cat /identity/common/USER.md; printf '\n\n'; fi
    cat /identity/AGENTS.md
  } > "$CODEX_HOME/AGENTS.md"
  cp "$CODEX_HOME/AGENTS.md" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
fi

# Skills: canonical in /identity/.agents/skills (Codex scans ~/.agents/skills). Claude Code only scans ~/.claude/skills.
if [[ -d /identity/.agents/skills ]]; then
  mkdir -p "$HOME/.agents" "$CLAUDE_CONFIG_DIR/skills"
  ln -sfn /identity/.agents/skills "$HOME/.agents/skills"
  for d in /identity/.agents/skills/*/; do
    [[ -f "$d/SKILL.md" ]] && ln -sfn "${d%/}" "$CLAUDE_CONFIG_DIR/skills/$(basename "$d")"
  done
fi

# MCP: one source (/identity/mcp.json, {"mcpServers": {...}} in Claude Code shape) → both harness formats.
if [[ -f /identity/mcp.json ]]; then
  node /usr/local/lib/vessel/render-mcp.js /identity/mcp.json "$HOME/.claude.json" "$CODEX_HOME/config.toml"
fi

# ---- 3. run -----------------------------------------------------------------
cd "$WORK_DIR"
log "harness=${BUZZ_ACP_AGENT_COMMAND} cwd=${WORK_DIR} identity=$(git -C /identity rev-parse --short HEAD 2>/dev/null || echo none)"
if [[ "${VESSEL_DRY_RUN:-0}" == "1" ]]; then
  log "dry run — links:"; find "$CLAUDE_CONFIG_DIR" "$HOME/.agents" "$CODEX_HOME" -maxdepth 3 -type l -printf '  %p -> %l\n' 2>/dev/null; exit 0
fi
if [[ $# -gt 0 ]]; then exec "$@"; fi
: "${BUZZ_PRIVATE_KEY:?BUZZ_PRIVATE_KEY required}"
export BUZZ_ACP_SESSION_TITLE="${BUZZ_ACP_SESSION_TITLE:-$(basename "$WORK_DIR")}"

# Memory autosave backstop. The agent is responsible for committing its identity repo at session wrap-up;
# this only prevents loss when the container is recycled without one. Never rewrites history, never forces.
autosave_repo() {  # autosave_repo <dir>
  local dir="$1"
  [[ -d "$dir/.git" ]] || return 0
  if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
    git -C "$dir" add -A \
      && git -C "$dir" -c user.name="${VESSEL_GIT_NAME:-vessel}" -c user.email="${VESSEL_GIT_EMAIL:-vessel@localhost}" \
             commit -q -m "memory autosave $(date -u +%FT%TZ)" \
      && { git -C "$dir" push -q 2>/dev/null || log "warn: autosave push failed in $dir (kept locally)"; } \
      && log "autosave: $dir committed"
  fi
}
autosave() { autosave_repo /identity/common; autosave_repo /identity; }
buzz-acp & child=$!
( while sleep "${VESSEL_AUTOSAVE_INTERVAL:-600}"; do autosave; done ) & saver=$!
trap 'log "signal: saving identity, stopping harness"; autosave; kill -TERM "$child" 2>/dev/null' TERM INT
wait "$child"; rc=$?
kill "$saver" 2>/dev/null; autosave
exit "$rc"
