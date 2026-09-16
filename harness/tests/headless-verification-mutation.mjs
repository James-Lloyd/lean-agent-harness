#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const outFlag = process.argv.indexOf('--out');
if (outFlag < 0 || !process.argv[outFlag + 1]) {
  console.error('usage: node harness/tests/headless-verification-mutation.mjs --out <directory>');
  process.exit(2);
}
const out = resolve(root, process.argv[outFlag + 1]);
mkdirSync(out, { recursive: true });
const scratch = mkdtempSync(join(tmpdir(), 'headless-verification-mutation-'));
const prompt = readFileSync(join(root, 'PROMPT.md'), 'utf8');
const powershell = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const bash = process.platform === 'win32'
  ? join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe')
  : 'bash';

const mutations = [
  {
    id: 'command-cap',
    site: /at most two\s+shell verification commands/,
    replacement: 'shell verification commands',
    expected: 'FAIL caps model-side verification at two shell commands',
  },
  {
    id: 'timeout-cap',
    site: /tool timeout no greater than 120 seconds/,
    replacement: 'a suitable tool timeout',
    expected: 'FAIL requests a per-command tool timeout no greater than 120 seconds',
  },
  {
    id: 'background-ban',
    site: /Never start verification in the background or as a detached process/,
    replacement: 'Background verification is allowed',
    expected: 'FAIL forbids background or detached verification',
  },
  {
    id: 'complete-gate-ban',
    site: /Never invoke a configured complete\s+component or root gate command/,
    replacement: 'You may invoke a configured complete\ncomponent or root gate command',
    expected: 'FAIL forbids the model from invoking configured complete gates',
  },
  {
    id: 'quoted-data-allowance',
    site: /Reading, searching for, or comparing\s+the configured command as quoted data is allowed/,
    replacement: 'The configured command must never appear anywhere',
    expected: 'FAIL allows a configured gate command only as quoted comparison or search data',
  },
  {
    id: 'delegated-gate-ban',
    site: /executing it directly or through a shell, script,\s+function, subprocess, or wrapper is not/,
    replacement: 'delegated execution is allowed',
    expected: 'FAIL forbids direct and delegated gate execution',
  },
  {
    id: 'visible-failure',
    site: /report it plainly in\s+the transcript; do not hide it or convert it into success/,
    replacement: 'continue without recording the result',
    expected: 'FAIL keeps failed or timed-out targeted checks visible',
  },
  {
    id: 'runner-authority',
    site: /Only that runner gate can make the iteration\s+green/,
    replacement: 'The model decides whether the iteration is green',
    expected: 'FAIL names the runner complete gate as the authority',
  },
  {
    id: 'old-complete-gate-requirement',
    append: "\nThe changed component's gate, then the cross-cutting root gate, all pass.\n",
    expected: 'FAIL removes the old model-side complete-gate requirement',
  },
];

function scrub(value) {
  return String(value)
    .replaceAll('\\', '/')
    .replaceAll(resolve(scratch).replaceAll('\\', '/'), '<TMP>')
    .replaceAll(resolve(root).replaceAll('\\', '/'), '<REPO>');
}

function runPair(id, promptPath) {
  const ps = spawnSync(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(here, 'headless-verification-test.ps1'), '-PromptPath', promptPath], {
    cwd: root, encoding: 'utf8', windowsHide: true,
  });
  const sh = spawnSync(bash, [join(here, 'headless-verification-test.sh'), promptPath], {
    cwd: root, encoding: 'utf8', windowsHide: true,
  });
  const psText = scrub(`${ps.stdout || ''}${ps.stderr || ''}`);
  const shText = scrub(`${sh.stdout || ''}${sh.stderr || ''}`);
  writeFileSync(join(out, `${id}-powershell.log`), psText, 'utf8');
  writeFileSync(join(out, `${id}-bash.log`), shText, 'utf8');
  return { ps: { status: ps.status, output: psText }, sh: { status: sh.status, output: shText } };
}

const checks = [];
try {
  const controlPath = join(scratch, 'control.md');
  writeFileSync(controlPath, prompt, 'utf8');
  const control = runPair('control', controlPath);
  checks.push({ id: 'control-powershell', pass: control.ps.status === 0, status: control.ps.status });
  checks.push({ id: 'control-bash', pass: control.sh.status === 0, status: control.sh.status });

  for (const mutation of mutations) {
    let mutant = prompt;
    if (mutation.site) {
      if (!mutation.site.test(mutant)) throw new Error(`mutation site missing: ${mutation.id}`);
      mutant = mutant.replace(mutation.site, mutation.replacement);
    } else {
      mutant += mutation.append;
    }
    const mutantPath = join(scratch, `${mutation.id}.md`);
    writeFileSync(mutantPath, mutant, 'utf8');
    const result = runPair(mutation.id, mutantPath);
    checks.push({
      id: `${mutation.id}-powershell`,
      pass: result.ps.status !== 0 && result.ps.output.includes(mutation.expected),
      status: result.ps.status,
      expected: mutation.expected,
    });
    checks.push({
      id: `${mutation.id}-bash`,
      pass: result.sh.status !== 0 && result.sh.output.includes(mutation.expected),
      status: result.sh.status,
      expected: mutation.expected,
    });
  }

  const summary = { task: 'HEADLESS-VERIFICATION-BOUND-001', mutation: 'remove one prompt protection at a time', checks };
  writeFileSync(join(out, 'result.json'), `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
  for (const check of checks) console.log(`${check.pass ? 'ok' : 'FAIL'} ${check.id}`);
  if (checks.some((check) => !check.pass)) process.exitCode = 1;
} finally {
  const resolved = resolve(scratch);
  const temp = resolve(tmpdir());
  if (!resolved.startsWith(`${temp}${process.platform === 'win32' ? '\\' : '/'}`)) {
    throw new Error(`refusing to remove non-temp scratch path: ${resolved}`);
  }
  rmSync(resolved, { recursive: true, force: true });
}
