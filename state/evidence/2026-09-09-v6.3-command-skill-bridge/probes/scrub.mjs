#!/usr/bin/env node
/*
 * scrub.mjs — strip the OS username out of captured evidence, in EVERY escaping the tools emit.
 *
 * AGENTS.md 2026-09-07: a real username reached a commit in a public repo because the scrubber (and
 * the pre-commit denylist behind it) only knew one separator form. Codex, node, and PowerShell all
 * print paths JSON-escaped somewhere, so `Users\\<name>` matches neither a single-separator rule nor
 * a character class that consumes exactly one separator. Hence `[/\\]+` here, and hence this runs
 * from the probes themselves — a scrub the author has to remember at commit time is not a scrub.
 *
 *   node scrub.mjs <file>...
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

// `Users` + one-or-more separators of any flavour + the account name. Stops at a separator, a quote
// or whitespace so only the name is replaced. Case-insensitive: cmd.exe prints `USERS` sometimes.
const USER_RE = /(users)([/\\]+)([^/\\"'\s:*?<>|]+)/gi;

let changed = 0;
for (const f of process.argv.slice(2)) {
  if (!existsSync(f)) continue;
  const before = readFileSync(f, 'utf8');
  const after = before.replace(USER_RE, (_m, u, sep, _name) => `${u}${sep}<user>`);
  if (after !== before) { writeFileSync(f, after); changed++; }
}
console.log(`scrub: ${changed} file(s) rewritten`);
