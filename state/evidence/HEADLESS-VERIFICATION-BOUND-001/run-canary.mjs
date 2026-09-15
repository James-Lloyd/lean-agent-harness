#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';

const mode = process.argv[2];
if (mode !== 'pre' && mode !== 'post') {
  console.error('usage: node state/evidence/HEADLESS-VERIFICATION-BOUND-001/run-canary.mjs pre|post');
  process.exit(2);
}

const scriptDir = dirname(fileURLToPath(import.meta.url));
const sourceRoot = resolve(scriptDir, '..', '..', '..');
const outputDir = join(scriptDir, mode);
if (existsSync(outputDir)) {
  if (existsSync(join(outputDir, 'result.json'))) {
    console.error(`${mode} evidence already completed; refusing to overwrite it`);
    process.exit(2);
  }
  let attempt = 1;
  let archived = join(scriptDir, `${mode}-driver-failure-${attempt}`);
  while (existsSync(archived)) archived = join(scriptDir, `${mode}-driver-failure-${++attempt}`);
  renameSync(outputDir, archived);
}
mkdirSync(outputDir, { recursive: true });

const globalGitNull = process.platform === 'win32' ? 'NUL' : '/dev/null';
const baseEnv = { ...process.env, GIT_CONFIG_GLOBAL: globalGitNull };
const home = resolve(process.env.USERPROFILE || process.env.HOME || '');
const tempBase = resolve(tmpdir());
const tempRoot = mkdtempSync(join(tempBase, `harness-headless-${mode}-`));
const canaryRoot = join(tempRoot, 'repo');

function scrub(value) {
  let text = String(value).replaceAll('\\', '/');
  const replacements = [
    [resolve(canaryRoot).replaceAll('\\', '/'), '<CANARY>'],
    [resolve(sourceRoot).replaceAll('\\', '/'), '<SOURCE>'],
    [resolve(tempRoot).replaceAll('\\', '/'), '<TMP>'],
    [home.replaceAll('\\', '/'), '<HOME>'],
  ].filter(([needle]) => needle && needle !== '.').sort((a, b) => b[0].length - a[0].length);
  for (const [needle, replacement] of replacements) {
    text = text.replaceAll(needle, replacement);
    text = text.replaceAll(needle.toLowerCase(), replacement);
  }
  text = text.replace(/\/tmp\/harness-headless-(?:pre|post)-[^/\s]+/gi, '<TMP>');
  return text;
}

function replaceExactlyOnce(text, before, after, label) {
  const first = text.indexOf(before);
  if (first < 0 || text.indexOf(before, first + before.length) >= 0) {
    throw new Error(`expected exactly one ${label} fixture value`);
  }
  return `${text.slice(0, first)}${after}${text.slice(first + before.length)}`;
}

