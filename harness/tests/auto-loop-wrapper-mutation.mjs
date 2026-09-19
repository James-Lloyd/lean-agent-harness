#!/usr/bin/env node
// Proves the no-commit stop is load-bearing by removing it independently from both loop twins.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const args = process.argv.slice(2); const outAt = args.indexOf("--out");
const temporary = outAt < 0;
const out = temporary ? fs.mkdtempSync(path.join(os.tmpdir(), "auto-loop-mutation-")) : path.resolve(args[outAt + 1]);
fs.mkdirSync(out, { recursive: true });
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "auto-loop-mutant-engine-"));
process.on("exit", () => fs.rmSync(scratch, { recursive: true, force: true }));
const mutant = path.join(scratch, "engine");
fs.cpSync(path.join(root, "plugin/engine"), mutant, { recursive: true });

function replaceOnce(file, needle) {
  const text = fs.readFileSync(file, "utf8"); const at = text.indexOf(needle);
  if (at < 0 || text.indexOf(needle, at + needle.length) >= 0) throw new Error(`mutation anchor missing or ambiguous: ${file}`);
  fs.writeFileSync(file, text.slice(0, at) + text.slice(at + needle.length), "utf8");
}
replaceOnce(path.join(mutant, "loop.ps1"), `    if (-not $commitOnGreen) {
      # A later checkpoint is necessarily based on the same HEAD. If a later iteration fails and rolls
      # back, it would erase this accepted-but-uncommitted green work. One green iteration is therefore
      # the only safe run boundary when commits are disabled, regardless of maxIterations.
      Write-Host "STOP: commitOnGreen=false - preserving the green uncommitted changes and stopping before another iteration." -ForegroundColor Yellow
      break
    }
`);
replaceOnce(path.join(mutant, "loop.sh"), `    if [ "$(cfg '.loop.commitOnGreen')" != "true" ]; then
      # A later checkpoint shares this HEAD; rolling it back would erase accepted uncommitted work.
      # Preserve the green tree by making the first green result the run boundary.
      echo "STOP: commitOnGreen=false - preserving the green uncommitted changes and stopping before another iteration."
      break
    fi
`);

function findBash() {
  if (process.platform !== "win32") return "bash";
  return [path.join(process.env.ProgramFiles || "C:\\Program Files", "Git/bin/bash.exe"), path.join(process.env.LOCALAPPDATA || "", "Programs/Git/bin/bash.exe")].find(fs.existsSync) || "bash";
}
function msys(value) { return process.platform === "win32" ? value.replace(/^([A-Za-z]):[\\/]/, (_, d) => `/${d.toLowerCase()}/`).replaceAll(path.win32.sep, "/") : value; }
function run(name, command, commandArgs, env = process.env) {
  const result = spawnSync(command, commandArgs, { cwd: root, env, encoding: "utf8", timeout: 120_000 });
  const text = `${result.stdout || ""}${result.stderr || ""}`;
  fs.writeFileSync(path.join(out, `${name}.log`), `${text}\nEXIT_CODE=${result.status}\n`, "utf8");
  return { name, status: result.status, text };
}
const powershell = process.platform === "win32" ? "powershell" : "pwsh"; const bash = findBash();
const psTest = path.join(here, "auto-loop-wrapper-test.ps1"); const shTest = msys(path.join(here, "auto-loop-wrapper-test.sh"));
const runs = [
  run("powershell-control", powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", psTest]),
  run("powershell-mutant", powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", psTest, "-Engine", mutant]),
  run("bash-control", bash, [shTest]),
  run("bash-mutant", bash, [shTest], { ...process.env, HARNESS_TEST_ENGINE: msys(mutant) }),
];
const byName = Object.fromEntries(runs.map((run) => [run.name, run]));
const rejected = (run) => run.status !== 0 && run.text.includes("FAIL no-commit loop invokes the model exactly once") && run.text.includes("FAIL first green uncommitted change survives");
const checks = {
  powershellControlPassed: byName["powershell-control"].status === 0,
  powershellMutantRejected: rejected(byName["powershell-mutant"]),
  bashControlPassed: byName["bash-control"].status === 0,
  bashMutantRejected: rejected(byName["bash-mutant"]),
};
const summary = { task: "HARNESS-053-AUTO-WRAPPERS", mutation: "remove the no-commit green stop", checks, runs: runs.map(({ name, status }) => ({ name, status })) };
fs.writeFileSync(path.join(out, "result.json"), `${JSON.stringify(summary, null, 2)}\n`, "utf8");
console.log(JSON.stringify(summary, null, 2));
if (!Object.values(checks).every(Boolean)) process.exitCode = 1;
