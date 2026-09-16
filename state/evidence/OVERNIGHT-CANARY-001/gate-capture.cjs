const childProcess = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { syncBuiltinESMExports } = require('node:module');

const target = process.argv[1] ? path.resolve(process.argv[1]).replaceAll('\\', '/') : '';
const capture = process.env.HARNESS_GATE_CAPTURE;
if (
  capture
  && target.endsWith('/harness/tests/gate.mjs')
  && !process.execArgv.includes('--check')
  && !process.env.HARNESS_GATE_CAPTURE_ACTIVE
) {
  process.env.HARNESS_GATE_CAPTURE_ACTIVE = '1';
  const append = (value, encoding) => {
    const data = Buffer.isBuffer(value)
      ? value
      : Buffer.from(String(value), typeof encoding === 'string' ? encoding : 'utf8');
    fs.appendFileSync(capture, data);
  };
  fs.appendFileSync(
    capture,
    `COMMAND: node harness/tests/gate.mjs\n=== gate-process-start pid=${process.pid} utc=${new Date().toISOString()} ===\n`,
  );

  const stdoutWrite = process.stdout.write.bind(process.stdout);
  const stderrWrite = process.stderr.write.bind(process.stderr);
  process.stdout.write = (chunk, encoding, callback) => {
    append(chunk, encoding);
    return stdoutWrite(chunk, encoding, callback);
  };
  process.stderr.write = (chunk, encoding, callback) => {
    append(chunk, encoding);
    return stderrWrite(chunk, encoding, callback);
  };

  const originalSpawnSync = childProcess.spawnSync;
  childProcess.spawnSync = (command, args, options = {}) => {
    if (options.stdio !== 'inherit') return originalSpawnSync(command, args, options);
    const result = originalSpawnSync(command, args, {
      ...options,
      stdio: ['inherit', 'pipe', 'pipe'],
      maxBuffer: 32 * 1024 * 1024,
    });
    if (result.stdout) {
      append(result.stdout);
      stdoutWrite(result.stdout);
    }
    if (result.stderr) {
      append(result.stderr);
      stderrWrite(result.stderr);
    }
    return result;
  };
  syncBuiltinESMExports();

  process.on('exit', (code) => {
    fs.appendFileSync(
      capture,
      `\n=== gate-process-end pid=${process.pid} code=${code} utc=${new Date().toISOString()} ===\n`,
    );
  });
}
