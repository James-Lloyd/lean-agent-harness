#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const pluginRoot = path.dirname(scriptDir);
const repoRoot = path.dirname(pluginRoot);
const failures = [];

function readJson(relative) {
  const absolute = path.join(repoRoot, relative);
  try {
    return JSON.parse(fs.readFileSync(absolute, "utf8"));
  } catch (error) {
    failures.push(`${relative}: ${error.message}`);
    return {};
  }
}

function check(condition, message) {
  if (!condition) failures.push(message);
}

const portable = readJson("plugin/plugin.json");
const codex = readJson("plugin/.codex-plugin/plugin.json");
const claude = readJson("plugin/.claude-plugin/plugin.json");
const marketplace = readJson(".agents/plugins/marketplace.json");
const claudeMarketplace = readJson(".claude-plugin/marketplace.json");
const hooks = readJson("plugin/hooks/hooks.json");
const claudeHooks = readJson("plugin/hooks/claude-hooks.json");

check(portable.name === "lean-agent-harness", "portable manifest has the wrong name");
check(portable.$schema === "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json", "portable manifest schema is not pinned");
check(codex.skills === "./skills/", "Codex compatibility manifest does not expose plugin skills");
check(claude.hooks === "./hooks/claude-hooks.json", "Claude manifest does not select the Claude hook manifest");
check(portable.version === codex.version && codex.version === claude.version, "host manifest versions differ");
const marketplaceEntry = marketplace.plugins?.find((entry) => entry.name === portable.name);
check(marketplaceEntry?.source?.source === "local" && marketplaceEntry.source.path === "./plugin", "Codex marketplace does not publish ./plugin");
check(marketplaceEntry?.policy?.installation === "AVAILABLE" && marketplaceEntry.policy.authentication === "ON_INSTALL", "Codex marketplace policy is incomplete");
check(claudeMarketplace.plugins?.some((entry) => entry.name === portable.name && entry.source === "./plugin"), "Claude marketplace does not publish ./plugin");

const allowedEvents = new Set(["PreToolUse", "PostToolUse", "SessionStart"]);
const events = Object.keys(hooks.hooks ?? {});
check(events.length === allowedEvents.size && events.every((event) => allowedEvents.has(event)), "Codex hook manifest has unsupported or missing events");
const hookCommands = events.flatMap((event) => hooks.hooks[event] ?? []).flatMap((group) => group.hooks ?? []).map((hook) => hook.command);
check(hookCommands.length === 4, "Codex hook manifest should contain four commands");
check(Object.hasOwn(claudeHooks.hooks ?? {}, "ConfigChange"), "Claude hook manifest lost ConfigChange");
check(hooks.hooks?.PreToolUse?.[0]?.matcher === "Bash", "destructive-command guard must match only Bash");
check(hooks.hooks?.PreToolUse?.[1]?.matcher === "apply_patch|Edit|Write", "spec guard must match only edit tools");
check(hooks.hooks?.PostToolUse?.[0]?.matcher === "apply_patch|Edit|Write", "fast gate must match only edit tools");
check(hookCommands.every((command) => command?.includes("${PLUGIN_ROOT}/hooks/run.mjs") && command.includes(" --codex ")), "Codex hook commands must use PLUGIN_ROOT and the Codex denial adapter");
for (const name of ["block-destructive", "protect-specs", "format-and-check", "session-start"]) {
  check(hookCommands.filter((command) => command?.endsWith(name)).length === 1, `Codex hook ${name} is missing or duplicated`);
}

const agentMap = fs.readFileSync(path.join(repoRoot, "AGENTS.md"), "utf8");
check(Buffer.byteLength(agentMap, "utf8") <= 32 * 1024, "root AGENTS.md exceeds Codex's default 32 KiB instruction budget");
check(agentMap.split(/\r?\n/).length <= 100, "root AGENTS.md exceeds its 100-line navigation-map budget");

const skillRoot = path.join(pluginRoot, "skills");
const skillNames = fs.readdirSync(skillRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && fs.existsSync(path.join(skillRoot, entry.name, "SKILL.md")))
  .map((entry) => entry.name)
  .sort();
