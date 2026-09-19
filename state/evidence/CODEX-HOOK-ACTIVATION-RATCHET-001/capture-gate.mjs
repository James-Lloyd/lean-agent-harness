#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const evidenceDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(evidenceDir, "..", "..", "..");
const home = path.resolve(process.env.USERPROFILE || process.env.HOME || "");
const accountName = path.basename(home);
const outputFile = path.join(evidenceDir, "gate.txt");
const sweepFile = path.join(evidenceDir, "privacy-sweep.json");

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function flexiblePathPattern(value) {
  const normalized = value.replaceAll("\\", "/");
  const drivePath = /^([A-Za-z]):\/(.*)$/.exec(normalized);
  if (drivePath) {
    const tail = drivePath[2].split("/").filter(Boolean).map(escapeRegExp).join("[/\\\\]+");
    return new RegExp(`(?:${escapeRegExp(drivePath[1])}:|/${escapeRegExp(drivePath[1])})[/\\\\]+${tail}`, "gi");
  }
  const parts = normalized.split("/").filter(Boolean).map(escapeRegExp).join("[/\\\\]+");
  return new RegExp(`${normalized.startsWith("/") ? "[/\\\\]+" : ""}${parts}`, "gi");
}

const replacements = [
  [repoRoot, "<SOURCE>"],
  [home, "<HOME>"],
].filter(([needle]) => needle && needle !== ".")
  .sort((a, b) => b[0].length - a[0].length)
  .map(([needle, replacement]) => [flexiblePathPattern(needle), replacement]);
const userPathPattern = /(users)([/\\]+)([^/\\"'\s:*?<>|]+)/gi;

function scrub(value) {
  let text = String(value);
  for (const [pattern, replacement] of replacements) text = text.replace(pattern, replacement);
  return text
    .replace(userPathPattern, (_match, users, separator) => `${users}${separator}<user>`)
    .replace(/[ \t]+(?=\r?$)/gm, "");
}

function visit(directory, files = []) {
  for (const name of fs.readdirSync(directory)) {
    const candidate = path.join(directory, name);
    if (fs.statSync(candidate).isDirectory()) visit(candidate, files);
    else files.push(candidate);
  }
  return files;
}

const gate = spawnSync(process.execPath, [path.join(repoRoot, "harness", "tests", "gate.mjs")], {
  cwd: repoRoot,
  encoding: "utf8",
});
const scrubbed = scrub(`${gate.stdout || ""}${gate.stderr || ""}`);
if (scrub(scrubbed) !== scrubbed) throw new Error("gate evidence scrub is not idempotent");
fs.writeFileSync(outputFile, scrubbed, "utf8");

const accountBytes = Buffer.from(accountName.toLowerCase(), "utf8");
const matches = visit(evidenceDir)
  .filter((file) => file !== sweepFile)
  .filter((file) => Buffer.from(fs.readFileSync(file).toString("utf8").toLowerCase(), "utf8").includes(accountBytes));
if (matches.length) throw new Error(`private account name remains in ${matches.length} evidence file(s)`);

fs.writeFileSync(sweepFile, `${JSON.stringify({
  gateExit: gate.status,
  scrubIdempotent: true,
  binaryInclusiveAccountMatches: matches.length,
  filesScanned: visit(evidenceDir).filter((file) => file !== sweepFile).length,
}, null, 2)}\n`, "utf8");
console.log(`GATE CAPTURE: exit=${gate.status}; private-account matches=${matches.length}`);
process.exit(gate.status ?? 1);
