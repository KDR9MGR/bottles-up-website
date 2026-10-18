import { describe, expect, it, vi } from 'vitest';
import {
  BATCH_SIZE,
  MAX_AGE_HOURS,
  decideMessage,
  formatClock,
  formatMinutes,
  isSendableEmail,
  loadFacts,
  runOutbox,
  type BookingFacts,
  type ClaimedMessage,
  type Facts,
  type OutboxDeps,
  type VipFacts,
} from '../../supabase/functions/_shared/outbox.ts';
import { createFakeDb } from './stubs/fakeDb.ts';

const NOW = Date.parse('2026-10-19T20:00:00Z');
const SITE = 'https://bottlesupapp.com/';
const msg = (over: Partial<ClaimedMessage> = {}): ClaimedMessage => ({
  id: 'm1', kind: 'seated_ack', venue_id: 'v1', ref_id: 'b1', payload: {}, attempts: 1, created_at: '2026-10-19T19:50:00Z', ...over,
});
const booking = (over: Partial<BookingFacts> = {}): BookingFacts => ({
  type: 'booking', customerEmail: 'hana@guest.example', customerName: 'Hana Holder', venueName: 'Active Lounge', tableTypeName: 'VIP booth',
  guestCount: 4, confirmationCode: 'BT-HOLD1', startTime: '22:00:00', seated: true, estimateMinutes: 20, ...over,
});
const vip = (over: Partial<VipFacts> = {}): VipFacts => ({
  type: 'vip', email: 'vera@guest.example', name: 'Vera VIP', tier: 'Gold', credentialCode: 'VIP-8H3K2', validFrom: '2026-10-01', validUntil: '2026-12-31',
  ended: false, venueName: 'Active Lounge', ...over,
});
const sent = (d: ReturnType<typeof decideMessage>) => {
  if (d.action !== 'send') throw new Error('expected a send, got: ' + d.reason);
  return d;
};
const failed = (d: ReturnType<typeof decideMessage>) => {
  if (d.action !== 'fail') throw new Error('expected a fail');
  return d.reason;
};

describe('formatting', () => {
  it('writes minutes the way a person says them', () => {
    expect(formatMinutes(1)).toBe('1 minute');
    expect(formatMinutes(20)).toBe('20 minutes');
    expect(formatMinutes(59)).toBe('59 minutes');
    expect(formatMinutes(60)).toBe('1 hour');
    expect(formatMinutes(75)).toBe('1 hour 15 minutes');
    expect(formatMinutes(121)).toBe('2 hours 1 minute');
    expect(formatMinutes(480)).toBe('8 hours');
  });

  it('writes a time of day on the 12 hour clock', () => {
    expect(formatClock('01:00:00')).toBe('1:00 AM');
    expect(formatClock('00:30:00')).toBe('12:30 AM');
    expect(formatClock('12:00:00')).toBe('12:00 PM');
    expect(formatClock('22:30:00')).toBe('10:30 PM');
    expect(formatClock('23:59')).toBe('11:59 PM');
    expect(formatClock(null)).toBeNull();
    expect(formatClock('late')).toBe('late');
    expect(formatClock('25:00:00')).toBe('25:00:00');
  });

  it('accepts a plain address and refuses anything that could carry a second recipient or markup', () => {
    expect(isSendableEmail('a@b.co')).toBe(true);
    expect(isSendableEmail(' a@b.co ')).toBe(true);
    for (const bad of [null, undefined, '', 'nobody', 'a@b', 'a b@c.co', 'a@b.co,c@d.co', 'a@b.co;c@d.co', 'a,b@c.co', 'a;b@c.co', 'a@b.co,c.co', 'a@b.co;c.co', '<a@b.co>', 'a@b.co\nBcc: x@y.co', 'x'.repeat(250) + '@b.co']) {
      expect(isSendableEmail(bad as string)).toBe(false);
    }
  });
});

