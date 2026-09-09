#!/usr/bin/env node
/*
 * force-env.mjs — run a copy of gate.mjs under a DOCTORED environment, to reach the half-grade
 * branch without editing the code (AGENTS.md 2026-09-06: force the branch through the environment,
 * and give it a positive control).
 *
 * It exists because `env ProgramFiles=... bash` does NOT work from Git Bash: MSYS special-cases that
 * one variable and hands the child the real `C:\Program Files` anyway (measured — `ProgramFiles(x86)`
 * and `LOCALAPPDATA` did get through, `ProgramFiles` did not). Spawning from node sets the child's
 * environment verbatim, with no shell in between.
 *
 *   node force-env.mjs <gate.mjs> <strict:0|1> <nogitbash:0|1>
 *
 * nogitbash=1 points every Git-install candidate at an empty dir and strips git from PATH (System32,
 * WindowsPowerShell and nodejs stay, so `where` and powershell.exe still resolve) — so findBash
 * returns null while the .ps1 twin still runs.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [gate, strict, nogit] = process.argv.slice(2);
const env = { ...process.env, HARNESS_GATE_STRICT: strict === '1' ? '1' : '0' };

if (nogit === '1') {
  const empty = mkdtempSync(join(tmpdir(), 'noGit-'));
  env.ProgramFiles = empty;
  env['ProgramFiles(x86)'] = empty;
  env.ProgramW6432 = empty;
  env.LOCALAPPDATA = empty;
  const sysroot = process.env.SystemRoot || 'C:\\Windows';
  env.PATH = [
    join(sysroot, 'System32'),
    join(sysroot, 'System32', 'WindowsPowerShell', 'v1.0'),
    join(process.execPath, '..'),
  ].join(';');
  env.Path = env.PATH;
}

const r = spawnSync(process.execPath, [gate], { env, encoding: 'utf8' });
process.stdout.write((r.stdout || '') + (r.stderr || ''));
process.exit(r.status === null ? 1 : r.status);
