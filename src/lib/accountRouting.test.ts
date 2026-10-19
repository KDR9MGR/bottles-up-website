import { describe, expect, it } from 'vitest';
import {
  attentionFor,
  buildDestinations,
  decideLanding,
  EMPTY_SNAPSHOT,
  isDestinationPermitted,
  LEAVE_ONBOARDING_LABEL,
  LEAVE_ONBOARDING_TO,
  leaveAddBusinessTo,
  parseBusinessRow,
  parseSignupIntent,
  parseWorkspaceRow,
  type AccountSnapshot,
  type Business,
  type Workspace,
} from './accountRouting';
import { landingSection } from './roleNavigation';

const ws = (over: Partial<Workspace> = {}): Workspace => ({
  membershipId: 'm1',
  orgId: 'o1',
  orgName: 'Club Co',
  orgKind: 'venue_owner',
  role: 'owner',
  venueId: null,
  venueName: null,
  eventId: null,
  eventTitle: null,
  shiftId: null,
  shiftName: null,
  accessEndAt: null,
  ...over,
});

const biz = (over: Partial<Business> = {}): Business => ({
  orgId: 'o1',
  name: 'Club Co',
  kind: 'venue_owner',
  verificationState: 'verified',
  requestMessage: null,
  missing: [],
  venueCount: 1,
  pendingClaims: 0,
  ...over,
});

const person = (over: Partial<AccountSnapshot> = {}): AccountSnapshot => ({
  ...EMPTY_SNAPSHOT,
  signedIn: true,
  profileComplete: true,
  ...over,
});

const to = (s: AccountSnapshot, opts = {}) => {
  const l = decideLanding(s, opts);
  return l.kind === 'redirect' ? l.to : l.kind;
};

describe('after login (brief, section 3 table)', () => {
  it('a signed-out visitor is not routed anywhere', () => {
    expect(decideLanding(EMPTY_SNAPSHOT).kind).toBe('signed_out');
  });

  it('personal user -> personal dashboard', () => {
    expect(to(person())).toBe('/dashboard');
  });

  it('owner (verified, with a venue) -> their workspace, starting at Overview', () => {
    const s = person({ workspaces: [ws()], businesses: [biz()] });
    expect(to(s)).toBe('/w/m1/overview');
  });

  it('event organizer -> My Events home', () => {
    const s = person({
      workspaces: [ws({ membershipId: 'm2', role: 'organizer', orgKind: 'organizer', orgName: 'Night Events' })],
      businesses: [biz({ orgId: 'o1', kind: 'organizer', name: 'Night Events' })],
    });
    expect(to(s)).toBe('/w/m2/home');
  });

  it.each([
    ['manager', 'tonight'],
    ['server', 'tables'],
    ['door', 'scan'],
    ['security', 'alerts'],
    ['verifier', 'review'],
  ] as const)('%s -> their assigned workspace (%s)', (role, section) => {
    const s = person({ workspaces: [ws({ membershipId: 'mx', role, venueId: 'v1', venueName: 'Club A' })] });
    expect(to(s)).toBe(`/w/mx/${section}`);
    expect(landingSection(role)).toBe(section);
  });

  it('several businesses or roles -> workspace selector', () => {
    const s = person({
      workspaces: [ws(), ws({ membershipId: 'm9', orgId: 'o9', orgName: 'Other Co', role: 'manager', venueId: 'v9', venueName: 'Other Club' })],
      businesses: [biz()],
    });
    const l = decideLanding(s);
    expect(l.kind).toBe('select');
    if (l.kind === 'select') {
      expect(l.destinations.map((d) => d.key)).toEqual(['personal', 'm1', 'm9']);
    }
  });

  it('...and remembers the last workspace while it is still theirs', () => {
    const s = person({
      workspaces: [ws(), ws({ membershipId: 'm9', orgId: 'o9', orgName: 'Other Co', role: 'manager', venueId: 'v9', venueName: 'Other Club' })],
      businesses: [biz()],
    });
    expect(to(s, { lastKey: 'm9' })).toBe('/w/m9/tonight');
    expect(to(s, { lastKey: 'm1' })).toBe('/w/m1/overview');
  });

  it('...but ignores a remembered workspace that has been revoked since', () => {
    const s = person({
      workspaces: [ws(), ws({ membershipId: 'm9', orgId: 'o9', role: 'manager', venueId: 'v9' })],
      businesses: [biz()],
    });
    expect(decideLanding(s, { lastKey: 'm-revoked' }).kind).toBe('select');
  });

  it('...and does not treat "personal" as a remembered workspace when there is business work', () => {
    const s = person({
      workspaces: [ws(), ws({ membershipId: 'm9', orgId: 'o9', role: 'manager', venueId: 'v9' })],
      businesses: [biz()],
    });
    expect(decideLanding(s, { lastKey: 'personal' }).kind).toBe('select');
  });

  it('a platform admin -> the CMS', () => {
    expect(to(person({ isCmsAdmin: true }))).toBe('/cms');
  });

  it('legacy door staff keep landing on the scanner, other legacy staff on the server dashboard', () => {
    expect(to(person({ legacyStaffRole: 'door_staff' }))).toBe('/door/scan');
    expect(to(person({ legacyStaffRole: 'server' }))).toBe('/staff/tables');
    expect(to(person({ legacyStaffRole: 'manager' }))).toBe('/staff/tables');
  });

  it('an admin who is also an owner is asked which to open', () => {
    const s = person({ isCmsAdmin: true, workspaces: [ws()], businesses: [biz()] });
    expect(decideLanding(s).kind).toBe('select');
  });
});