describe('seated acknowledgment', () => {
  it('is sent to the booking holder with the booking details and the staff-entered estimate', () => {
    const d = sent(decideMessage(msg(), booking(), NOW, SITE));
    expect(d.to).toBe('hana@guest.example');
    expect(d.subject).toBe("You're seated at Active Lounge");
    for (const part of ['Hana Holder', 'Active Lounge', 'VIP booth', '4 guests', '10:00 PM', 'BT-HOLD1', 'about 20 minutes']) {
      expect(d.html).toContain(part);
      expect(d.text).toContain(part);
    }
    expect(d.html).toContain('href="https://bottlesupapp.com/booking/BT-HOLD1"');
    expect(d.text).toContain('View your booking: https://bottlesupapp.com/booking/BT-HOLD1');
  });

  it('only mentions an estimate when there is one', () => {
    const d = sent(decideMessage(msg(), booking({ estimateMinutes: null }), NOW, SITE));
    expect(d.html).not.toContain('estimates');
    expect(d.text).not.toContain('estimates');
  });

  it('never claims anything about payment or delivery', () => {
    const d = sent(decideMessage(msg(), booking(), NOW, SITE));
    expect(d.text.toLowerCase()).not.toMatch(/delivered|collected|received your payment/);
    expect(d.text).toContain('does not change what you have paid');
  });

  it('escapes everything a person typed, so a name cannot add markup to the e-mail', () => {
    const d = sent(decideMessage(msg(), booking({ customerName: '<img src=x onerror=1>', venueName: 'A & "B" <club>' }), NOW, SITE));
    expect(d.html).not.toContain('<img');
    expect(d.html).toContain('&lt;img src=x onerror=1&gt;');
    expect(d.html).toContain('A &amp; &quot;B&quot; &lt;club&gt;');
  });

  it('keeps the subject on one line whatever the venue is called', () => {
    const d = sent(decideMessage(msg(), booking({ venueName: 'Club\r\nBcc: spy@x.co' }), NOW, SITE));
    expect(d.subject).not.toMatch(/[\r\n]/);
  });

  it('copes with a booking that has no code, no time and one guest', () => {
    const d = sent(decideMessage(msg(), booking({ confirmationCode: null, startTime: null, guestCount: 1, customerName: null }), NOW, SITE));
    expect(d.html).toContain('Hi there');
    expect(d.html).toContain('1 guest<');
    expect(d.html).not.toContain('Booking code');
    expect(d.html).not.toContain('View your booking');
  });

  it('is not sent if the guest was un-seated since it was queued', () => {
    expect(failed(decideMessage(msg(), booking({ seated: false }), NOW, SITE))).toMatch(/no longer marked as seated/);
  });

  it('is not sent if the booking is gone, or the facts belong to something else', () => {
    expect(failed(decideMessage(msg(), null, NOW, SITE))).toMatch(/no longer exists/);
    expect(failed(decideMessage(msg(), vip(), NOW, SITE))).toMatch(/no longer exists/);
  });

  it('is not sent without a usable address', () => {
    expect(failed(decideMessage(msg(), booking({ customerEmail: null }), NOW, SITE))).toMatch(/no valid e-mail/);
    expect(failed(decideMessage(msg(), booking({ customerEmail: 'not an address' }), NOW, SITE))).toMatch(/no valid e-mail/);
  });
});

describe('estimate update', () => {
  const upd = msg({ kind: 'estimate_updated' });

  it('is sent with the CURRENT estimate and says it changed', () => {
    const d = sent(decideMessage(upd, booking({ estimateMinutes: 45 }), NOW, SITE));
    expect(d.subject).toBe('Updated service estimate at Active Lounge');
    expect(d.text).toContain('now estimates about 45 minutes');
  });

  it('is not sent if the estimate was cleared in the meantime', () => {
    expect(failed(decideMessage(upd, booking({ estimateMinutes: null }), NOW, SITE))).toMatch(/estimate was cleared/);
  });

  it('is not sent if the guest is no longer seated', () => {
    expect(failed(decideMessage(upd, booking({ seated: false }), NOW, SITE))).toMatch(/no longer marked as seated/);
  });
});

