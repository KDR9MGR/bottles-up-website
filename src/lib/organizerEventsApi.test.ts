import { afterEach, describe, expect, it, vi } from 'vitest';
import { supabase } from './supabase';
import { listOrgEvents, removeOrgEvent, saveOrgEvent } from './organizerEventsApi';

type Reply = { data: unknown; error: { message: string } | null };

function fakeRpc(reply: Reply) {
  const calls: [string, unknown][] = [];
  vi.spyOn(supabase, 'rpc').mockImplementation(((fn: string, args: unknown) => { calls.push([fn, args]); return Promise.resolve(reply); }) as never);
  return calls;
}

afterEach(() => vi.restoreAllMocks());

describe('the organizer\'s events over the database functions', () => {
  it('lists the events of one business, reads each row, and drops rows it cannot read', async () => {
    const calls = fakeRpc({
      error: null,
      data: [
        { event_id: 'e1', title: 'Party', start_date: '2031-10-24T22:00:00Z', status: 'draft' },
        { title: 'no id', start_date: '2031-10-24T22:00:00Z' },
        { event_id: 'e3', title: 'Live', start_date: '2031-11-24T22:00:00Z', status: 'published', ticket_tier_count: 2 },
      ],
    });
    const events = await listOrgEvents('org-1');
    expect(calls).toEqual([['list_org_events', { p_org: 'org-1' }]]);
    expect(events.map((e) => [e.eventId, e.status, e.ticketTierCount])).toEqual([['e1', 'draft', 0], ['e3', 'published', 2]]);
  });

  it('a missing or odd answer is an empty list, never a crash', async () => {
    fakeRpc({ error: null, data: null });
    expect(await listOrgEvents('org-1')).toEqual([]);
  });

  it('a refusal reaches the caller as a plain sentence', async () => {
    fakeRpc({ error: { message: 'not allowed' }, data: null });
    await expect(listOrgEvents('org-1')).rejects.toThrow("You don't have access to do that.");
  });

  it('adding sends the business, no event id, and the details; the new id comes back', async () => {
    const calls = fakeRpc({ error: null, data: 'new-id' });
    expect(await saveOrgEvent('org-1', null, { title: 'Party' })).toBe('new-id');
    expect(calls).toEqual([['save_org_event', { p_org: 'org-1', p_event: null, p_details: { title: 'Party' } }]]);
  });

  it('changing names the event', async () => {
    const calls = fakeRpc({ error: null, data: 'e1' });
    await saveOrgEvent('org-1', 'e1', { title: 'Renamed' });
    expect(calls).toEqual([['save_org_event', { p_org: 'org-1', p_event: 'e1', p_details: { title: 'Renamed' } }]]);
  });

  it('removing names the business and the event', async () => {
    const calls = fakeRpc({ error: null, data: null });
    await removeOrgEvent('org-1', 'e1');
    expect(calls).toEqual([['remove_org_event', { p_org: 'org-1', p_event: 'e1' }]]);
  });
});
