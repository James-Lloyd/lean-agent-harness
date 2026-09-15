#!/usr/bin/env node

import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const patterns = [
  [/\/tmp\/harness-headless-(?:pre|post)-[^/\s]+/gi, '<TMP>'],
  [/[ \t]+(?=\r?$)/gm, ''],
];
let changed = 0;

function visit(path) {
  for (const name of readdirSync(path)) {
    const candidate = join(path, name);
    if (statSync(candidate).isDirectory()) {
      visit(candidate);
      continue;
    }
    if (resolve(candidate) === resolve(fileURLToPath(import.meta.url))) continue;
    const before = readFileSync(candidate, 'utf8');
    let after = before;
    for (const [pattern, replacement] of patterns) after = after.replace(pattern, replacement);
    if (after !== before) {
      writeFileSync(candidate, after, 'utf8');
      changed++;
    }
  }
}

visit(root);
console.log(`sanitized ${changed} evidence file(s)`);