describe('VIP invitation', () => {
  const inv = msg({ kind: 'vip_invite', ref_id: 'vip1' });

  it('is sent to the guest with their code and validity', () => {
    const d = sent(decideMessage(inv, vip(), NOW, SITE));
    expect(d.to).toBe('vera@guest.example');
    expect(d.subject).toBe('Your VIP access at Active Lounge');
    for (const part of ['Vera VIP', 'Active Lounge', 'Gold', 'VIP-8H3K2', '2026-10-01', '2026-12-31']) {
      expect(d.html).toContain(part);
      expect(d.text).toContain(part);
    }
  });

  it('leaves out validity dates that were not set', () => {
    const d = sent(decideMessage(inv, vip({ validFrom: null, validUntil: null }), NOW, SITE));
    expect(d.text).not.toContain('Valid from');
    expect(d.text).not.toContain('Valid until');
  });

  it('is not sent for a membership that has ended, or one that is gone', () => {
    expect(failed(decideMessage(inv, vip({ ended: true }), NOW, SITE))).toMatch(/has ended/);
    expect(failed(decideMessage(inv, null, NOW, SITE))).toMatch(/no longer exists/);
    expect(failed(decideMessage(inv, booking(), NOW, SITE))).toMatch(/no longer exists/);
  });

  it('is not sent without a usable address', () => {
    expect(failed(decideMessage(inv, vip({ email: null }), NOW, SITE))).toMatch(/no valid e-mail/);
  });

  it('escapes the guest name and the code', () => {
    const d = sent(decideMessage(inv, vip({ name: '<b>x</b>', credentialCode: '"><script>' }), NOW, SITE));
    expect(d.html).not.toContain('<b>x');
    expect(d.html).not.toContain('<script>');
  });
});

describe('what is never sent', () => {
  it('a message older than the limit, even if everything else is fine', () => {
    const old = new Date(NOW - (MAX_AGE_HOURS * 3600_000 + 1000)).toISOString();
    expect(failed(decideMessage(msg({ created_at: old }), booking(), NOW, SITE))).toMatch(new RegExp(`more than ${MAX_AGE_HOURS} hours old`));
  });

  it('a message exactly at the limit still goes', () => {
    const edge = new Date(NOW - MAX_AGE_HOURS * 3600_000).toISOString();
    sent(decideMessage(msg({ created_at: edge }), booking(), NOW, SITE));
  });

  it('a kind this sender does not know (the reason names it, cut to a safe length, on one line)', () => {
    const reason = failed(decideMessage(msg({ kind: 'sms_blast\nBcc: x'.padEnd(100, 'z') }), booking(), NOW, SITE));
    expect(reason).toMatch(/unknown message kind/);
    expect(reason).not.toMatch(/\n/);
    expect(reason.length).toBeLessThan(100);
  });
});

