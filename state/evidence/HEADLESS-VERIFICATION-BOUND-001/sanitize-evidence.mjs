#!/usr/bin/env node

import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const sourceRoot = resolve(root, '..', '..', '..');
const home = resolve(process.env.USERPROFILE || process.env.HOME || '');

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function flexiblePathPattern(value) {
  const normalized = value.replaceAll('\\', '/');
  const drivePath = /^([A-Za-z]):\/(.*)$/.exec(normalized);
  if (drivePath) {
    const tail = drivePath[2].split('/').filter(Boolean).map(escapeRegExp).join('[/\\\\]+');
    return new RegExp(`(?:${escapeRegExp(drivePath[1])}:|/${escapeRegExp(drivePath[1])})[/\\\\]+${tail}`, 'gi');
  }
  const parts = normalized.split('/').filter(Boolean).map(escapeRegExp).join('[/\\\\]+');
  return new RegExp(`${normalized.startsWith('/') ? '[/\\\\]+' : ''}${parts}`, 'gi');
}

const pathReplacements = [
  [sourceRoot, '<SOURCE>'],
  [home, '<HOME>'],
].filter(([needle]) => needle && needle !== '.')
  .sort((a, b) => b[0].length - a[0].length)
  .map(([needle, replacement]) => [flexiblePathPattern(needle), replacement]);
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
    for (const [pattern, replacement] of pathReplacements) after = after.replace(pattern, replacement);
    for (const [pattern, replacement] of patterns) after = after.replace(pattern, replacement);
    if (after !== before) {
      writeFileSync(candidate, after, 'utf8');
      changed++;
    }
  }
}

visit(root);
console.log(`sanitized ${changed} evidence file(s)`);
