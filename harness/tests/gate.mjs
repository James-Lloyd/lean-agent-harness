#!/usr/bin/env node
/*
 * gate.mjs — the harness's OWN gate entry point (harness.config.json -> components[0].gate.test).
 * One command, both self-test twins, on either platform.
 *
 * WHY NODE, and not a .sh/.ps1 twin pair. A gate step in harness.config.json is ONE string, and the
 * engine hands it to a DIFFERENT shell per platform: `cmd /c <cmd>` in plugin/engine/lib/gate.ps1,
 * `bash -lc <cmd>` in gate.sh. So the string has to parse and resolve under both, and no shell
 * spelling does:
 *   - `harness/tests/run-tests.ps1` — cmd.exe refuses a forward-slash command path
 *     ("'harness' is not recognized"); backslashes then break under bash.
 *   - `powershell ... -File ...` — no `powershell` on Linux.
 *   - `bash harness/tests/gate.sh` — MEASURED TRAP, and the reason this file is not a shell script:
 *     under `cmd /c` on Windows, `bash` resolves to WSL's C:\Windows\System32\bash.exe, NOT to Git
 *     Bash (which is only on PATH inside a Git Bash session). On a box without WSL the gate died with
 *     HCS_E_HYPERV_NOT_INSTALLED; with WSL it would have run the suite in a different OS entirely.
 * `node` is on PATH under both shells and is already a harness dependency (the plugin's hook
 * dispatcher, plugin/hooks/run.mjs, is a cross-platform .mjs for exactly this reason), and node
 * resolves paths itself, so the platform dispatch lives here — written once — instead of being
 * encoded in a config string.
 *
 * WHAT IT RUNS. The platform's NATIVE twin is mandatory and fails the gate if it is missing or red
 * (Windows -> run-tests.ps1, POSIX -> run-tests.sh). On Windows the .sh twin is run as well when Git
 * Bash can be located BY PATH ON DISK (never by a PATH lookup — see above), which is the common case
 * on a dev box and grades both twins locally.
 *
 * On POSIX the .ps1 twin is NOT attempted, even where pwsh exists. That is a DECISION, not a
 * measurement: run-tests.ps1 does carry a pwsh/powershell host branch and may well run there, but
 * nothing in CI has ever run it off Windows, so its POSIX behaviour is unknown and a red from it
 * would say nothing about the change under test. If that gets measured, run it and delete this
 * paragraph.
 *
 * Whenever a twin goes ungraded the run prints a loud UNGRADED banner naming CI's per-OS jobs as the
 * backstop. NOTE the limit of that, honestly: the engine's gate step (Invoke-GateStep / _gate_step)
 * PRINTS a command's output only when it exits non-zero, so on a green half-graded run the banner is
 * captured and discarded — it is visible under /verify, where the agent runs this command itself,
 * and invisible under loop/fleet. Set HARNESS_GATE_STRICT=1 to make an ungraded twin exit non-zero
 * instead; that is what makes the half-grade reach a caller that only reads the exit code.
 *
 *   Run:  node harness/tests/gate.mjs
 */
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const WIN = process.platform === 'win32';

function which(cmd) {
  const probe = spawnSync(WIN ? 'where' : 'command', WIN ? [cmd] : ['-v', cmd], {
    encoding: 'utf8', shell: !WIN,
  });
  if (probe.status !== 0) return null;
  const first = String(probe.stdout || '').split(/\r?\n/).find((l) => l.trim());
  return first ? first.trim() : null;
}

// A PowerShell to run the .ps1 twin — WINDOWS ONLY, deliberately. Windows PowerShell 5.1 is the
// harness's documented engine and run-tests.ps1 carries no platform branches (it drives cmd.exe
// forms, `powershell`, Windows paths); CI never runs it anywhere but windows-latest. Reaching for a
// Linux `pwsh` would produce reds that say nothing about the change under test, so on POSIX the .ps1
// twin is reported UNGRADED instead of attempted.
function findPowerShell() {
  if (!WIN) return null;
  for (const c of ['powershell', 'pwsh']) {
    if (which(c)) return { exe: c, args: ['-NoProfile', '-ExecutionPolicy', 'Bypass'] };
  }
  return null;
}

// A bash to run the .sh twin. On Windows a bare PATH lookup finds WSL, which is the wrong OS — so
// look for Git Bash at its real install locations, plus wherever this repo's own git lives.
function findBash() {
  if (!WIN) {
    const p = which('bash');
    return p ? { exe: p } : null;
  }
  const candidates = [
    join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe'),
    join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Git', 'bin', 'bash.exe'),
    join(process.env.LOCALAPPDATA || '', 'Programs', 'Git', 'bin', 'bash.exe'),
  ];
  const gitExec = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
  if (gitExec.status === 0) {
    // .../Git/mingw64/libexec/git-core -> .../Git/bin/bash.exe
    const m = String(gitExec.stdout).trim().replace(/\//g, '\\').match(/^(.*)\\mingw(?:32|64)\\libexec\\git-core$/i);
    if (m) candidates.push(join(m[1], 'bin', 'bash.exe'));
  }
  const hit = candidates.find((c) => c && existsSync(c));
  return hit ? { exe: hit } : null;
}

function run(label, exe, args, cwd) {
  console.log(`=== ${label}\n    ${exe} ${args.join(' ')}`);
  const r = spawnSync(exe, args, { cwd, stdio: 'inherit' });
  const code = r.status === null ? 1 : r.status;
  if (r.error) console.log(`    ! ${r.error.message}`);
  console.log('');
  return code;
}

const ps = findPowerShell();
const sh = findBash();
let rc = 0;
const ungraded = [];

// --- the .ps1 twin ---
if (ps) {
  rc |= run('PowerShell self-tests (harness/tests/run-tests.ps1)', ps.exe, [...ps.args, '-File', join(HERE, 'run-tests.ps1')], HERE);
} else if (WIN) {
  console.log('=== PowerShell self-tests: no powershell/pwsh found on Windows — failing CLOSED.\n');
  rc = 1;
} else {
  ungraded.push('run-tests.ps1 (POSIX host — not attempted by decision; unmeasured off Windows, CI grades it on windows-latest)');
}

// --- the .sh twin ---
if (sh) {
  rc |= run('bash self-tests (harness/tests/run-tests.sh)', sh.exe, [join(HERE, 'run-tests.sh')], HERE);
} else if (!WIN) {
  console.log('=== bash self-tests: no bash found — failing CLOSED.\n');
  rc = 1;
} else {
  ungraded.push('run-tests.sh (no Git Bash found; a PATH `bash` on Windows is WSL and is not used)');
}

const STRICT = process.env.HARNESS_GATE_STRICT === '1';
for (const u of ungraded) {
  console.log('!!! UNGRADED TWIN: ' + u);
  console.log('!!! This gate run graded HALF the engine. CI (.github/workflows/harness-selftest.yml)');
  console.log('!!! grades the .sh twin on ubuntu and the .ps1 twin on windows, and is the backstop —');
  console.log('!!! but locally, treat this as a gap.' + (STRICT ? ' HARNESS_GATE_STRICT=1: failing on it.' : ''));
}
// A caller that only reads the exit code (the engine's gate step swallows a green command's output)
// cannot see the banner above. HARNESS_GATE_STRICT=1 turns the half-grade into a red.
if (ungraded.length && STRICT) rc |= 1;

console.log(rc === 0 ? `GATE: green${ungraded.length ? ' (half-graded — see above)' : ' (both twins)'}` : 'GATE: RED');
process.exit(rc === 0 ? 0 : 1);
