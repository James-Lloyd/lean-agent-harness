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

// Only run the dispatcher when invoked directly (`node run.mjs ...`), not when the
// test imports resolveHook from this module.
const invokedDirectly =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  const here = dirname(fileURLToPath(import.meta.url));
  const hook = process.argv[2];
  if (!hook) {
    process.stderr.write('hook dispatcher: missing hook name (usage: node run.mjs <hook>)\n');
    process.exit(2);
  }
  const { cmd, args, script } = resolveHook(process.platform, hook, here);
  if (!existsSync(script)) {
    process.stderr.write(`hook dispatcher: no script for '${hook}' at ${script}\n`);
    process.exit(2);
  }
  // stdio:'inherit' shares this process's stdin/stdout/stderr with the child, so
  // the hook payload on stdin flows straight through and the child's stderr (the
  // block reason) reaches Claude Code unaltered.
  const child = spawn(cmd, args, { stdio: 'inherit' });
  child.on('error', (err) => {
    process.stderr.write(`hook dispatcher: failed to spawn ${cmd}: ${err.message}\n`);
    process.exit(2);
  });
  child.on('exit', (code, signal) => process.exit(signal ? 1 : code == null ? 1 : code));
}
