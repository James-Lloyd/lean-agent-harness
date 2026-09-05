// Cross-platform hook dispatcher for the lean-agent-harness plugin.
//
// A plugin's hooks.json is STATIC — it can't branch on the operating system the
// way /harness-init does when it wires .claude/settings.json. So every hook is
// routed through this one shim: `node run.mjs <hook-name>`. Node is a hard
// dependency of Claude Code, so it is always present.
//
// We pick the platform-native interpreter (Windows PowerShell 5.1 on win32, bash
// elsewhere), run the matching hook body that sits next to this file, forward
// stdin verbatim (hooks receive their tool-call payload as JSON on stdin), and
// exit with the child's exit code — so a blocked destructive command still
// surfaces exit 2 to Claude Code and the call is denied.
//
// `node run.mjs --codex <hook-name>` is the OpenAI Codex CLI mode (slice V5, verified
// live on Codex 0.144.3): Codex sends the SAME payload (tool_name "Bash",
// tool_input.command, hook_event_name, …) but does NOT treat exit code 2 as a
// denial — a hook exiting 2 is logged "PreToolUse Failed" and the call PROCEEDS
// (fail-open). Codex blocks only on the JSON decision written to stdout with exit
// 0. In --codex mode the shim therefore buffers the payload, captures the child's
// streams, and translates exit 2 + stderr into that JSON; everything else passes
// through unchanged. The hook BODIES stay single-contract (exit 2 = deny).
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync } from 'node:fs';

// Pure, testable: given a platform + hook name, return the interpreter, its args,
// and the resolved script path. No side effects — the unit test drives this for
// both OS branches without spawning anything.
export function resolveHook(platform, hook, hooksDir) {
  const isWin = platform === 'win32';
  const script = join(hooksDir, `${hook}.${isWin ? 'ps1' : 'sh'}`);
  const cmd = isWin ? 'powershell.exe' : 'bash';
  const args = isWin
    ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script]
    : [script];
  return { cmd, args, script };
}

// Pure: `node run.mjs [--codex] <hook>` -> { codex, hook }.
export function parseArgs(argv) {
  const rest = argv.slice(2);
  const codex = rest[0] === '--codex';
  const hook = codex ? rest[1] : rest[0];
  // Any other flag-shaped arg (or --codex not in first position) is a usage error, not a hook name:
  // `node run.mjs block-destructive --codex` must not silently run in Claude mode under Codex (fail-open).
  const bad = rest.find((a, i) => a.startsWith('-') && !(i === 0 && a === '--codex'));
  return { codex, hook: bad ? undefined : hook, error: bad ? `unknown argument '${bad}'` : undefined };
}

// Pure: translate a hook body's outcome into what Codex acts on.
//   exit 0      -> pass the child's stdout through (SessionStart context etc.), exit 0
//   exit 2      -> DENY: PreToolUse uses the hookSpecificOutput form (OBSERVED to block on
//                  Codex 0.144.3 in slice V5; PermissionRequest is the documented sibling,
//                  speculative — nothing the harness generates fires it). Other events get
//                  the older {decision:"block", reason} form (documented, NOT observed) AND
//                  keep the child's stderr, so the reason survives even if Codex ignores
//                  the JSON. Exit 0 always: Codex ignores a nonzero exit, so the decision
//                  MUST ride on stdout + exit 0.
//   other code  -> a hook ERROR, not a decision: stderr through, same exit code (both
//                  vendors treat it as non-blocking — nothing to translate)
export function codexDecision(exitCode, stdout, stderr, eventName) {
  if (exitCode === 0) return { out: stdout || '', err: stderr || '', code: 0 };
  if (exitCode === 2) {
    const reason = (stderr || '').trim() || `blocked by harness hook (${eventName})`;
    const ev = eventName || 'PreToolUse';
    if (ev === 'PreToolUse' || ev === 'PermissionRequest') {
      return { out: JSON.stringify({ hookSpecificOutput: { hookEventName: ev, permissionDecision: 'deny', permissionDecisionReason: reason } }), err: '', code: 0 };
    }
    return { out: JSON.stringify({ decision: 'block', reason }), err: stderr || '', code: 0 };
  }
  return { out: stdout || '', err: stderr || '', code: exitCode == null ? 1 : exitCode };
}

// Only run the dispatcher when invoked directly (`node run.mjs ...`), not when the
// test imports the pure functions from this module.
const invokedDirectly =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  const here = dirname(fileURLToPath(import.meta.url));
  const { codex, hook, error } = parseArgs(process.argv);
  if (!hook) {
    process.stderr.write(`hook dispatcher: ${error || 'missing hook name'} (usage: node run.mjs [--codex] <hook>)\n`);
    process.exit(2);
  }
  const { cmd, args, script } = resolveHook(process.platform, hook, here);
  if (!existsSync(script)) {
    process.stderr.write(`hook dispatcher: no script for '${hook}' at ${script}\n`);
    process.exit(2);
  }
  if (!codex) {
    // Claude Code: stdio:'inherit' shares this process's stdin/stdout/stderr with the
    // child, so the payload flows straight through and the child's stderr (the block
    // reason) reaches Claude Code unaltered, as does its exit code.
    const child = spawn(cmd, args, { stdio: 'inherit' });
    child.on('error', (err) => {
      process.stderr.write(`hook dispatcher: failed to spawn ${cmd}: ${err.message}\n`);
      process.exit(2);
    });
    child.on('exit', (code, signal) => process.exit(signal ? 1 : code == null ? 1 : code));
  } else {
    // Codex: buffer the payload (we need hook_event_name for the decision shape),
    // feed it to the child, capture its streams, translate on exit.
    let payload = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => { payload += c; });
    process.stdin.on('end', () => {
      let eventName = 'PreToolUse';
      try { eventName = JSON.parse(payload).hook_event_name || eventName; } catch { /* keep default */ }
      const child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'pipe'] });
      let out = '', err = '';
      child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
      child.stdout.on('data', (c) => { out += c; });
      child.stderr.on('data', (c) => { err += c; });
      child.on('error', (e) => {
        process.stderr.write(`hook dispatcher: failed to spawn ${cmd}: ${e.message}\n`);
        process.exit(2);
      });
      child.on('close', (code, signal) => {
        const d = codexDecision(signal ? 1 : code, out, err, eventName);
        if (d.err) process.stderr.write(d.err);
        // stdout to a pipe is asynchronous on POSIX: exit only after the decision has been
        // flushed, or a truncated deny JSON becomes an unparseable — i.e. fail-OPEN — decision.
        const finish = () => process.exit(d.code);
        if (d.out) process.stdout.write(d.out, finish); else finish();
      });
      child.stdin.on('error', () => { /* child may exit before reading */ });
      child.stdin.end(payload);
    });
    process.stdin.resume();
  }
}
