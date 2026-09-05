// V5 probe: record every hook payload Codex sends, verbatim, then allow (exit 0).
// usage: node record-hook.mjs <label> <out.jsonl>
import { appendFileSync } from 'node:fs';
const [label, out] = [process.argv[2] ?? 'unlabelled', process.argv[3]];
let data = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { data += c; });
process.stdin.on('end', () => {
  let payload;
  try { payload = JSON.parse(data); } catch { payload = data; }
  const rec = { label, ts: new Date().toISOString(), argv: process.argv.slice(2), env_hook_vars: Object.fromEntries(Object.entries(process.env).filter(([k]) => /CODEX|HOOK/i.test(k))), payload };
  appendFileSync(out, JSON.stringify(rec) + '\n');
  process.exit(0);
});
process.stdin.resume();
