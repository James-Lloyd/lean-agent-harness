// Unit + e2e test for the cross-platform hook dispatcher (run.mjs).
// Cross-platform by design: runs on Windows or Unix via `node run.test.mjs`.
// Wired into both harness test suites (run-tests.ps1 / run-tests.sh).
//
//  1-2.  Branch SELECTION is pure and tested for BOTH OSes here, regardless of the
//        host: win32 -> powershell.exe + .ps1, anything else -> bash + .sh.
//  3-4.  A real dispatch on the CURRENT platform proves stdin passthrough and exit
//        -code preservation end to end: a destructive command is blocked (exit 2),
//        a benign one is allowed (exit 0).
//  5-9.  --codex mode (slice V5): Codex ignores exit code 2, so a denial must become
//        the JSON permissionDecision on stdout with exit 0 — pure translation table
//        first, then a real dispatch proving the destructive payload yields exit 0 +
//        deny JSON and the benign one exit 0 + no decision.
import { resolveHook, parseArgs, codexDecision } from './run.mjs';
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
const dispatch = (payload, ...pre) =>
  spawnSync(process.execPath, [join(here, 'run.mjs'), ...pre, 'block-destructive'],
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

// 5. arg parsing: --codex is a mode flag, not a hook name
{
  const a = parseArgs(['node', 'run.mjs', '--codex', 'block-destructive']);
  const b = parseArgs(['node', 'run.mjs', 'block-destructive']);
  ok('parseArgs: --codex <hook> / <hook>', a.codex === true && a.hook === 'block-destructive' && b.codex === false && b.hook === 'block-destructive');
  // a misplaced or unknown flag is a usage error, never a silent fall-through to Claude mode (fail-open under Codex)
  const c = parseArgs(['node', 'run.mjs', 'block-destructive', '--codex']);
  const d = parseArgs(['node', 'run.mjs', '--bogus', 'block-destructive']);
  ok('parseArgs: misplaced/unknown flag -> no hook + error', c.hook === undefined && !!c.error && d.hook === undefined && !!d.error);
}
// 6. translation table: exit 2 on PreToolUse -> deny JSON, exit 0, reason = stderr
{
  const d = codexDecision(2, '', 'BLOCKED by harness guardrail: recursive force-delete.\n', 'PreToolUse');
  let j = null; try { j = JSON.parse(d.out); } catch { /* fail below */ }
  ok('codexDecision: exit 2 + PreToolUse -> {hookSpecificOutput.permissionDecision: deny}, exit 0, stderr as reason',
    d.code === 0 && j && j.hookSpecificOutput && j.hookSpecificOutput.hookEventName === 'PreToolUse'
    && j.hookSpecificOutput.permissionDecision === 'deny'
    && j.hookSpecificOutput.permissionDecisionReason.startsWith('BLOCKED by harness guardrail'));
}
// 7. translation table: exit 2 on a non-permission event -> legacy block form; exit 0 / other codes pass through
{
  const post = codexDecision(2, '', 'format failed', 'PostToolUse');
  let j = null; try { j = JSON.parse(post.out); } catch { /* fail below */ }
  const allow = codexDecision(0, 'context line\n', '', 'SessionStart');
  const errc = codexDecision(1, '', 'boom', 'PreToolUse');
  ok('codexDecision: exit 2 + PostToolUse -> {decision: block} AND stderr kept; exit 0 passes stdout; exit 1 stays exit 1 (error, not decision)',
    post.code === 0 && j && j.decision === 'block' && j.reason === 'format failed' && post.err === 'format failed'
    && allow.code === 0 && allow.out === 'context line\n'
    && errc.code === 1 && errc.err === 'boom' && errc.out === '');
}
// 8. e2e --codex: destructive payload -> exit 0 + deny JSON on stdout (what Codex 0.144.3 acts on)
{
  const res = dispatch(JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'rm -rf /' } }), '--codex');
  let j = null; try { j = JSON.parse(res.stdout); } catch { /* fail below */ }
  ok('--codex: destructive `rm -rf /` -> exit 0 + permissionDecision deny on stdout',
    res.status === 0 && j && j.hookSpecificOutput && j.hookSpecificOutput.permissionDecision === 'deny');
}
// 9. e2e --codex: benign payload -> exit 0 and NO decision on stdout
{
  const res = dispatch(JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'git status' } }), '--codex');
  ok('--codex: benign `git status` -> exit 0, empty stdout (no decision)', res.status === 0 && res.stdout.trim() === '');
}

console.log(`\nRESULT: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
