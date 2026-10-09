import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { AccountError, friendlyMessage } from './account';
import { cancelBusinessSteps, CLEARED_BUSINESS_INTENT, confirmCancelBusiness, runCancelBusiness } from './cancelBusiness';
import { supabase } from './supabase';
import { parseSignupIntent } from './accountRouting';

function steps(log: string[], over: { cancel?: () => Promise<void>; clear?: () => Promise<void>; refresh?: () => Promise<unknown> } = {}) {
  return {
    cancel: over.cancel ?? (async () => { log.push('cancel'); }),
    clearBusinessIntent: over.clear ?? (async () => { log.push('clear intent'); }),
    refresh: over.refresh ?? (async () => { log.push('refresh'); }),
  };
}

describe('cancelling a business', () => {
  it('cancels first, then forgets the business sign-up, then reads what the person can open', async () => {
    const log: string[] = [];
    await runCancelBusiness('o1', steps(log));
    expect(log).toEqual(['cancel', 'clear intent', 'refresh']);
  });

  it('asks the database to cancel the business it was given', async () => {
    const asked: string[] = [];
    await runCancelBusiness('org-42', { ...steps([]), cancel: async (id: string) => { asked.push(id); } });
    expect(asked).toEqual(['org-42']);
  });

  it('when the database refuses, nothing else happens and the refusal reaches the screen', async () => {
    const log: string[] = [];
    const refused = steps(log, { cancel: async () => { throw new Error('This business still has team members.'); } });
    await expect(runCancelBusiness('o1', refused)).rejects.toThrow('team members');
    expect(log).toEqual([]);
  });

  it('failing to clear the sign-up intent does not undo or hide the cancellation: the person is still taken on', async () => {
    const log: string[] = [];
    await runCancelBusiness('o1', steps(log, { clear: async () => { throw new Error('offline'); } }));
    expect(log).toEqual(['cancel', 'refresh']);
  });

  it('the cleared intent reads as a personal account, so signing in does not send the person to create another business', () => {
    expect(parseSignupIntent({ ...CLEARED_BUSINESS_INTENT })).toEqual({ kind: 'personal' });
    // and it replaces the business one rather than sitting beside it
    expect(parseSignupIntent({ signup_intent: 'business', business_kind: 'venue_owner', ...CLEARED_BUSINESS_INTENT })).toEqual({ kind: 'personal' });
  });
});

// The database refuses in short sentences written for developers. Each one the migration can raise must reach the person as a
// full sentence, and the ones that mean "ask BottlesUp" must say so. Read from the migration so a new refusal cannot be added
// without a message for it.
describe('what the person is told when the database refuses', () => {
  const sql = readFileSync(join(__dirname, '..', '..', 'supabase', 'migrations', '20261012100000_cancel_business.sql'), 'utf8');
  const raised = [...sql.matchAll(/raise exception '([^']+)'/g)].map((m) => m[1]);

  it('finds the refusals it is about to check (so this cannot pass by checking nothing)', () => {
    expect(raised.length).toBeGreaterThanOrEqual(7);
  });

  it.each(raised)('"%s" is not shown raw', (raw) => {
    const shown = friendlyMessage(raw);
    expect(shown).not.toBe(raw);
    expect(shown).toMatch(/^[A-Z]/);
    expect(shown).toMatch(/[.]$/);
  });

  it('the refusals that only the BottlesUp team can resolve say to contact them', () => {
    for (const raw of raised.filter((r) => /Contact BottlesUp/.test(r))) {
      expect(friendlyMessage(raw)).toMatch(/contact BottlesUp/i);
    }
  });

  it('the one a person can fix themselves says what to do', () => {
    expect(friendlyMessage('this business still has team members. Remove them first')).toMatch(/Remove them first/);
  });
});

describe('what the screen does once it has an answer', () => {
  it('a cancelled business sends the person to Home, which decides from what they still hold', async () => {
    const out = await confirmCancelBusiness('o1', steps([]));
    expect(out).toEqual({ ok: true, goTo: '/home', message: null });
  });

  it('a refusal becomes the sentence for the person, and the person stays where they are', async () => {
    const refused = steps([], { cancel: async () => { throw new AccountError('This business still has team members. Remove them first, then cancel it.'); } });
    expect(await confirmCancelBusiness('o1', refused)).toEqual({ ok: false, goTo: null, message: 'This business still has team members. Remove them first, then cancel it.' });
  });

  it('an unexpected failure is a generic sentence, never a raw error', async () => {
    const broken = steps([], { cancel: async () => { throw new TypeError('x is undefined'); } });
    expect(await confirmCancelBusiness('o1', broken)).toEqual({ ok: false, goTo: null, message: 'Please try again.' });
  });
});

describe('the real steps', () => {
  it('cancel asks the database to cancel exactly that business', async () => {
    const calls: unknown[][] = [];
    vi.spyOn(supabase, 'rpc').mockImplementation(((...args: unknown[]) => { calls.push(args); return Promise.resolve({ data: null, error: null }); }) as never);
    await cancelBusinessSteps(async () => undefined).cancel('org-42');
    expect(calls).toEqual([['cancel_business', { p_org: 'org-42' }]]);
    vi.restoreAllMocks();
  });

  it('clearing the intent writes the personal intent into the account\'s own metadata', async () => {
    const written: unknown[] = [];
    vi.spyOn(supabase.auth, 'updateUser').mockImplementation((async (attrs: unknown) => { written.push(attrs); return { data: { user: null }, error: null }; }) as never);
    await cancelBusinessSteps(async () => undefined).clearBusinessIntent();
    expect(written).toEqual([{ data: { signup_intent: 'personal', business_kind: null } }]);
    vi.restoreAllMocks();
  });

  it('a metadata update that fails is reported as a failure (the flow decides it is not fatal)', async () => {
    vi.spyOn(supabase.auth, 'updateUser').mockImplementation((async () => ({ data: { user: null }, error: new Error('offline') })) as never);
    await expect(cancelBusinessSteps(async () => undefined).clearBusinessIntent()).rejects.toThrow('offline');
    vi.restoreAllMocks();
  });

  it('refresh is the one it was given', async () => {
    let refreshed = 0;
    await cancelBusinessSteps(async () => { refreshed++; }).refresh();
    expect(refreshed).toBe(1);
  });
});
