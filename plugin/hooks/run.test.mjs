// Unit + e2e test for the cross-platform hook dispatcher (run.mjs).
// Cross-platform by design: runs on Windows or Unix via `node run.test.mjs`.
// Wired into both harness test suites (run-tests.ps1 / run-tests.sh).
//
//  1-2. Branch SELECTION is pure and tested for BOTH OSes here, regardless of the
//       host: win32 -> powershell.exe + .ps1, anything else -> bash + .sh.
//  3-4. A real dispatch on the CURRENT platform proves stdin passthrough and exit
//       -code preservation end to end: a destructive command is blocked (exit 2),
//       a benign one is allowed (exit 0).
import { resolveHook } from './run.mjs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
let pass = 0, fail = 0;
const ok = (name, cond) => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name); }
};

// 1. Windows branch selection
{
  const r = resolveHook('win32', 'block-destructive', here);
  ok('win32 -> powershell.exe -File block-destructive.ps1',
    r.cmd === 'powershell.exe' && r.args.includes('-File') && r.script.endsWith('block-destructive.ps1'));
}
// 2. Unix branch selection
{
  const r = resolveHook('linux', 'block-destructive', here);
  ok('linux -> bash block-destructive.sh',
    r.cmd === 'bash' && r.args.length === 1 && r.script.endsWith('block-destructive.sh'));
}

// Real dispatch on the current platform. On Unix these exercise the .sh body; on
// Windows the .ps1 body — either way through run.mjs, proving the shim forwards
// stdin and preserves the child's exit code.
const dispatch = (payload) =>
  spawnSync(process.execPath, [join(here, 'run.mjs'), 'block-destructive'],
    { input: payload, encoding: 'utf8' });

// 3. destructive command blocked (exit 2)
{
  const res = dispatch(JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'rm -rf /' } }));
  ok('destructive `rm -rf /` blocked via dispatcher (exit 2)', res.status === 2);
}
// 4. benign command allowed (exit 0)
{
  const res = dispatch(JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'git status' } }));
  ok('benign `git status` allowed via dispatcher (exit 0)', res.status === 0);
}

console.log(`\nRESULT: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
