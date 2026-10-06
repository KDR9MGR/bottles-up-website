import { describe, expect, it } from 'vitest';
import {
  buildInvitePayload, canCancelInvitation, canRemoveMember, canSendNewLink, describeAccess, describeScope, displayName,
  emailOutcomeMessage, INVITATION_STATE, invitationLink, isCurrentMember, isInvitationState, isMemberState, localInputToIso,
  MEMBER_STATE, mailtoLink, validateInvite, type InviteForm,
} from './team';

const form = (over: Partial<InviteForm> = {}): InviteForm => ({
  email: 'nia@example.com', role: 'server', venueId: 'v1', temporary: false, start: '', end: '', shiftId: '', ...over,
});
const NOW = new Date(2026, 9, 10, 12, 0); // local time, like a datetime-local value

describe('validateInvite', () => {
  it('accepts a complete invitation', () => {
    expect(validateInvite(form(), NOW)).toEqual([]);
  });

  it.each(['', 'nia', 'nia@', '@x.com', 'a b@x.com'])('rejects the email %j', (email) => {
    expect(validateInvite(form({ email }), NOW).join(' ')).toMatch(/email address/);
  });

  it('needs a club and a role', () => {
    expect(validateInvite(form({ venueId: '' }), NOW).join(' ')).toMatch(/club/);
    expect(validateInvite(form({ role: '' }), NOW).join(' ')).toMatch(/role/);
  });

  it('reports every problem at once, not one at a time', () => {
    expect(validateInvite(form({ email: '', venueId: '', role: '' }), NOW)).toHaveLength(3);
  });

  describe('temporary access', () => {
    it('needs both a start and an end', () => {
      expect(validateInvite(form({ temporary: true }), NOW).join(' ')).toMatch(/start and an end/);
      expect(validateInvite(form({ temporary: true, start: '2026-10-10T21:00' }), NOW).join(' ')).toMatch(/start and an end/);
      expect(validateInvite(form({ temporary: true, start: 'garbage', end: 'garbage' }), NOW).join(' ')).toMatch(/start and an end/);
    });

    it('needs the end after the start', () => {
      expect(validateInvite(form({ temporary: true, start: '2026-10-10T21:00', end: '2026-10-10T21:00' }), NOW).join(' ')).toMatch(/after the start/);
      expect(validateInvite(form({ temporary: true, start: '2026-10-11T03:00', end: '2026-10-10T21:00' }), NOW).join(' ')).toMatch(/after the start/);
    });

    it('refuses a window that has already ended', () => {
      expect(validateInvite(form({ temporary: true, start: '2026-10-09T20:00', end: '2026-10-10T02:00' }), NOW).join(' ')).toMatch(/past/);
    });

    it('accepts a window that is under way or in the future', () => {
      expect(validateInvite(form({ temporary: true, start: '2026-10-10T09:00', end: '2026-10-10T23:00' }), NOW)).toEqual([]);
      expect(validateInvite(form({ temporary: true, start: '2026-10-10T21:00', end: '2026-10-11T03:00' }), NOW)).toEqual([]);
    });

    it('ignores the window fields entirely when access is ongoing', () => {
      expect(validateInvite(form({ temporary: false, start: 'garbage', end: '' }), NOW)).toEqual([]);
    });
  });
});

describe('buildInvitePayload', () => {
  it('cleans the email and leaves out what was not chosen', () => {
    expect(buildInvitePayload(form({ email: '  Nia@Example.COM ' }))).toEqual({
      email: 'nia@example.com', role: 'server', venueId: 'v1', shiftId: null, accessStartAt: null, accessEndAt: null,
    });
  });

  it('sends the window as instants only for temporary access', () => {
    const p = buildInvitePayload(form({ temporary: true, start: '2026-10-10T21:00', end: '2026-10-11T03:00', shiftId: 's1' }));
    expect(p.shiftId).toBe('s1');
    expect(new Date(p.accessStartAt as string).getTime()).toBe(new Date('2026-10-10T21:00').getTime());
    expect(new Date(p.accessEndAt as string).getTime()).toBe(new Date('2026-10-11T03:00').getTime());
    expect(buildInvitePayload(form({ temporary: false, start: '2026-10-10T21:00', end: '2026-10-11T03:00' })).accessStartAt).toBeNull();
  });

  it('treats an unreadable local time as nothing, never as "now"', () => {
    expect(localInputToIso('')).toBeNull();
    expect(localInputToIso('garbage')).toBeNull();
    expect(localInputToIso('2026-13-45T99:99')).toBeNull();
    expect(localInputToIso('2026-10-10T21:00')).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  });
});