function run(command, args, cwd = sourceRoot, options = {}) {
  const result = spawnSync(command, args, {
    cwd,
    env: { ...baseEnv, ...(options.env || {}) },
    encoding: 'utf8',
    windowsHide: true,
    shell: Boolean(options.shell),
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (!options.allowFailure && result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed (${result.status}):\n${result.stdout}\n${result.stderr}`);
  }
  return result;
}

function git(args, cwd = sourceRoot, options = {}) {
  return run('git', args, cwd, options);
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function findRunDir() {
  const runs = join(canaryRoot, 'harness', '.runs');
  if (!existsSync(runs)) return null;
  const names = readdirSync(runs).filter((name) => /^run-\d+$/.test(name)).sort();
  return names.length ? join(runs, names.at(-1)) : null;
}

function captureIfPresent(source, target) {
  if (!existsSync(source)) return false;
  writeFileSync(target, scrub(readFileSync(source, 'utf8')), 'utf8');
  return true;
}

function proveGateCapturePreload() {
  const fixtureRoot = join(tempRoot, 'capture-self-test');
  const fixtureDir = join(fixtureRoot, 'harness', 'tests');
  mkdirSync(fixtureDir, { recursive: true });
  const gateFixture = join(fixtureDir, 'gate.mjs');
  const otherFixture = join(fixtureDir, 'other.mjs');
  const capturePath = join(fixtureRoot, 'capture.txt');
  const negativePath = join(fixtureRoot, 'negative.txt');
  const syntaxCheckPath = join(fixtureRoot, 'syntax-check.txt');
  writeFileSync(gateFixture, "import { spawnSync } from 'node:child_process';\nspawnSync(process.execPath, ['-e', \"console.log('child-output')\"], { stdio: 'inherit' });\nconsole.log('parent-output');\n", 'utf8');
  writeFileSync(otherFixture, "console.log('negative-control');\n", 'utf8');
  const preload = join(scriptDir, 'gate-capture.cjs').replaceAll('\\', '/');
  const positive = run(process.execPath, [gateFixture], fixtureRoot, {
    allowFailure: true,
    env: { NODE_OPTIONS: `--require=${preload}`, HARNESS_GATE_CAPTURE: capturePath },
  });
  const negative = run(process.execPath, [otherFixture], fixtureRoot, {
    allowFailure: true,
    env: { NODE_OPTIONS: `--require=${preload}`, HARNESS_GATE_CAPTURE: negativePath },
  });
  const syntaxCheck = run(process.execPath, ['--check', gateFixture], fixtureRoot, {
    allowFailure: true,
    env: { NODE_OPTIONS: `--require=${preload}`, HARNESS_GATE_CAPTURE: syntaxCheckPath },
  });
  const captured = existsSync(capturePath) ? readFileSync(capturePath, 'utf8') : '';
  const checks = {
    positiveExitZero: positive.status === 0,
    childOutputCaptured: captured.includes('child-output'),
    parentOutputCaptured: captured.includes('parent-output'),
    exitMarkerCaptured: /gate-process-end .* code=0/.test(captured),
    outputStillVisible: String(positive.stdout).includes('child-output') && String(positive.stdout).includes('parent-output'),
    unrelatedNodeIgnored: negative.status === 0 && !existsSync(negativePath),
    syntaxCheckIgnored: syntaxCheck.status === 0 && !existsSync(syntaxCheckPath),
  };
  writeJson(join(outputDir, 'capture-self-test.json'), {
    checks,
    positiveOutput: scrub(`${positive.stdout}${positive.stderr}`),
    capturedOutput: scrub(captured),
    negativeOutput: scrub(`${negative.stdout}${negative.stderr}`),
  });
  if (Object.values(checks).some((value) => !value)) {
    throw new Error(`gate capture preload self-test failed: ${JSON.stringify(checks)}`);
  }
}

let tempRemoved = false;
try {
  proveGateCapturePreload();
  const baseRef = git(['rev-parse', 'origin/main']).stdout.trim();
  run('git', ['clone', '--quiet', '--no-hardlinks', sourceRoot, canaryRoot], tempRoot);
  git(['switch', '--quiet', '-c', `evidence-headless-${mode}`, baseRef], canaryRoot);

  const planPath = join(canaryRoot, 'state', 'fix_plan.md');
  let plan = readFileSync(planPath, 'utf8');
  const prerequisite = /^- \[ \](?: \(wip: [^)]+\))? Determine and bound headless in-model verification/m;
  if (!prerequisite.test(plan)) throw new Error('could not locate the headless-verification prerequisite');
  plan = plan.replace(prerequisite, '- [x] Determine and bound headless in-model verification');
  writeFileSync(planPath, plan, 'utf8');

  const tasksPath = join(canaryRoot, 'state', 'tasks.json');
  const tasks = JSON.parse(readFileSync(tasksPath, 'utf8'));
  tasks.tasks.push({
    id: 'OVERNIGHT-CANARY-001',
    category: 'docs',
    component: 'root',
    description: "Correct the overnight guide's stale claim that this repo has an empty root gate.",
    steps: ['Correct only the stale root-gate paragraph and record user-visible evidence'],
    acceptance: 'The guide describes the wired cross-platform self-test gate and the configured gate remains green.',
    files: ['docs/overnight.md', 'state/'],
    status: 'todo',
    evidence: null,
    passes: false,
  });
  writeJson(tasksPath, tasks);

  const configPath = join(canaryRoot, 'harness', 'harness.config.json');
  let configText = readFileSync(configPath, 'utf8');
  configText = replaceExactlyOnce(
    configText,
    '"implement": { "model": "claude-opus-5",    "fallback": null,            "effort": "high" }',
    '"implement": { "model": "codex",             "fallback": null,            "effort": "high" }',
    'implement route',
  );
  configText = replaceExactlyOnce(configText, '"mode": "supervised"', '"mode": "auto"', 'autonomy mode');
  configText = replaceExactlyOnce(configText, '"maxIterations": 20', '"maxIterations": 1', 'iteration limit');
  configText = replaceExactlyOnce(configText, '"everyNIterations": 5', '"everyNIterations": 0', 'checkpoint interval');
  configText = replaceExactlyOnce(configText, '"commitOnGreen": true', '"commitOnGreen": false', 'commit toggle');
  configText = replaceExactlyOnce(configText, '"tagOnGreen": true', '"tagOnGreen": false', 'tag toggle');
  if (mode === 'pre') {
    configText = replaceExactlyOnce(configText, '"timeoutSeconds": 900', '"timeoutSeconds": 300', 'Codex watchdog');
  }
  writeFileSync(configPath, configText, 'utf8');
  const config = JSON.parse(configText);

  const routingSkillPath = join(canaryRoot, 'plugin', 'skills', 'model-routing', 'SKILL.md');
  let routingSkill = readFileSync(routingSkillPath, 'utf8');
  routingSkill = replaceExactlyOnce(
    routingSkill,
    '| `implement` | `generator` | `claude-opus-5` | `high` | `null` |',
    '| `implement` | `generator` | `codex` | `high` | `null` |',
    'model-routing skill row',
  );
  writeFileSync(routingSkillPath, routingSkill, 'utf8');
  const implementLine = configText.split(/\r?\n/).find((line) => line.includes('\"implement\":')) || '';
  const fixtureChecks = {
    productionGateExact: config.components[0].gate.test === 'node harness/tests/gate.mjs',
    implementFieldsRemainOneLine: /\"model\": \"codex\".*\"fallback\": null.*\"effort\": \"high\"/.test(implementLine),
    routingSkillMatches: routingSkill.includes('| `implement` | `generator` | `codex` | `high` | `null` |'),
  };
  if (Object.values(fixtureChecks).some((value) => !value)) {
    throw new Error(`canary fixture preflight failed: ${JSON.stringify(fixtureChecks)}`);
  }

  // The loop intentionally swallows a green gate's stdout. Capture the real gate process without
  // changing its configured command: this preload activates only for gate.mjs, mirrors the inherited
  // child output, and preserves each child's original status/error result.
  const gateCapturePreload = join(canaryRoot, '.harness-canary-gate-capture.cjs');
  copyFileSync(join(scriptDir, 'gate-capture.cjs'), gateCapturePreload);

  if (mode === 'post') {
    copyFileSync(join(sourceRoot, 'PROMPT.md'), join(canaryRoot, 'PROMPT.md'));
  }

  git(['add', '.harness-canary-gate-capture.cjs', 'PROMPT.md', 'harness/harness.config.json', 'plugin/skills/model-routing/SKILL.md', 'state/fix_plan.md', 'state/tasks.json'], canaryRoot);
  git(['-c', 'user.name=Harness Evidence', '-c', 'user.email=evidence@example.invalid', 'commit', '--quiet', '-m', `headless ${mode} canary fixture`], canaryRoot);
  const fixtureRef = git(['rev-parse', 'HEAD'], canaryRoot).stdout.trim();
  const fixturePatch = git(['diff', '--binary', `${baseRef}..${fixtureRef}`], canaryRoot).stdout;
  writeFileSync(join(outputDir, 'fixture.patch'), scrub(fixturePatch), 'utf8');

  const effectiveGate = config.components[0].gate.test;
  const codexLauncher = process.platform === 'win32'
    ? join(process.env.APPDATA || '', 'npm', 'codex.cmd')
    : 'codex';
  const codexVersion = run(codexLauncher, ['--version'], canaryRoot, { allowFailure: true, shell: process.platform === 'win32' });
  const codexAuth = run(codexLauncher, ['login', 'status'], canaryRoot, { allowFailure: true, shell: process.platform === 'win32' });
  const engineRef = git(['rev-parse', 'HEAD'], sourceRoot).stdout.trim();
  writeJson(join(outputDir, 'environment.json'), {
    mode,
    baseRef,
    fixtureRef,
    engineRef,
    effectiveGate,
    fixtureChecks,
    watchdogSeconds: config.models.codex.timeoutSeconds,
    codexVersion: scrub(`${codexVersion.stdout}${codexVersion.stderr}`).trim(),
    codexVersionExit: codexVersion.status,
    codexAuth: scrub(`${codexAuth.stdout}${codexAuth.stderr}`).trim(),
    codexAuthExit: codexAuth.status,
  });

  const powershell = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const loopArgs = [
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', join(sourceRoot, 'plugin', 'engine', 'loop.ps1'),
    '-ProjectRoot', canaryRoot,
    '-Mode', 'auto',
    '-MaxIterations', '1',
  ];
  const childEnv = {
    ...baseEnv,
    HARNESS_ENGINE: join(sourceRoot, 'plugin', 'engine'),
    HARNESS_SANDBOX: '1',
    HARNESS_GATE_CAPTURE: join(canaryRoot, 'harness', '.runs', 'canary-outer-gate.txt'),
    NODE_OPTIONS: [baseEnv.NODE_OPTIONS, `--require=${gateCapturePreload.replaceAll('\\', '/')}`].filter(Boolean).join(' '),
  };
  const startedUtc = new Date().toISOString();
  const started = performance.now();
  const stdout = [];
  const stderr = [];
  let observedLength = 0;
  let pendingLine = '';
  const timeline = [];
  const child = spawn(powershell, loopArgs, {
    cwd: canaryRoot,
    env: childEnv,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', (chunk) => stdout.push(chunk));
  child.stderr.on('data', (chunk) => stderr.push(chunk));

  function pollTranscript() {
    const runDir = findRunDir();
    const iterLog = runDir && join(runDir, 'iter-1.log');
    if (!iterLog || !existsSync(iterLog)) return;
    const current = readFileSync(iterLog, 'utf8');
    pendingLine += current.slice(observedLength);
    observedLength = current.length;
    const lines = pendingLine.split(/\r?\n/);
    pendingLine = lines.pop() || '';
    for (const line of lines.filter(Boolean)) {
      timeline.push({ elapsedMs: Math.round(performance.now() - started), line: scrub(line) });
    }
  }
  const poll = setInterval(pollTranscript, 100);

  const exit = await new Promise((resolveExit) => {
    child.on('error', (error) => resolveExit({ code: null, signal: null, error: String(error) }));
    child.on('exit', (code, signal) => resolveExit({ code, signal, error: null }));
  });
  clearInterval(poll);
  pollTranscript();
  if (pendingLine) timeline.push({ elapsedMs: Math.round(performance.now() - started), line: scrub(pendingLine) });
  const elapsedMs = Math.round(performance.now() - started);
  const endedUtc = new Date().toISOString();
  writeFileSync(join(outputDir, 'loop-output.log'), scrub(Buffer.concat(stdout).toString('utf8')), 'utf8');
  writeFileSync(join(outputDir, 'loop-stderr.log'), scrub(Buffer.concat(stderr).toString('utf8')), 'utf8');
  writeFileSync(join(outputDir, 'timeline.jsonl'), timeline.map((entry) => JSON.stringify(entry)).join('\n') + (timeline.length ? '\n' : ''), 'utf8');

  const runDir = findRunDir();
  if (runDir) {
    captureIfPresent(join(runDir, 'iter-1.log'), join(outputDir, 'iter-1.log'));
    captureIfPresent(join(runDir, 'ledger.jsonl'), join(outputDir, 'ledger.jsonl'));
  }
  captureIfPresent(join(canaryRoot, 'harness', '.runs', 'canary-outer-gate.txt'), join(outputDir, 'outer-gate.txt'));

  const endRef = git(['rev-parse', 'HEAD'], canaryRoot).stdout.trim();
  const status = git(['status', '--short'], canaryRoot).stdout;
  writeJson(join(outputDir, 'result.json'), {
    mode,
    command: scrub([powershell, ...loopArgs].join(' ')),
    startedUtc,
    endedUtc,
    elapsedMs,
    exit,
    startRef: fixtureRef,
    endRef,
    status: scrub(status).trimEnd().split(/\r?\n/).filter(Boolean),
    captured: {
      transcript: existsSync(join(outputDir, 'iter-1.log')),
      ledger: existsSync(join(outputDir, 'ledger.jsonl')),
      outerGate: existsSync(join(outputDir, 'outer-gate.txt')),
      timelineEntries: timeline.length,
    },
  });
  console.log(JSON.stringify({ mode, elapsedMs, exit, startRef: fixtureRef, endRef, status: scrub(status).trim(), outputDir: `<SOURCE>/state/evidence/HEADLESS-VERIFICATION-BOUND-001/${mode}` }, null, 2));
} finally {
  const resolvedTemp = resolve(tempRoot);
  if (resolvedTemp.startsWith(`${tempBase}${process.platform === 'win32' ? '\\' : '/'}`) && resolvedTemp.includes(`harness-headless-${mode}-`)) {
    rmSync(resolvedTemp, { recursive: true, force: true });
    tempRemoved = true;
  }
  writeJson(join(outputDir, 'cleanup.json'), { tempRemoved });
}