describe('reading the facts', () => {
  const seed = () =>
    createFakeDb({
      site_table_bookings: [{
        id: 'b1', customer_email: 'hana@guest.example', customer_name: 'Hana Holder', guest_count: 4, confirmation_code: 'BT-HOLD1',
        table_type: { name: 'VIP booth' }, venue: { name: 'Active Lounge' }, time_slot: { start_time: '22:00:00' },
      }],
      site_booking_seating: [{ booking_id: 'b1', estimate_minutes: 20 }],
      site_vip_members: [
        { id: 'vip1', email: 'vera@guest.example', name: 'Vera VIP', tier: 'Gold', credential_code: 'VIP-8H3K2', valid_from: null, valid_until: '2026-12-31', ended_at: null, venue: { name: 'Active Lounge' } },
        { id: 'vip2', email: null, name: 'Old', tier: 'VIP', credential_code: 'VIP-OLD', ended_at: '2026-09-01T00:00:00Z', venue: { name: 'Active Lounge' } },
      ],
    });

  it('reads a seated booking with its current estimate', async () => {
    const f = (await loadFacts(seed().client, msg())) as BookingFacts;
    expect(f).toMatchObject({ type: 'booking', customerEmail: 'hana@guest.example', venueName: 'Active Lounge', tableTypeName: 'VIP booth', guestCount: 4, startTime: '22:00:00', seated: true, estimateMinutes: 20 });
  });

  it('reads a booking that is not seated as not seated, with no estimate', async () => {
    const db = seed();
    db.tables.site_booking_seating = [];
    const f = (await loadFacts(db.client, msg())) as BookingFacts;
    expect(f.seated).toBe(false);
    expect(f.estimateMinutes).toBeNull();
  });

  it('reads a seated booking whose estimate was cleared as having no estimate', async () => {
    const db = seed();
    db.tables.site_booking_seating = [{ booking_id: 'b1', estimate_minutes: null }];
    const f = (await loadFacts(db.client, msg({ kind: 'estimate_updated' }))) as BookingFacts;
    expect(f.seated).toBe(true);
    expect(f.estimateMinutes).toBeNull();
  });

  it('answers null for a booking that is gone, a message with no reference, or an unknown kind', async () => {
    expect(await loadFacts(seed().client, msg({ ref_id: 'nope' }))).toBeNull();
    expect(await loadFacts(seed().client, msg({ ref_id: null }))).toBeNull();
    expect(await loadFacts(seed().client, msg({ kind: 'mystery' }))).toBeNull();
  });

  it('reads a VIP membership, and whether it has ended', async () => {
    const live = (await loadFacts(seed().client, msg({ kind: 'vip_invite', ref_id: 'vip1' }))) as VipFacts;
    expect(live).toMatchObject({ type: 'vip', email: 'vera@guest.example', tier: 'Gold', credentialCode: 'VIP-8H3K2', validUntil: '2026-12-31', ended: false, venueName: 'Active Lounge' });
    const gone = (await loadFacts(seed().client, msg({ kind: 'vip_invite', ref_id: 'vip2' }))) as VipFacts;
    expect(gone.ended).toBe(true);
    expect(await loadFacts(seed().client, msg({ kind: 'vip_invite', ref_id: 'nope' }))).toBeNull();
  });

  it('turns a read error into an error (the message is then retried), without leaking the database text', async () => {
    const broken = { from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: { message: 'secret table detail' } }) }) }) }) };
    await expect(loadFacts(broken, msg())).rejects.toThrow('could not read the booking');
    await expect(loadFacts(broken, msg({ kind: 'vip_invite' }))).rejects.toThrow('could not read the VIP membership');
  });
});

