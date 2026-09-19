#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const evidenceDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(evidenceDir, "..", "..", "..");
const args = process.argv.slice(2);
const outputDirIndex = args.indexOf("--output-dir");
if (outputDirIndex >= 0 && !args[outputDirIndex + 1]) throw new Error("--output-dir requires a path");
const outputDir = path.resolve(outputDirIndex >= 0 ? args[outputDirIndex + 1] : evidenceDir);
const resultFile = path.join(outputDir, "result.json");
const pluginRoot = path.join(repoRoot, "plugin");
const installer = path.join(pluginRoot, "scripts", "install-codex-hooks.mjs");
const doctorFile = path.join(pluginRoot, "commands", "harness-doctor.md");
const twinTestFiles = [
  path.join(repoRoot, "harness", "tests", "run-tests.ps1"),
  path.join(repoRoot, "harness", "tests", "run-tests.sh"),
];
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "harness-hook-ratchet-"));
const target = path.join(tempRoot, "hooks.json");
const checks = [];

function record(name, pass, detail) {
  checks.push({ name, pass: Boolean(pass), detail });
}

function runInstaller(extraArgs) {
  return spawnSync(process.execPath, [installer, "--target", target, ...extraArgs], { encoding: "utf8" });
}

function doctorAssertions(text) {
  return {
    heading: text.includes("Codex user-hook activation freshness"),
    sensor: text.includes("install-codex-hooks.mjs --check"),
    stale: text.includes("stale harness-owned hook file"),
    repair: text.includes("Repair by invoking `$harness-codex-activate`"),
    foreign: text.includes("do not overwrite a foreign hook file"),
  };
}

try {
  const install = runInstaller([]);
  record("install harness-owned fixture", install.status === 0, `exit=${install.status}`);

  const initialFresh = runInstaller(["--check"]);
  record("new fixture is fresh", initialFresh.status === 0, `exit=${initialFresh.status}`);

  const stale = JSON.parse(fs.readFileSync(target, "utf8"));
  const removedTarget = path.join(tempRoot, "removed-0.5.1", "hooks", "run.mjs").replaceAll("\\", "/");
  stale.hooks.PreToolUse[0].hooks[0].command = `node "${removedTarget}" --codex block-destructive`;
  fs.writeFileSync(target, `${JSON.stringify(stale, null, 2)}\n`, "utf8");
  record("stale fixture target is absent", !fs.existsSync(removedTarget), "removed cache path was never created");

  const staleCheck = runInstaller(["--check"]);
  const staleOutput = `${staleCheck.stderr}${staleCheck.stdout}`;
  record("stale harness-owned fixture fails closed", staleCheck.status !== 0 && staleOutput.includes("STALE"), `exit=${staleCheck.status}; verdict=STALE`);

  const refresh = runInstaller([]);
  record("reactivation refreshes stale fixture", refresh.status === 0, `exit=${refresh.status}`);
  const finalFresh = runInstaller(["--check"]);
  record("refreshed fixture is fresh", finalFresh.status === 0, `exit=${finalFresh.status}`);

  const doctor = fs.readFileSync(doctorFile, "utf8");
  const base = doctorAssertions(doctor);
  record("doctor carries all activation clauses", Object.values(base).every(Boolean), JSON.stringify(base));

  for (const twinTestFile of twinTestFiles) {
    const twin = doctorAssertions(fs.readFileSync(twinTestFile, "utf8"));
    record(
      `${path.basename(twinTestFile)} pins all activation clauses`,
      Object.values(twin).every(Boolean),
      JSON.stringify(twin),
    );
  }

  const noSensor = doctorAssertions(doctor.replace("install-codex-hooks.mjs --check", "sensor removed"));
  record("sensor-removal mutant is rejected", !noSensor.sensor, "sensor assertion changed true to false");
  const noRepair = doctorAssertions(doctor.replace("Repair by invoking `$harness-codex-activate`", "repair removed"));
  record("repair-removal mutant is rejected", !noRepair.repair, "repair assertion changed true to false");
  const noForeign = doctorAssertions(doctor.replace("do not overwrite a foreign hook file", "foreign rule removed"));
  record("foreign-ownership mutant is rejected", !noForeign.foreign, "foreign assertion changed true to false");

  const manifestFiles = ["plugin.json", ".codex-plugin/plugin.json", ".claude-plugin/plugin.json"];
  const versions = manifestFiles.map((relative) => JSON.parse(fs.readFileSync(path.join(pluginRoot, relative), "utf8")).version);
  record("plugin version surfaces agree at 0.5.2", versions.every((version) => version === "0.5.2"), versions.join(","));
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}

const failed = checks.filter((check) => !check.pass);
const result = {
  task: "CODEX-HOOK-ACTIVATION-RATCHET-001",
  modelCalls: 0,
  passed: checks.length - failed.length,
  failed: failed.length,
  checks,
};
fs.mkdirSync(outputDir, { recursive: true });
fs.writeFileSync(resultFile, `${JSON.stringify(result, null, 2)}\n`, "utf8");
console.log(`RESULT: ${result.passed} passed, ${result.failed} failed`);
process.exit(failed.length ? 1 : 0);
