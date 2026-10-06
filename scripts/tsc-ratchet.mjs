#!/usr/bin/env node
// Type-check "ratchet".
//
// `tsc` currently reports 127 errors, almost all because src/types/database.ts is
// out of date (it lacks several tables and ~16 RPC functions the code calls).
// Making CI fail on all of them would just get CI ignored, so instead:
//
//   * tsc-baseline.json lists the errors that exist today.
//   * This script FAILS if there is any error that is not in the baseline
//     (a new one, or more of an existing kind), so the number can never grow.
//   * When errors are fixed, it tells you to tighten the baseline.
//
//   node scripts/tsc-ratchet.mjs            check (what CI runs)
//   node scripts/tsc-ratchet.mjs --update   rewrite the baseline to the current errors
//
// An error is identified by file + TS code + message, NOT line number, so moving
// code around does not make an old error look new.
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const baselinePath = join(root, 'tsc-baseline.json');
const update = process.argv.includes('--update');

const run = spawnSync('npx', ['--no-install', 'tsc', '-p', 'tsconfig.app.json', '--noEmit', '--pretty', 'false'], {
  cwd: root,
  encoding: 'utf8',
  maxBuffer: 64 * 1024 * 1024,
});
if (run.error) {
  console.error('Could not run tsc:', run.error.message);
  process.exit(2);
}

// "src/a/b.tsx(12,5): error TS2339: Property 'x' does not exist on type 'Y'."
// Continuation lines (indented) belong to the same error and are ignored.
const re = /^(.+?)\(\d+,\d+\): error (TS\d+): (.*)$/;
const current = {};
let unparsed = 0;
for (const line of run.stdout.split('\n')) {
  if (!line || /^\s/.test(line)) continue;
  const m = re.exec(line);
  if (!m) {
    if (line.includes('error TS')) unparsed++;
    continue;
  }
  const key = `${m[1]} | ${m[2]} | ${m[3]}`;
  current[key] = (current[key] ?? 0) + 1;
}
if (unparsed > 0) {
  console.error(`Found ${unparsed} tsc error line(s) in a format this script does not understand. Refusing to guess.`);
  process.exit(2);
}
if (run.status !== 0 && Object.keys(current).length === 0) {
  console.error('tsc failed without reporting any error this script can read:\n' + run.stdout + run.stderr);
  process.exit(2);
}

const total = (o) => Object.values(o).reduce((a, b) => a + b, 0);

if (update) {
  const sorted = Object.fromEntries(Object.entries(current).sort(([a], [b]) => a.localeCompare(b)));
  writeFileSync(baselinePath, JSON.stringify(sorted, null, 2) + '\n');
  console.log(`Baseline written: ${total(sorted)} known type error(s) in ${Object.keys(sorted).length} distinct form(s).`);
  process.exit(0);
}

if (!existsSync(baselinePath)) {
  console.error('tsc-baseline.json is missing. Create it with:  node scripts/tsc-ratchet.mjs --update');
  process.exit(2);
}
const baseline = JSON.parse(readFileSync(baselinePath, 'utf8'));

const added = [];
for (const [key, n] of Object.entries(current)) {
  const allowed = baseline[key] ?? 0;
  if (n > allowed) added.push(`  + ${key}${allowed ? `   (${n} now, ${allowed} allowed)` : ''}`);
}
const fixed = [];
for (const [key, n] of Object.entries(baseline)) {
  const now = current[key] ?? 0;
  if (now < n) fixed.push(`  - ${key}${now ? `   (${now} now, ${n} in baseline)` : ''}`);
}

console.log(`Type errors: ${total(current)} now, ${total(baseline)} allowed by the baseline.`);

if (added.length > 0) {
  console.error(`\nFAIL: ${added.length} NEW type error(s) that are not in tsc-baseline.json:\n${added.join('\n')}`);
  console.error('\nFix them. (If one is genuinely unavoidable, run `node scripts/tsc-ratchet.mjs --update` and say why in the PR.)');
  process.exit(1);
}
if (fixed.length > 0) {
  console.log(`\nNice: ${fixed.length} baseline error(s) are gone. Tighten the baseline so they cannot come back:`);
  console.log('  node scripts/tsc-ratchet.mjs --update');
}
console.log('OK: no new type errors.');