describe('one run', () => {
  const makeDeps = (batch: ClaimedMessage[], facts: Record<string, Facts>, over: Partial<OutboxDeps> = {}) => {
    const finish = vi.fn(async () => undefined);
    const send = vi.fn(async () => ({ sent: true }));
    const claim = vi.fn(async () => batch);
    const purgeChat = vi.fn(async () => 3);
    const deps: OutboxDeps = {
      configured: () => true, claim, loadFacts: async (m) => facts[m.id] ?? null, send, finish, purgeChat, now: () => NOW, siteUrl: SITE, ...over,
    };
    return { deps, finish, send, claim, purgeChat };
  };

  it('sends what is sendable, fails what can never go, and reports both', async () => {
    const batch = [msg({ id: 'ok' }), msg({ id: 'unseated', ref_id: 'b2' }), msg({ id: 'vip', kind: 'vip_invite', ref_id: 'v' })];
    const { deps, finish, send } = makeDeps(batch, { ok: booking(), unseated: booking({ seated: false }), vip: vip() });
    const summary = await runOutbox(deps);
    expect(summary).toEqual({ claimed: 3, sent: 2, retried: 0, failed: 1, chatPurged: 3 });
    expect(send).toHaveBeenCalledTimes(2);
    expect(finish).toHaveBeenCalledWith('ok', 'sent', null);
    expect(finish).toHaveBeenCalledWith('vip', 'sent', null);
    expect(finish).toHaveBeenCalledWith('unseated', 'failed', expect.stringMatching(/no longer marked as seated/));
  });

  it('asks for a batch of the agreed size', async () => {
    const { deps, claim } = makeDeps([], {});
    await runOutbox(deps);
    expect(claim).toHaveBeenCalledWith(BATCH_SIZE);
  });

  it('retries, with a plain reason, when the provider refuses', async () => {
    const { deps, finish } = makeDeps([msg()], { m1: booking() }, { send: vi.fn(async () => ({ sent: false, reason: 'send_failed' })) });
    const summary = await runOutbox(deps);
    expect(summary).toMatchObject({ sent: 0, retried: 1, failed: 0 });
    expect(finish).toHaveBeenCalledWith('m1', 'retry', 'the e-mail provider did not accept the message');
  });

  it('retries when reading the facts throws, and carries on with the rest of the batch', async () => {
    const { deps, finish, send } = makeDeps([msg({ id: 'a' }), msg({ id: 'b' })], { b: booking() }, {
      loadFacts: async (m) => { if (m.id === 'a') throw new Error('could not read the booking'); return booking(); },
    });
    const summary = await runOutbox(deps);
    expect(summary).toMatchObject({ claimed: 2, sent: 1, retried: 1 });
    expect(finish).toHaveBeenCalledWith('a', 'retry', 'could not read the booking');
    expect(send).toHaveBeenCalledTimes(1);
  });

  it('records a successful send a second time if the first recording fails (an unrecorded send would go out again)', async () => {
    const finish = vi.fn().mockRejectedValueOnce(new Error('blip')).mockResolvedValue(undefined);
    const { deps } = makeDeps([msg()], { m1: booking() }, { finish });
    const summary = await runOutbox(deps);
    expect(summary).toMatchObject({ sent: 1, retried: 0 });
    expect(finish).toHaveBeenCalledTimes(2);
    expect(finish).toHaveBeenNthCalledWith(2, 'm1', 'sent', null);
  });

  it('still counts a failure to record when recording keeps failing, without crashing the run', async () => {
    const finish = vi.fn(async () => { throw new Error('down'); });
    const { deps } = makeDeps([msg({ id: 'a' }), msg({ id: 'b' })], { a: booking(), b: booking() }, { finish });
    const summary = await runOutbox(deps);
    expect(summary.claimed).toBe(2);
    expect(summary.retried).toBe(2);
  });

  it('uses up no attempt when there is no e-mail provider key: nothing is claimed, nothing sent', async () => {
    const { deps, claim, send, purgeChat } = makeDeps([msg()], { m1: booking() }, { configured: () => false });
    const summary = await runOutbox(deps);
    expect(summary).toEqual({ skipped: 'not_configured', claimed: 0, sent: 0, retried: 0, failed: 0, chatPurged: 3 });
    expect(claim).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
    expect(purgeChat).toHaveBeenCalledTimes(1);
  });

  it('reports a queue it cannot read, sends nothing, and still cleans up chats', async () => {
    const { deps, send, purgeChat } = makeDeps([], {}, { claim: vi.fn(async () => { throw new Error('rpc down'); }) });
    const summary = await runOutbox(deps);
    expect(summary.error).toMatch(/could not claim messages: rpc down/);
    expect(summary).toMatchObject({ claimed: 0, sent: 0 });
    expect(send).not.toHaveBeenCalled();
    expect(purgeChat).toHaveBeenCalledTimes(1);
  });

  it('reports a chat clean-up that failed as null, and the e-mail part is unaffected', async () => {
    const { deps } = makeDeps([msg()], { m1: booking() }, { purgeChat: vi.fn(async () => { throw new Error('boom'); }) });
    const summary = await runOutbox(deps);
    expect(summary).toMatchObject({ sent: 1, chatPurged: null });
  });
});
