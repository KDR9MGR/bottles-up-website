import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// The app calls database functions by name and by argument name. Nothing else checks those against the SQL, so a typo
// would only surface at runtime, for a real person. This reads both sides and compares them: every function the app
// calls must exist in the migrations, every argument must be one the function declares, and every argument the function
// requires (no default) must be passed.

const ROOT = join(__dirname, '..', '..');
const migrations = readdirSync(join(ROOT, 'supabase', 'migrations')).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(join(ROOT, 'supabase', 'migrations', f), 'utf8')).join('\n');

interface Param { name: string; required: boolean }

/** Splits "a int, b text default 'x,y'" on top-level commas only. */
function splitTopLevel(list: string): string[] {
  const parts: string[] = [];
  let depth = 0; let quote = false; let cur = '';
  for (const ch of list) {
    if (ch === "'") quote = !quote;
    if (!quote) {
      if (ch === '(' || ch === '[') depth++;
      if (ch === ')' || ch === ']') depth--;
      if (ch === ',' && depth === 0) { parts.push(cur); cur = ''; continue; }
    }
    cur += ch;
  }
  if (cur.trim()) parts.push(cur);
  return parts.map((p) => p.trim()).filter(Boolean);
}

function definedFunctions(sql: string): Map<string, Param[]> {
  const out = new Map<string, Param[]>();
  const re = /create (?:or replace )?function public\.(\w+)\s*\(([\s\S]*?)\)\s*(?:returns|language)/gi;
  for (const m of sql.matchAll(re)) {
    const params = splitTopLevel(m[2]).map((p) => {
      const name = /^(\w+)/.exec(p)?.[1] ?? '';
      return { name, required: !/\bdefault\b/i.test(p) };
    }).filter((p) => p.name.startsWith('p_'));
    out.set(m[1], params);
  }
  return out;
}

interface Call { fn: string; args: string[]; file: string }

function callsIn(file: string): Call[] {
  const src = readFileSync(join(ROOT, file), 'utf8');
  const calls: Call[] = [];
  // call('name', { ... })  /  call<T>('name', { ... })  /  db.rpc('name', { ... })  /  rpc('name', { ... })
  // The generic part may itself contain <...> (call<Record<string, unknown>[] | null>(...)), so it is matched up to ">(".
  const re = /\b(?:call|rpc|safeRows)(?:<[^(]*>)?\(\s*'(\w+)'\s*(?:,\s*\{([\s\S]*?)\}\s*)?\)/g;
  for (const m of src.matchAll(re)) {
    const args = [...(m[2] ?? '').matchAll(/\b(p_\w+)\s*:/g)].map((a) => a[1]);
    calls.push({ fn: m[1], args, file });
  }
  return calls;
}

const defined = definedFunctions(migrations);
const FILES = ['src/lib/account.ts', 'src/lib/venueSetupApi.ts', 'supabase/functions/_shared/teamInvitation.ts'];
const calls = FILES.flatMap(callsIn);

describe('the app and the database agree on every function call', () => {
  it('finds the calls and the definitions it is checking (so this test cannot pass by checking nothing)', () => {
    expect(defined.size).toBeGreaterThan(30);
    expect(calls.map((c) => c.fn)).toEqual(expect.arrayContaining(['invite_member', 'reserve_invitation_email', 'save_my_profile', 'list_team', 'my_workspaces']));
  });

  // An independent cross-check on the pattern above: any quoted name that is a real database function and appears in
  // these files must have been picked up as a call. If the pattern ever misses a call style, this fails loudly instead
  // of that call quietly going unchecked.
  it('does not skip any call: every quoted database function name in these files was checked', () => {
    const found = new Set(calls.map((c) => c.fn));
    const missed: string[] = [];
    for (const file of FILES) {
      const src = readFileSync(join(ROOT, file), 'utf8');
      for (const m of src.matchAll(/'([a-z][a-z0-9_]+)'/g)) {
        if (defined.has(m[1]) && !found.has(m[1])) missed.push(`${m[1]} (${file})`);
      }
    }
    expect(missed).toEqual([]);
  });

  // Functions the app calls that predate these migrations or live only in production are named here explicitly, so a
  // new unknown name fails instead of being waved through.
  const KNOWN_ELSEWHERE = new Set<string>([]);

  for (const c of calls) {
    it(`${c.fn}(${c.args.join(', ')}) matches its definition`, () => {
      if (KNOWN_ELSEWHERE.has(c.fn)) return;
      const params = defined.get(c.fn);
      expect(params, `${c.fn} is called in ${c.file} but no migration defines it`).toBeDefined();
      const names = (params ?? []).map((p) => p.name);
      for (const a of c.args) expect(names, `${c.fn} has no argument ${a}`).toContain(a);
      for (const p of params ?? []) {
        if (p.required) expect(c.args, `${c.fn} requires ${p.name} but the call does not pass it`).toContain(p.name);
      }
    });
  }
});