describe('resuming business onboarding', () => {
  it('a business not yet submitted lands on onboarding, not an empty dashboard', () => {
    const s = person({ workspaces: [ws()], businesses: [biz({ verificationState: 'not_submitted' })] });
    expect(to(s)).toBe('/business/o1/onboarding');
  });

  it('a venue owner with no venue yet is sent to add or claim one, even when verified', () => {
    const s = person({ workspaces: [ws()], businesses: [biz({ venueCount: 0, pendingClaims: 0 })] });
    expect(to(s)).toBe('/business/o1/onboarding');
  });

  it('a pending claim counts as having a venue', () => {
    const s = person({ workspaces: [ws()], businesses: [biz({ venueCount: 0, pendingClaims: 1 })] });
    expect(to(s)).toBe('/w/m1/overview');
  });

  it('a business sent back by the reviewer lands where it can read the request', () => {
    const s = person({ workspaces: [ws()], businesses: [biz({ verificationState: 'more_information_needed', requestMessage: 'Add registration number' })] });
    expect(to(s)).toBe('/business/o1/onboarding');
  });

  it('a business under review keeps its dashboard (it may keep drafting) but is flagged', () => {
    const s = person({ workspaces: [ws()], businesses: [biz({ verificationState: 'under_review' })] });
    expect(to(s)).toBe('/w/m1/overview');
    expect(buildDestinations(s).find((d) => d.key === 'm1')?.attention).toBe('under_review');
  });

  it('an organizer has no venue requirement', () => {
    const b = biz({ kind: 'organizer', venueCount: 0, verificationState: 'verified' });
    expect(attentionFor(b)).toBeNull();
  });

  it('attention is flagged on the selector entries so the page can show "Continue setup"', () => {
    const s = person({
      workspaces: [ws(), ws({ membershipId: 'm2', orgId: 'o2', orgName: 'Second Co' })],
      businesses: [biz(), biz({ orgId: 'o2', name: 'Second Co', verificationState: 'not_submitted' })],
    });
    const dests = buildDestinations(s);
    expect(dests.find((d) => d.key === 'm1')?.attention).toBeNull();
    expect(dests.find((d) => d.key === 'm2')?.attention).toBe('finish_setup');
  });
});

