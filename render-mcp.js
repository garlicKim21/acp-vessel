// Render /identity/mcp.json ({"mcpServers": {...}}, Claude Code shape) into both harness formats.
// usage: node render-mcp.js <mcp.json> <~/.claude.json> <~/.codex/config.toml>
const fs = require('fs');
const [src, claudePath, codexPath] = process.argv.slice(2);
const servers = JSON.parse(fs.readFileSync(src, 'utf8')).mcpServers || {};

// Claude Code: merge into ~/.claude.json
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(claudePath, 'utf8')); } catch {}
cfg.mcpServers = servers;
fs.writeFileSync(claudePath, JSON.stringify(cfg, null, 2) + '\n');

// Codex: replace a marker-delimited block in config.toml
const q = (v) => JSON.stringify(String(v));
const lines = ['# >>> acp-vessel mcp (generated from /identity/mcp.json)'];
for (const [name, s] of Object.entries(servers)) {
  lines.push(`[mcp_servers.${name}]`);
  if (s.command) lines.push(`command = ${q(s.command)}`);
  if (Array.isArray(s.args) && s.args.length) lines.push(`args = [${s.args.map(q).join(', ')}]`);
  if (s.url) lines.push(`url = ${q(s.url)}`);
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
