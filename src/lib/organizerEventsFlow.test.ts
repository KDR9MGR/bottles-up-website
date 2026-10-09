import { describe, expect, it } from 'vitest';
import { AccountError } from './account';
import { EMPTY_EVENT_FORM, eventPayload, type EventForm } from './organizerEvents';
import { submitEventForm } from './organizerEventsFlow';

const good: EventForm = { ...EMPTY_EVENT_FORM, title: 'Party', description: 'Fun', venueName: 'The Roof', startsAt: '2031-10-24T22:00' };

function recorder(over?: () => Promise<unknown>) {
  const calls: unknown[][] = [];
  return { calls, save: async (...args: unknown[]) => { calls.push(args); return over ? over() : 'e1'; } };
}

describe('saving the event form', () => {
  it('a form with problems sends nothing and says what is wrong', async () => {
    const r = recorder();
    const out = await submitEventForm(EMPTY_EVENT_FORM, 'o1', null, r.save);
    expect(out.ok).toBe(false);
    expect(out.problems).toContain('Give the event a title.');
    expect(r.calls).toEqual([]);
  });

  it('a new event is sent for this business with no event id, and with exactly the form\'s payload', async () => {
    const r = recorder();
    expect(await submitEventForm(good, 'o1', null, r.save)).toEqual({ ok: true, problems: [] });
    expect(r.calls).toEqual([['o1', null, eventPayload(good)]]);
  });

  it('a change names the event it changes', async () => {
    const r = recorder();
    await submitEventForm(good, 'o1', 'e42', r.save);
    expect(r.calls[0].slice(0, 2)).toEqual(['o1', 'e42']);
  });

  it('what is sent can never publish: no status, business or slug', async () => {
    const r = recorder();
    await submitEventForm(good, 'o1', null, r.save);
    const keys = Object.keys(r.calls[0][2] as object);
    for (const k of ['status', 'org_id', 'slug']) expect(keys).not.toContain(k);
  });

  it('a refusal from the database is a sentence for the form, so nothing typed is lost', async () => {
    const r = recorder(async () => { throw new AccountError('a business can have 200 events at most'); });
    expect(await submitEventForm(good, 'o1', null, r.save)).toEqual({ ok: false, problems: ['A business can have 200 events at most.'] });
  });

  it('a dropped connection is a generic sentence, never a raw error', async () => {
    const r = recorder(async () => { throw new TypeError('Failed to fetch'); });
    const out = await submitEventForm(good, 'o1', null, r.save);
    expect(out.ok).toBe(false);
    expect(out.problems).toEqual(['This could not be saved. Check your connection and try again.']);
  });
});