describe('sign-up intent and profile', () => {
  it('a new personal account is sent to create their profile first', () => {
    expect(to(person({ profileComplete: false }))).toBe('/onboarding/profile');
  });

  it('...unless they skipped it this session', () => {
    expect(to(person({ profileComplete: false }), { profileSkipped: true })).toBe('/dashboard');
  });

  it('an existing app user with an unfinished profile sees "Complete Your Profile", not a second registration', () => {
    const r = to(person({ profileComplete: false, signupIntent: null }));
    expect(r).toBe('/onboarding/profile');
    expect(r).not.toContain('signup');
  });

  it('someone who chose a business account but has no business yet resumes at the right type', () => {
    const s = person({ profileComplete: false, signupIntent: { kind: 'business', businessKind: 'organizer' } });
    expect(to(s)).toBe('/business/new?type=organizer');
    const v = person({ signupIntent: { kind: 'business', businessKind: 'venue_owner' } });
    expect(to(v)).toBe('/business/new?type=venue_owner');
  });

  it('a business account is not held up by the personal profile step', () => {
    const s = person({ profileComplete: false, workspaces: [ws()], businesses: [biz()] });
    expect(to(s)).toBe('/w/m1/overview');
  });

  it('an invited staff member is not held up by it either', () => {
    const s = person({ profileComplete: false, workspaces: [ws({ role: 'server', venueId: 'v1' })] });
    expect(to(s)).toBe('/w/m1/tables');
  });

  it('the stored intent never grants anything: it only chooses which onboarding page', () => {
    // Even claiming to be a venue owner gives no workspace, so the only place it can lead is
    // the page that creates a business through the database function.
    const s = person({ signupIntent: { kind: 'business', businessKind: 'venue_owner' } });
    expect(buildDestinations(s).map((d) => d.kind)).toEqual(['personal']);
  });
});

describe('a destination the person was heading for (booking link, invitation)', () => {
  it('is kept through login: a venue booking link', () => {
    expect(to(person(), { next: '/venues/xno' })).toBe('/venues/xno');
    expect(to(person({ workspaces: [ws()], businesses: [biz()] }), { next: '/events/7?ref=ig' })).toBe('/events/7?ref=ig');
  });

  it('beats the default landing, even for an owner (they asked for that page)', () => {
    expect(to(person({ workspaces: [ws()], businesses: [biz()] }), { next: '/venues/xno' })).toBe('/venues/xno');
  });

  it('keeps an invitation link so staff can accept it after signing up', () => {
    expect(to(person({ profileComplete: false }), { next: '/accept-invite?token=abc123' })).toBe('/accept-invite?token=abc123');
  });

  it.each([
    'https://evil.example',
    '//evil.example',
    '/\\evil.example',
    'javascript:alert(1)',
    '/login',
    '/home',
  ])('drops an unsafe destination: %s', (next) => {
    expect(to(person(), { next })).toBe('/dashboard');
  });

  it('a workspace link is honoured only for a workspace they still hold', () => {
    const s = person({ workspaces: [ws({ membershipId: 'm1' })], businesses: [biz()] });
    expect(to(s, { next: '/w/m1/payments' })).toBe('/w/m1/payments');
    expect(to(s, { next: '/w/m-revoked/payments' })).toBe('/w/m1/overview');
  });

  it('a revoked role opens no operational dashboard', () => {
    const s = person(); // membership gone: my_workspaces no longer returns it
    expect(to(s, { next: '/w/m1/tables' })).toBe('/dashboard');
  });

  it('the admin area and the older staff pages need the matching access', () => {
    expect(to(person(), { next: '/cms/bookings' })).toBe('/dashboard');
    expect(to(person({ isCmsAdmin: true }), { next: '/cms/bookings' })).toBe('/cms/bookings');
    expect(to(person(), { next: '/staff/tables' })).toBe('/dashboard');
    expect(to(person({ legacyStaffRole: 'server' }), { next: '/staff/tables' })).toBe('/staff/tables');
    expect(to(person({ legacyStaffRole: 'server' }), { next: '/door/login' })).toBe('/staff/tables');
  });

  it('a business page is honoured only for a business they hold (or the create page)', () => {
    const s = person({ workspaces: [ws()], businesses: [biz()] });
    expect(to(s, { next: '/business/o1/onboarding' })).toBe('/business/o1/onboarding');
    expect(to(s, { next: '/business/someone-elses/onboarding' })).toBe('/w/m1/overview');
    expect(to(person(), { next: '/business/new?type=organizer' })).toBe('/business/new?type=organizer');
  });
});

