#!/usr/bin/env bash
# acp-vessel entrypoint. Order:
#   1. secrets  — if INFISICAL_TOKEN is set, re-exec once under `infisical run` (env injected at start, no runtime dependency)
#   2. git      — deploy key from /run/secrets/git_deploy_key (read-only mount), identity + work repos clone or ff-pull
#   3. identity — symlinks so both harnesses read the same memory, instructions, skills, MCP config
#   4. run      — exec buzz-acp from the work directory (or any command given as arguments)
set -euo pipefail

log() { printf '[vessel] %s\n' "$*" >&2; }

# ---- 1. secrets -------------------------------------------------------------
if [[ -n "${INFISICAL_TOKEN:-}" && -z "${VESSEL_SECRETS_LOADED:-}" ]]; then
  export VESSEL_SECRETS_LOADED=1
  : "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID required with INFISICAL_TOKEN}"
  log "injecting secrets from Infisical (project ${INFISICAL_PROJECT_ID}, env ${INFISICAL_ENV:-prod})"
  exec infisical run ${INFISICAL_API_URL:+--domain "$INFISICAL_API_URL"} \
       --projectId "$INFISICAL_PROJECT_ID" --env "${INFISICAL_ENV:-prod}" -- "$0" "$@"
fi

# ---- 2. git -----------------------------------------------------------------
if [[ -r /run/secrets/git_deploy_key ]]; then
  install -m 0600 /run/secrets/git_deploy_key "$HOME/.ssh/id_deploy"
  export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_deploy -o IdentitiesOnly=yes"
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

# Identity repo → /identity. Work repos → /work/<name>. First work repo is the default cwd.
sync_repo "${VESSEL_IDENTITY_REPO:-}" /identity
WORK_DIR="${VESSEL_WORK_DIR:-}"
for url in ${VESSEL_WORK_REPOS:-}; do
  name="$(basename "${url%.git}")"
  sync_repo "$url" "/work/$name"
  [[ -z "$WORK_DIR" ]] && WORK_DIR="/work/$name"
done
WORK_DIR="${WORK_DIR:-/work}"

# ---- 3. identity ------------------------------------------------------------
# Claude Code keeps auto-memory under ~/.claude/projects/<slug>/memory where slug = cwd with '/' → '-'.
# Link it to the identity repo so memory is git-backed and shared with Codex (which is told to read it via AGENTS.md).
mkdir -p /identity/memory
slug="${WORK_DIR//\//-}"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug"
ln -sfn /identity/memory "$CLAUDE_CONFIG_DIR/projects/$slug/memory"

# Instructions: AGENTS.md is canonical. Claude reads ~/.claude/CLAUDE.md, Codex reads $CODEX_HOME/AGENTS.md.
if [[ -f /identity/AGENTS.md ]]; then
  ln -sfn /identity/AGENTS.md "$CLAUDE_CONFIG_DIR/CLAUDE.md"
  ln -sfn /identity/AGENTS.md "$CODEX_HOME/AGENTS.md"
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
  python3 - "$HOME/.claude.json" "$CODEX_HOME/config.toml" <<'PY'
import json, sys, os, re
claude_path, codex_path = sys.argv[1], sys.argv[2]
servers = json.load(open('/identity/mcp.json')).get('mcpServers', {})
# Claude Code: merge into ~/.claude.json
cfg = {}
if os.path.exists(claude_path):
    try: cfg = json.load(open(claude_path))
    except Exception: cfg = {}
cfg['mcpServers'] = servers
json.dump(cfg, open(claude_path, 'w'), indent=2)
# Codex: replace a marker-delimited block in config.toml
def toml_str(v): return json.dumps(v)
lines = ['# >>> acp-vessel mcp (generated from /identity/mcp.json)']
for name, s in servers.items():
    lines.append(f'[mcp_servers.{name}]')
    if 'command' in s: lines.append(f'command = {toml_str(s["command"])}')
    if s.get('args'): lines.append('args = [' + ', '.join(toml_str(a) for a in s['args']) + ']')
    if s.get('url'): lines.append(f'url = {toml_str(s["url"])}')
    if s.get('env'):
        lines.append(f'[mcp_servers.{name}.env]')
        for k, v in s['env'].items(): lines.append(f'{k} = {toml_str(v)}')
lines.append('# <<< acp-vessel mcp')
block = '\n'.join(lines) + '\n'
old = open(codex_path).read() if os.path.exists(codex_path) else ''
new = re.sub(r'# >>> acp-vessel mcp.*?# <<< acp-vessel mcp\n', '', old, flags=re.S).rstrip('\n')
open(codex_path, 'w').write((new + '\n\n' if new else '') + block)
PY
fi

# ---- 4. run -----------------------------------------------------------------
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
autosave() {
  [[ -d /identity/.git ]] || return 0
  if [[ -n "$(git -C /identity status --porcelain 2>/dev/null)" ]]; then
    git -C /identity add -A \
      && git -C /identity -c user.name="${VESSEL_GIT_NAME:-vessel}" -c user.email="${VESSEL_GIT_EMAIL:-vessel@localhost}" \
             commit -q -m "memory autosave $(date -u +%FT%TZ)" \
      && { git -C /identity push -q 2>/dev/null || log "warn: autosave push failed (kept locally)"; } \
      && log "autosave: identity committed"
  fi
}
buzz-acp & child=$!
( while sleep "${VESSEL_AUTOSAVE_INTERVAL:-600}"; do autosave; done ) & saver=$!
trap 'log "signal: saving identity, stopping harness"; autosave; kill -TERM "$child" 2>/dev/null' TERM INT
wait "$child"; rc=$?
kill "$saver" 2>/dev/null; autosave
exit "$rc"
