import { beforeAll, describe, expect, it } from 'vitest';
import bcrypt from 'bcryptjs';
import { validateTierAccessCode } from '../../supabase/functions/_shared/tierAccessCode.ts';
import { createFakeDb } from './stubs/fakeDb';

let hash: string;
beforeAll(() => {
  // 4 rounds keeps the test fast; the code under test only calls compareSync.
  hash = bcrypt.hashSync('DOOR2026', 4);
});

const run = (code: string | null | undefined, rows = [{ tier_id: 't1', code_hash: '' }]) => {
  const db = createFakeDb({ ticket_tier_access_codes: rows.map((r) => ({ ...r, code_hash: r.code_hash || hash })) });
  return validateTierAccessCode(db.client, 't1', code);
};

describe('validateTierAccessCode (gated ticket tiers)', () => {
  it('accepts the right code', async () => {
    expect(await run('DOOR2026')).toEqual({ valid: true, message: 'Access code accepted' });
  });
  it('ignores spaces around what was typed', async () => {
    expect((await run('  DOOR2026  ')).valid).toBe(true);
  });
  it('is case-sensitive: a different case is a different code', async () => {
    expect(await run('door2026')).toEqual({ valid: false, message: 'Incorrect access code' });
  });
  it('rejects a wrong code', async () => {
    expect(await run('NOPE')).toEqual({ valid: false, message: 'Incorrect access code' });
  });
  it('rejects empty, blank, null and undefined without checking the hash', async () => {
    for (const v of ['', '   ', null, undefined]) {
      expect(await run(v as any)).toEqual({ valid: false, message: 'Enter the access code' });
    }
  });
  it('a tier with no code configured cannot be unlocked by any code', async () => {
    expect(await run('DOOR2026', [])).toEqual({ valid: false, message: 'This ticket type has no access code configured' });
  });
  it('only a different tier\'s code exists: still not unlockable', async () => {
    const db = createFakeDb({ ticket_tier_access_codes: [{ tier_id: 'other', code_hash: hash }] });
    expect((await validateTierAccessCode(db.client, 't1', 'DOOR2026')).valid).toBe(false);
  });
});
