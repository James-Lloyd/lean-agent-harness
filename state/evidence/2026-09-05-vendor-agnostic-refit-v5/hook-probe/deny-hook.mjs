// V5 probe: a PreToolUse hook that DENIES via the documented JSON decision output (exit 0), for any
// command mentioning "probe-dir"; allows everything else. Records the payload it saw.
import { appendFileSync } from 'node:fs';
const out = process.argv[2];
let data = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { data += c; });
process.stdin.on('end', () => {
  let p = {}; try { p = JSON.parse(data); } catch {}
  const cmd = (p.tool_input && p.tool_input.command) || '';
  appendFileSync(out, JSON.stringify({ ts: new Date().toISOString(), tool_name: p.tool_name, cmd }) + '\n');
  if (cmd.includes('probe-dir')) {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: 'BLOCKED by harness guardrail (probe): recursive force-delete' } }));
  }
  process.exit(0);
});
process.stdin.resume();