const commandSkillNames = skillNames.filter((name) => name.startsWith("harness-") && name !== "harness-codex-activate");
check(skillNames.length === 21, `plugin should expose 21 discoverable skills, found ${skillNames.length}`);
check(commandSkillNames.length === 14 && skillNames.includes("harness-codex-activate"), "plugin should expose 14 command adapters plus the Codex activation entry point");
const initCommand = fs.readFileSync(path.join(pluginRoot, "commands", "harness-init.md"), "utf8");
const codexAdapter = fs.readFileSync(path.join(pluginRoot, "references", "codex-command-adapter.md"), "utf8");
check(initCommand.includes("loaded as the installed") && initCommand.includes("Codex `harness-init` skill") && initCommand.includes("do not invoke `claude`"), "harness-init lacks an explicit Codex-only plugin-mode branch");
check(codexAdapter.includes("Do not invoke Claude to rediscover this plugin"), "Codex adapter does not neutralize Claude-only host detection");

const sync = spawnSync(process.execPath, [path.join(scriptDir, "sync-command-skills.mjs"), "--check"], { encoding: "utf8" });
check(sync.status === 0, `command skill synchronization failed: ${(sync.stderr || sync.stdout).trim()}`);

for (const wrapper of ["loop.ps1", "loop.sh", "fleet.ps1", "fleet.sh", "codex-setup.ps1", "codex-setup.sh"]) {
  const shipped = fs.readFileSync(path.join(pluginRoot, "engine", "wrappers", wrapper), "utf8");
  const project = fs.readFileSync(path.join(repoRoot, "harness", wrapper), "utf8");
  check(shipped === project, `project wrapper differs from shipped ${wrapper}`);
  check(shipped.includes(".codex/plugins/cache"), `${wrapper} does not discover the Codex plugin cache`);
}

const cacheFixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), "harness-codex-cache-"));
try {
  const fakeHome = path.join(cacheFixtureDir, "home");
  const consumer = path.join(cacheFixtureDir, "consumer");
  const consumerHarness = path.join(consumer, "harness");
  const fakeEngine = path.join(fakeHome, ".codex", "plugins", "cache", "lean-agent-harness", "lean-agent-harness", codex.version, "engine");
  const invocationLog = path.join(cacheFixtureDir, "invocations.txt");
  fs.mkdirSync(consumerHarness, { recursive: true });
  fs.mkdirSync(fakeEngine, { recursive: true });
  const fixtureEnv = { ...process.env, HOME: fakeHome, USERPROFILE: fakeHome, HARNESS_CACHE_FIXTURE_LOG: invocationLog };
  delete fixtureEnv.HARNESS_ENGINE;
  delete fixtureEnv.CLAUDE_PLUGIN_ROOT;
  const baseNames = ["loop", "fleet", "codex-setup"];
  if (process.platform === "win32") {
    const fakePs = 'param([string]$ProjectRoot, [Parameter(ValueFromRemainingArguments=$true)]$Rest)\n[IO.File]::AppendAllText($env:HARNESS_CACHE_FIXTURE_LOG, "$($MyInvocation.MyCommand.Name)|$ProjectRoot`n")\n';
    for (const name of baseNames) {
      fs.writeFileSync(path.join(fakeEngine, `${name}.ps1`), fakePs, "utf8");
      fs.copyFileSync(path.join(pluginRoot, "engine", "wrappers", `${name}.ps1`), path.join(consumerHarness, `${name}.ps1`));
      const run = spawnSync("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(consumerHarness, `${name}.ps1`)], { env: fixtureEnv, encoding: "utf8" });
      check(run.status === 0, `Codex-cache-only ${name}.ps1 wrapper failed: ${(run.stderr || run.stdout).trim()}`);
    }
  } else {
    const fakeSh = `#!/usr/bin/env bash\nprintf '%s|%s\\n' "$(basename "$0")" "$2" >> "$HARNESS_CACHE_FIXTURE_LOG"\n`;
    for (const name of baseNames) {
      const engineFile = path.join(fakeEngine, `${name}.sh`);
      fs.writeFileSync(engineFile, fakeSh, { encoding: "utf8", mode: 0o755 });
      fs.copyFileSync(path.join(pluginRoot, "engine", "wrappers", `${name}.sh`), path.join(consumerHarness, `${name}.sh`));
      const run = spawnSync("bash", [path.join(consumerHarness, `${name}.sh`)], { env: fixtureEnv, encoding: "utf8" });
      check(run.status === 0, `Codex-cache-only ${name}.sh wrapper failed: ${(run.stderr || run.stdout).trim()}`);
    }
  }
  const invocations = fs.existsSync(invocationLog) ? fs.readFileSync(invocationLog, "utf8") : "";
  const invocationRecords = invocations.trim().split(/\r?\n/).filter(Boolean).map((line) => {
    const separator = line.indexOf("|");
    return separator >= 0 ? [line.slice(0, separator), line.slice(separator + 1)] : [line, ""];
  });
  const comparablePath = (value) => {
    const normalized = path.resolve(value);
    return process.platform === "win32" ? normalized.toLowerCase() : normalized;
  };
  const expectedExtension = process.platform === "win32" ? ".ps1" : ".sh";
  check(
    invocationRecords.length === baseNames.length
      && baseNames.every((name) => invocationRecords.some(([script]) => script === `${name}${expectedExtension}`))
      && invocationRecords.every(([, projectRoot]) => comparablePath(projectRoot) === comparablePath(consumer)),
    `Codex-cache-only wrappers did not invoke the installed engine with the consumer root: ${JSON.stringify(invocationRecords)}`,
  );
} finally {
  fs.rmSync(cacheFixtureDir, { recursive: true, force: true });
}

const activationDir = fs.mkdtempSync(path.join(os.tmpdir(), "harness-codex-activation-"));
const activationTarget = path.join(activationDir, "hooks.json");
try {
  const installer = path.join(scriptDir, "install-codex-hooks.mjs");
  const install = spawnSync(process.execPath, [installer, "--target", activationTarget], { encoding: "utf8" });
  check(install.status === 0, `Codex hook activation failed: ${(install.stderr || install.stdout).trim()}`);
  if (fs.existsSync(activationTarget)) {
    const installed = JSON.parse(fs.readFileSync(activationTarget, "utf8"));
    check(installed.description === "Lean Agent Harness user hooks for Codex (managed by harness-codex-activate).", "activated Codex hooks lack the ownership description");
    check(!Object.hasOwn(installed, "_generated_by"), "activated Codex hooks contain an unsupported top-level marker");
    const activatedCommands = Object.values(installed.hooks ?? {}).flat().flatMap((group) => group.hooks ?? []).map((hook) => hook.command);
    check(activatedCommands.length === 4 && activatedCommands.every((command) => !command.includes("${PLUGIN_ROOT}") && command.includes("/hooks/run.mjs") && command.includes(" --codex ")), "activated Codex hooks do not resolve the installed plugin root");
  }
  const freshness = spawnSync(process.execPath, [installer, "--target", activationTarget, "--check"], { encoding: "utf8" });
  check(freshness.status === 0, `Codex hook activation freshness check failed: ${(freshness.stderr || freshness.stdout).trim()}`);
  const foreign = '{"_generated_by":"another-tool","hooks":{}}\n';
  fs.writeFileSync(activationTarget, foreign, "utf8");
  const refusal = spawnSync(process.execPath, [installer, "--target", activationTarget], { encoding: "utf8" });
  check(refusal.status !== 0 && fs.readFileSync(activationTarget, "utf8") === foreign, "Codex hook activation overwrote a foreign _generated_by marker");
  for (const owned of [
    { _generated_by: "GENERATED by lean-agent-harness codex-setup (plugin 0.4.9). Do not edit" },
    { description: "GENERATED by lean-agent-harness codex-setup (plugin 0.5.0). Do not edit" },
  ]) {
    fs.writeFileSync(activationTarget, `${JSON.stringify({ ...owned, hooks: {} })}\n`, "utf8");
    const migration = spawnSync(process.execPath, [installer, "--target", activationTarget], { encoding: "utf8" });
    check(migration.status === 0, `Codex hook activation could not migrate a harness generator marker: ${(migration.stderr || migration.stdout).trim()}`);
  }
} finally {
  fs.rmSync(activationDir, { recursive: true, force: true });
}

if (failures.length) {
  console.error(failures.map((failure) => `FAIL: ${failure}`).join("\n"));
  process.exit(1);
}

console.log(`OpenAI plugin package is consistent: ${codex.version}, ${hookCommands.length} hooks, ${skillNames.length} discoverable skills (${commandSkillNames.length + 1} Codex entry points), 6 dual-cache wrappers with cache-only execution, activation fallback, ${Buffer.byteLength(agentMap, "utf8")} byte AGENTS.md`);