describe('isDestinationPermitted', () => {
  it('lets public and personal pages through', () => {
    const s = person();
    for (const p of ['/', '/venues/xno', '/events', '/dashboard', '/profile', '/my-tickets', '/bookings/table/9']) {
      expect(isDestinationPermitted(p, s)).toBe(true);
    }
  });

  it('does not confuse a venue slug that starts with a role word with a protected area', () => {
    const s = person();
    expect(isDestinationPermitted('/venues/cms', s)).toBe(true);
    expect(isDestinationPermitted('/venues/staff-lounge', s)).toBe(true);
    expect(isDestinationPermitted('/cmsx', s)).toBe(true);
  });
});

describe('buildDestinations', () => {
  it('is empty when signed out', () => {
    expect(buildDestinations(EMPTY_SNAPSHOT)).toEqual([]);
  });

  it('always offers the personal account first', () => {
    expect(buildDestinations(person())[0]).toMatchObject({ key: 'personal', path: '/dashboard' });
  });

  it('titles a manager by their venue and a door person by their event', () => {
    const s = person({
      workspaces: [
        ws({ membershipId: 'a', role: 'manager', venueId: 'v1', venueName: 'Club A' }),
        ws({ membershipId: 'b', role: 'door', eventId: 'e1', eventTitle: 'Friday Night', shiftName: 'Doors 9pm' }),
      ],
    });
    const d = buildDestinations(s);
    expect(d.find((x) => x.key === 'a')).toMatchObject({ title: 'Club A', subtitle: 'Manager · Club Co' });
    expect(d.find((x) => x.key === 'b')).toMatchObject({ title: 'Friday Night', subtitle: 'Door Staff · Club Co · Doors 9pm' });
  });
});

