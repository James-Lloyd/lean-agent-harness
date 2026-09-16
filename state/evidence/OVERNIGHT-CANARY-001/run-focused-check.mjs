#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const evidenceRoot = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(evidenceRoot, '..', '..', '..');
const outputFlag = process.argv.indexOf('--output-dir');
if (outputFlag >= 0 && !process.argv[outputFlag + 1]) {
  throw new Error('--output-dir requires a path');
}
const outputRoot = outputFlag >= 0 ? resolve(process.argv[outputFlag + 1]) : evidenceRoot;
mkdirSync(outputRoot, { recursive: true });
const read = (path) => readFileSync(join(repoRoot, path), 'utf8');
const config = JSON.parse(read('harness/harness.config.json'));
const tasks = JSON.parse(read('state/tasks.json')).tasks;
const guide = read('docs/overnight.md');
const dispatcher = join(repoRoot, 'harness', 'tests', 'gate.mjs');
const checks = [];

function check(label, condition) {
  checks.push({ label, passed: Boolean(condition) });
}

const task = tasks.filter(({ id }) => id === 'OVERNIGHT-CANARY-001');
const root = config.components.find(({ name }) => name === 'root');
const crossCuttingCommands = Object.entries(config.gate)
  .filter(([key]) => !key.startsWith('_'))
  .map(([, value]) => value);
const syntax = spawnSync(process.execPath, ['--check', dispatcher], { encoding: 'utf8' });

check('one OVERNIGHT-CANARY-001 task record exists', task.length === 1);
check('guide names the exact configured root gate command', guide.includes('`node harness/tests/gate.mjs`'));
check('guide describes native and Bash twin dispatch', /native self-test twin[\s\S]*bash twin/i.test(guide));
check('stale root-empty example claim is absent', !guide.includes("as in this harness's own root component"));
check('root component gate.test is the documented command', root?.gate?.test === 'node harness/tests/gate.mjs');
check('cross-cutting gate has no configured commands', crossCuttingCommands.every((value) => value === null));
check('empty-gate warning covers component and cross-cutting gates', /component gates and cross-cutting gate contain no[\s\S]*commands/.test(guide));
check('configured dispatcher exists', existsSync(dispatcher));
check('configured dispatcher parses', syntax.status === 0);
check('PowerShell twin retains root gate wiring coverage', read('harness/tests/run-tests.ps1').includes("root component gate.test is wired (not null)"));
check('Bash twin retains root gate wiring coverage', read('harness/tests/run-tests.sh').includes('root component gate.test is wired (not null)'));
check('task points to its evidence directory', task[0]?.evidence === 'state/evidence/OVERNIGHT-CANARY-001/');
check('operator evidence note exists', existsSync(join(evidenceRoot, 'README.md')));

const passed = checks.filter(({ passed: ok }) => ok).length;
const failed = checks.length - passed;
const lines = [
  `COMMAND: node state/evidence/OVERNIGHT-CANARY-001/run-focused-check.mjs${outputFlag >= 0 ? ' --output-dir <OUTPUT_DIR>' : ''}`,
  ...checks.map(({ label, passed: ok }) => `  ${ok ? 'ok' : 'not ok'}  ${label}`),
  '',
  `RESULT: ${passed} passed, ${failed} failed`,
  `EXIT_CODE: ${failed === 0 ? 0 : 1}`,
  '',
];

const output = lines.join('\n');
writeFileSync(join(outputRoot, 'focused-check.txt'), output, 'utf8');
process.stdout.write(output);
process.exitCode = failed === 0 ? 0 : 1;
