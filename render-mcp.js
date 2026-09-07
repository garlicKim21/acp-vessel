// Render /identity/mcp.json ({"mcpServers": {...}}, Claude Code shape) into both harness formats.
// usage: node render-mcp.js <mcp.json> <~/.claude.json> <~/.codex/config.toml>
const fs = require('fs');
const [src, claudePath, codexPath] = process.argv.slice(2);
// ${VAR} / ${VAR:-default} in url, headers, env and args are expanded from the container environment at render time,
// so the identity repo carries no host addresses or tokens — those are ports the host plugs in (VM_URL, VERIFY_AUTH_TOKEN...).
const expand = (v) => typeof v === 'string'
  ? v.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g, (_, k, d) => (process.env[k] ?? d ?? `\${${k}}`))
  : v;
const raw = JSON.parse(fs.readFileSync(src, 'utf8')).mcpServers || {};
const servers = {};
for (const [name, s] of Object.entries(raw)) {
  const o = { ...s };
  if (o.url) o.url = expand(o.url);
  if (o.command) o.command = expand(o.command);
  if (Array.isArray(o.args)) o.args = o.args.map(expand);
  if (o.headers) o.headers = Object.fromEntries(Object.entries(o.headers).map(([k, v]) => [k, expand(v)]));
  if (o.env) o.env = Object.fromEntries(Object.entries(o.env).map(([k, v]) => [k, expand(v)]));
  servers[name] = o;
}

// Claude Code: merge into ~/.claude.json
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(claudePath, 'utf8')); } catch {}
cfg.mcpServers = servers;
fs.writeFileSync(claudePath, JSON.stringify(cfg, null, 2) + '\n');

// Codex: replace a marker-delimited block in config.toml
const q = (v) => JSON.stringify(String(v));
const lines = ['# >>> acp-vessel mcp (generated from /identity/mcp.json)'];
// Vessel defaults: Codex Memories (background transcript summaries, global to CODEX_HOME) stay off.
// Memory is the git-backed /identity/memory that AGENTS.md points at; a second uncurated store would drift from it.
lines.push('[features]', 'memories = false', '');
for (const [name, s] of Object.entries(servers)) {
  lines.push(`[mcp_servers.${name}]`);
  if (s.command) lines.push(`command = ${q(s.command)}`);
  if (Array.isArray(s.args) && s.args.length) lines.push(`args = [${s.args.map(q).join(', ')}]`);
  if (s.url) lines.push(`url = ${q(s.url)}`);
  if (s.headers && Object.keys(s.headers).length) {
    // Codex: static headers table. (bearer_token_env_var would also work for Authorization, but a rendered header keeps one shape.)
    lines.push(`http_headers = { ${Object.entries(s.headers).map(([k, v]) => `${q(k)} = ${q(v)}`).join(', ')} }`);
  }
  if (s.env && Object.keys(s.env).length) {
    lines.push(`[mcp_servers.${name}.env]`);
    for (const [k, v] of Object.entries(s.env)) lines.push(`${k} = ${q(v)}`);
  }
}
lines.push('# <<< acp-vessel mcp');
const block = lines.join('\n') + '\n';
let old = '';
try { old = fs.readFileSync(codexPath, 'utf8'); } catch {}
const kept = old.replace(/# >>> acp-vessel mcp[\s\S]*?# <<< acp-vessel mcp\n/, '').replace(/\n+$/, '');
fs.writeFileSync(codexPath, (kept ? kept + '\n\n' : '') + block);