describe('parsing what the database and the account return', () => {
  it('reads the sign-up intent, and distrusts anything else', () => {
    expect(parseSignupIntent({ signup_intent: 'personal' })).toEqual({ kind: 'personal' });
    expect(parseSignupIntent({ signup_intent: 'business', business_kind: 'organizer' })).toEqual({ kind: 'business', businessKind: 'organizer' });
    expect(parseSignupIntent({ signup_intent: 'business', business_kind: 'venue_owner' })).toEqual({ kind: 'business', businessKind: 'venue_owner' });
    expect(parseSignupIntent({ signup_intent: 'business', business_kind: 'admin' })).toBeNull();
    expect(parseSignupIntent({ signup_intent: 'business' })).toBeNull();
    expect(parseSignupIntent({ signup_intent: 'owner' })).toBeNull();
    expect(parseSignupIntent(null)).toBeNull();
    expect(parseSignupIntent('business')).toBeNull();
    expect(parseSignupIntent({})).toBeNull();
  });

  it('parses a workspace row', () => {
    const row = {
      membership_id: 'm1', org_id: 'o1', org_name: 'Club Co', org_kind: 'venue_owner', role: 'manager',
      venue_id: 'v1', venue_name: 'Club A', event_id: null, event_title: null, shift_id: null, shift_name: null, access_end_at: null,
    };
    expect(parseWorkspaceRow(row)).toMatchObject({ membershipId: 'm1', role: 'manager', venueName: 'Club A', eventId: null });
  });

  it('drops a workspace row with a role or kind it does not know, instead of guessing', () => {
    const base = { membership_id: 'm1', org_id: 'o1', org_name: 'X', org_kind: 'venue_owner', role: 'manager' };
    expect(parseWorkspaceRow({ ...base, role: 'superadmin' })).toBeNull();
    expect(parseWorkspaceRow({ ...base, org_kind: 'bank' })).toBeNull();
    expect(parseWorkspaceRow({ ...base, membership_id: 5 })).toBeNull();
  });

  it('parses a business row and drops an unknown state', () => {
    const row = {
      org_id: 'o1', org_name: 'Club Co', org_kind: 'venue_owner', verification_state: 'under_review',
      request_message: null, missing: ['venue'], venue_count: 2, pending_claims: 1,
    };
    expect(parseBusinessRow(row)).toMatchObject({ verificationState: 'under_review', missing: ['venue'], venueCount: 2, pendingClaims: 1 });
    expect(parseBusinessRow({ ...row, verification_state: 'approved' })).toBeNull();
    expect(parseBusinessRow({ ...row, org_kind: 'x' })).toBeNull();
  });

  it('tolerates a missing list or counts', () => {
    const b = parseBusinessRow({ org_id: 'o1', org_name: 'C', org_kind: 'organizer', verification_state: 'verified' });
    expect(b).toMatchObject({ missing: [], venueCount: 0, pendingClaims: 0 });
  });
});

describe('leaving onboarding (client report: a business added by mistake could not be left or cancelled)', () => {
  const unfinished = () => person({ workspaces: [ws()], businesses: [biz({ verificationState: 'not_submitted' })] });

  it('why "back to /home" was a trap: Home sends a person with one unfinished business straight back to its onboarding page', () => {
    expect(to(unfinished())).toBe('/business/o1/onboarding');
    expect(to(person({ workspaces: [ws()], businesses: [biz({ verificationState: 'more_information_needed' })] }))).toBe('/business/o1/onboarding');
  });

  it('so "back" from onboarding goes to the workspace list, which is not Home and never redirects', () => {
    expect(LEAVE_ONBOARDING_TO).toBe('/workspaces');
    expect(LEAVE_ONBOARDING_TO).not.toBe('/home');
    expect(LEAVE_ONBOARDING_LABEL.length).toBeGreaterThan(0);
  });

  it('the workspace list offers the personal account first, and the unfinished business as "Finish setup"', () => {
    const d = buildDestinations(unfinished());
    expect(d[0]).toMatchObject({ kind: 'personal', path: '/dashboard', attention: null });
    expect(d[1]).toMatchObject({ key: 'm1', path: '/business/o1/onboarding', attention: 'finish_setup' });
  });

  it('"back" from "Add your business" goes to the workspace list when there is one, otherwise to the personal account', () => {
    expect(leaveAddBusinessTo(person({ workspaces: [ws()] }))).toBe('/workspaces');
    expect(leaveAddBusinessTo(person({ workspaces: [] }))).toBe('/dashboard');
    // Home would return a person with a business sign-up and no business to Add your business again.
    const stuck = person({ workspaces: [], signupIntent: { kind: 'business', businessKind: 'venue_owner' } });
    expect(to(stuck)).toBe('/business/new?type=venue_owner');
    expect(leaveAddBusinessTo(stuck)).not.toBe('/home');
  });

  it('after the only business is cancelled, a cleared sign-up intent lands on the personal account; an uncleared one pushes them to create another', () => {
    const cancelled = { workspaces: [], businesses: [] };
    expect(to(person({ ...cancelled, signupIntent: { kind: 'business', businessKind: 'venue_owner' } }))).toBe('/business/new?type=venue_owner');
    expect(to(person({ ...cancelled, signupIntent: { kind: 'personal' } }))).toBe('/dashboard');
  });
});