describe('the link and the fallback email', () => {
  it('builds the accept address and encodes the token', () => {
    expect(invitationLink('https://www.bottlesupapp.com', 'abc')).toBe('https://www.bottlesupapp.com/accept-invite?token=abc');
    expect(invitationLink('http://localhost:8080/', 'a b&c')).toBe('http://localhost:8080/accept-invite?token=a%20b%26c');
  });

  it('prepares a mail the inviter can send themselves', () => {
    const m = mailtoLink('nia@example.com', 'Club Co', 'Bottle Server', 'https://x.example/accept-invite?token=abc');
    expect(m.startsWith('mailto:nia%40example.com?')).toBe(true);
    const params = new URLSearchParams(m.split('?')[1]);
    expect(params.get('subject')).toBe('You are invited to join Club Co on BottlesUp');
    expect(params.get('body')).toContain('https://x.example/accept-invite?token=abc');
    expect(params.get('body')).toContain('as Bottle Server');
  });

  it('cannot be tricked by a name containing mail-header characters', () => {
    const m = mailtoLink('nia@example.com', 'Club\r\nBcc: x@evil.example', 'Server', 'https://x.example');
    expect(m).not.toMatch(/[\r\n]/);
    // ...and still none once the mail app has decoded it.
    const subject = new URLSearchParams(m.split('?')[1]).get('subject') as string;
    expect(subject).not.toMatch(/[\r\n]/);
  });
});

describe('what to tell the inviter after sending', () => {
  it('confirms a sent email by address', () => {
    expect(emailOutcomeMessage({ sent: true }, 'nia@example.com')).toEqual({ tone: 'success', text: 'We emailed the invitation to nia@example.com.' });
  });
  it.each([
    ['not_configured', /not set up/],
    ['rate_limited', /emailed recently/],
    ['send_failed', /could not send/],
    ['something_new', /could not send/],
  ])('a failure (%s) is a warning that points at the link', (reason, text) => {
    const m = emailOutcomeMessage({ sent: false, reason }, 'nia@example.com');
    expect(m.tone).toBe('warning');
    expect(m.text).toMatch(text);
    expect(m.text).toMatch(/link/);
  });
});

describe('states and what can be done in each', () => {
  it('has a label for every state', () => {
    for (const s of ['active', 'scheduled', 'expired', 'revoked'] as const) expect(MEMBER_STATE[s].label.length).toBeGreaterThan(2);
    for (const s of ['pending', 'accepted', 'expired', 'revoked'] as const) expect(INVITATION_STATE[s].label.length).toBeGreaterThan(2);
  });

  it('recognises valid states only', () => {
    expect(isMemberState('scheduled')).toBe(true);
    expect(isMemberState('pending')).toBe(false);
    expect(isInvitationState('accepted')).toBe(true);
    expect(isInvitationState('active')).toBe(false);
    expect(isMemberState(null)).toBe(false);
  });

  it('active and not-yet-started people are the current team; ended and removed are history', () => {
    expect(isCurrentMember('active')).toBe(true);
    expect(isCurrentMember('scheduled')).toBe(true);
    expect(isCurrentMember('expired')).toBe(false);
    expect(isCurrentMember('revoked')).toBe(false);
  });

  it('a new link can be sent only for a waiting or expired invitation', () => {
    expect(canSendNewLink('pending')).toBe(true);
    expect(canSendNewLink('expired')).toBe(true);
    expect(canSendNewLink('accepted')).toBe(false);
    expect(canSendNewLink('revoked')).toBe(false);
  });

  it('only a waiting or expired invitation can be cancelled', () => {
    expect(canCancelInvitation('pending')).toBe(true);
    expect(canCancelInvitation('expired')).toBe(true);
    expect(canCancelInvitation('accepted')).toBe(false);
    expect(canCancelInvitation('revoked')).toBe(false);
  });

  it('owners and organizers are never offered "remove"; removed people are not removed twice', () => {
    expect(canRemoveMember('owner', 'active')).toBe(false);
    expect(canRemoveMember('organizer', 'active')).toBe(false);
    expect(canRemoveMember('manager', 'active')).toBe(true);
    expect(canRemoveMember('server', 'scheduled')).toBe(true);
    expect(canRemoveMember('door', 'expired')).toBe(true);
    expect(canRemoveMember('server', 'revoked')).toBe(false);
  });
});

