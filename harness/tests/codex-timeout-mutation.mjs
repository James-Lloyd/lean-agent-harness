#!/usr/bin/env node
/*
 * Mutation proof for the timeout transcript contract. Each mutant keeps the watchdog verdict but
 * discards output produced before it, recreating the original failure independently in each twin.
 * Positive controls must pass; mutants must fail specifically on the missing early marker.
 */
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const args = process.argv.slice(2);
const outAt = args.indexOf("--out");
const temporary = outAt < 0;
const out = temporary ? fs.mkdtempSync(path.join(os.tmpdir(), "codex-timeout-mutation-")) : path.resolve(args[outAt + 1]);
fs.mkdirSync(out, { recursive: true });

const psOriginal = path.join(root, "plugin/engine/lib/invoke-codex.ps1");
const shOriginal = path.join(root, "plugin/engine/lib/invoke-codex.sh");
const psMutant = path.join(out, "invoke-codex.mutant.ps1");
const shMutant = path.join(out, "invoke-codex.mutant.sh");

function replaceOnce(text, needle, replacement, label) {
  const at = text.indexOf(needle);
  if (at < 0 || text.indexOf(needle, at + needle.length) >= 0) throw new Error(`${label}: mutation anchor missing or ambiguous`);
  return text.slice(0, at) + replacement + text.slice(at + needle.length);
}

const psNeedle = `      Get-Content -LiteralPath $pf -Raw | & $cmd @argList 2>&1 | ForEach-Object {\n        $writer.WriteLine("$_")\n        $writer.Flush()\n      }\n`;
const psText = replaceOnce(
  fs.readFileSync(psOriginal, "utf8").replaceAll("\r\n", "\n"),
  psNeedle,
  `      Get-Content -LiteralPath $pf -Raw | & $cmd @argList 2>&1 | ForEach-Object {\n        # MUTANT: delay/discard the live record instead of crossing the job boundary.\n        $null = "$_"\n      }\n`,
  "PowerShell",
);
fs.writeFileSync(psMutant, psText, "utf8");

const shNeedle = `    printf '%s' "$prompt" | timeout "$tmo" "$cmd" "\${args[@]}" > "$log" 2>&1; rc=$?`;
const shText = replaceOnce(
  fs.readFileSync(shOriginal, "utf8"),
  shNeedle,
  `    printf '%s' "$prompt" | timeout "$tmo" "$cmd" "\${args[@]}" > /dev/null 2>&1; rc=$?`,
  "Bash",
);
fs.writeFileSync(shMutant, shText, { encoding: "utf8", mode: 0o755 });

function findBash() {
  if (process.platform !== "win32") return "bash";
  const candidates = [
    path.join(process.env.ProgramFiles || "C:\\Program Files", "Git/bin/bash.exe"),
    path.join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "Git/bin/bash.exe"),
    path.join(process.env.LOCALAPPDATA || "", "Programs/Git/bin/bash.exe"),
  ];
  return candidates.find((candidate) => fs.existsSync(candidate)) || "bash";
}
function msys(value) {
  if (process.platform !== "win32") return value;
  return value.replace(/^([A-Za-z]):[\\/]/, (_, drive) => `/${drive.toLowerCase()}/`).replaceAll("\\", "/");
}
function run(name, command, commandArgs, env = process.env) {
  const result = spawnSync(command, commandArgs, { cwd: root, env, encoding: "utf8", timeout: 120_000 });
  const text = `${result.stdout || ""}${result.stderr || ""}`;
  fs.writeFileSync(path.join(out, `${name}.log`), `${text}\nEXIT_CODE=${result.status}\n`, "utf8");
  return { name, status: result.status, signal: result.signal, text };
}

const powershell = process.platform === "win32" ? "powershell" : "pwsh";
const bash = findBash();
const psTest = path.join(here, "codex-timeout-test.ps1");
const shTest = msys(path.join(here, "codex-timeout-test.sh"));
const shEnv = { ...process.env, CODEX_TIMEOUT_TEST_TIMEOUT_ONLY: "1" };
const results = [
  run("powershell-control", powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", psTest, "-InvokeLib", psOriginal, "-TimeoutOnly"]),
  run("powershell-mutant", powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", psTest, "-InvokeLib", psMutant, "-TimeoutOnly"]),
  run("bash-control", bash, [shTest, msys(shOriginal)], shEnv),
  run("bash-mutant", bash, [shTest, msys(shMutant)], shEnv),
];
const packageValidation = run("package-validation", process.execPath, [path.join(root, "plugin/scripts/validate-openai-plugin.mjs")]);
const manifestVersions = Object.fromEntries([
  "plugin/plugin.json",
  "plugin/.claude-plugin/plugin.json",
  "plugin/.codex-plugin/plugin.json",
].map((relative) => [relative, JSON.parse(fs.readFileSync(path.join(root, relative), "utf8")).version]));

const byName = Object.fromEntries(results.map((result) => [result.name, result]));
const expectedFailure = "FAIL timeout log keeps partial-before-timeout";
const checks = {
  powershellControlPassed: byName["powershell-control"].status === 0,
  powershellMutantRejected: byName["powershell-mutant"].status !== 0 && byName["powershell-mutant"].text.includes(expectedFailure),
  bashControlPassed: byName["bash-control"].status === 0,
  bashMutantRejected: byName["bash-mutant"].status !== 0 && byName["bash-mutant"].text.includes(expectedFailure),
  packageValidationPassed: packageValidation.status === 0,
  manifestVersionsAgree: new Set(Object.values(manifestVersions)).size === 1,
};
const summary = { task: "CODEX-TIMEOUT-TRANSCRIPT-001", mutation: "discard pre-timeout transcript", checks,
  runs: results.map(({ name, status, signal }) => ({ name, status, signal })), manifestVersions };
fs.writeFileSync(path.join(out, "result.json"), `${JSON.stringify(summary, null, 2)}\n`, "utf8");
console.log(JSON.stringify(summary, null, 2));
if (!Object.values(checks).every(Boolean)) process.exitCode = 1;