describe('wording', () => {
  it('describes access', () => {
    expect(describeAccess(null, null)).toBe('Ongoing');
    expect(describeAccess('2026-10-10T21:00:00Z', '2026-10-11T03:00:00Z', 'en-CA')).toMatch(/ to /);
    expect(describeAccess('2026-10-10T21:00:00Z', null, 'en-CA')).toMatch(/^From /);
    expect(describeAccess(null, '2026-10-11T03:00:00Z', 'en-CA')).toMatch(/^Until /);
  });

  it('names a person by name, then email', () => {
    expect(displayName('Nia Okafor', 'nia@example.com')).toBe('Nia Okafor');
    expect(displayName('  ', 'nia@example.com')).toBe('nia@example.com');
    expect(displayName(null, null)).toBe('Unknown');
  });

  it('describes where someone works', () => {
    expect(describeScope('Club A', null, null)).toBe('Club A');
    expect(describeScope('Club A', 'Friday Night', 'Doors 9pm')).toBe('Club A · Friday Night · Doors 9pm');
    expect(describeScope(null, null, null)).toBe('Whole business');
  });
});

import { parseShift, parseTeamInvitation, parseTeamMember, splitTeam, type TeamMember } from './team';

describe('reading database rows', () => {
  const member = {
    membership_id: 'm1', user_id: 'u1', email: 'nia@example.com', name: 'Nia', role: 'server', venue_id: 'v1', venue_name: 'Club A',
    event_id: null, event_title: null, shift_id: 's1', shift_name: 'Friday doors', access_start_at: null, access_end_at: null,
    state: 'scheduled', created_at: '2026-10-01T00:00:00Z',
  };

  it('reads a team member', () => {
    expect(parseTeamMember(member)).toMatchObject({ membershipId: 'm1', name: 'Nia', role: 'server', venueName: 'Club A', shiftName: 'Friday doors', state: 'scheduled', eventId: null });
  });

  it('drops a member with a state it does not know, or with missing identifiers', () => {
    expect(parseTeamMember({ ...member, state: 'suspended' })).toBeNull();
    expect(parseTeamMember({ ...member, membership_id: 5 })).toBeNull();
    expect(parseTeamMember({ ...member, role: undefined })).toBeNull();
  });

  it('treats empty strings as missing', () => {
    expect(parseTeamMember({ ...member, name: '', venue_name: '' })).toMatchObject({ name: null, venueName: null });
  });

  const invitation = {
    invitation_id: 'i1', email: 'new@staff.example', role: 'door', venue_id: 'v1', venue_name: 'Club A', event_id: null, event_title: null,
    shift_id: null, shift_name: null, access_start_at: '2026-10-10T21:00:00Z', access_end_at: '2026-10-11T03:00:00Z', state: 'pending',
    expires_at: '2026-10-17T00:00:00Z', created_at: '2026-10-10T00:00:00Z', emails_sent: 2, last_emailed_at: '2026-10-10T01:00:00Z',
  };

  it('reads an invitation, including how often it was emailed', () => {
    expect(parseTeamInvitation(invitation)).toMatchObject({ invitationId: 'i1', state: 'pending', emailsSent: 2, venueName: 'Club A' });
  });

  it('drops an invitation with an unknown state, and tolerates a missing email count', () => {
    expect(parseTeamInvitation({ ...invitation, state: 'sent' })).toBeNull();
    expect(parseTeamInvitation({ ...invitation, emails_sent: undefined })).toMatchObject({ emailsSent: 0 });
  });

  it('reads a shift', () => {
    expect(parseShift({ shift_id: 's1', name: 'Friday doors', starts_at: 'a', ends_at: 'b', event_title: null })).toMatchObject({ shiftId: 's1', name: 'Friday doors' });
    expect(parseShift({ shift_id: 's1', starts_at: 'a' })).toBeNull();
    expect(parseShift({ shift_id: 's1', name: '', starts_at: 'a', ends_at: 'b' })).toMatchObject({ name: 'Shift' });
  });

  it('splits the current team from history', () => {
    const base = parseTeamMember(member) as TeamMember;
    const list: TeamMember[] = [
      { ...base, membershipId: 'a', state: 'active' },
      { ...base, membershipId: 'b', state: 'revoked' },
      { ...base, membershipId: 'c', state: 'scheduled' },
      { ...base, membershipId: 'd', state: 'expired' },
    ];
    const { current, history } = splitTeam(list);
    expect(current.map((m) => m.membershipId)).toEqual(['a', 'c']);
    expect(history.map((m) => m.membershipId)).toEqual(['b', 'd']);
  });
});
