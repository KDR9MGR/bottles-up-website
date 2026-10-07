import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import { Route, Routes } from 'react-router-dom';
import { AccountContext, type AccountContextValue } from '@/hooks/useAccount';
import { EMPTY_SNAPSHOT, type AccountSnapshot, type Business, type Workspace } from '@/lib/accountRouting';
import { sectionsFor, WORKSPACE_ROLES } from '@/lib/roleNavigation';
import WorkspacePage from './WorkspacePage';
import WorkspaceSelector from '../components/WorkspaceSelector';

const ws = (over: Partial<Workspace> = {}): Workspace => ({
  membershipId: 'm1', orgId: 'o1', orgName: 'Club Co', orgKind: 'venue_owner', role: 'owner',
  venueId: null, venueName: null, eventId: null, eventTitle: null, shiftId: null, shiftName: null, accessEndAt: null, ...over,
});
const biz = (over: Partial<Business> = {}): Business => ({
  orgId: 'o1', name: 'Club Co', kind: 'venue_owner', verificationState: 'verified', requestMessage: null, missing: [], venueCount: 1, pendingClaims: 0, ...over,
});

function render(path: string, snapshot: AccountSnapshot, loading = false): string {
  const value: AccountContextValue = { loading, session: null, snapshot, refresh: async () => snapshot };
  return renderToString(
    <AccountContext.Provider value={value}>
      <StaticRouter location={path}>
        <Routes>
          <Route path="/w/:membershipId/:section" element={<WorkspacePage />} />
          <Route path="/workspaces" element={<WorkspaceSelector />} />
        </Routes>
      </StaticRouter>
    </AccountContext.Provider>,
  );
}

const person = (workspaces: Workspace[], businesses: Business[] = []): AccountSnapshot => ({
  ...EMPTY_SNAPSHOT, signedIn: true, profileComplete: true, workspaces, businesses,
});

const escape = (s: string) => s.replace(/&/g, '&amp;');

describe('what each role sees in its workspace', () => {
  it.each(WORKSPACE_ROLES)('%s sees exactly its own navigation, and nobody else\'s', (role) => {
    const mine = sectionsFor(role).map((s) => s.label);
    const snapshot = person([ws({ role, venueId: 'v1', venueName: 'Club A', orgKind: role === 'organizer' ? 'organizer' : 'venue_owner' })], [biz()]);
    const first = sectionsFor(role)[0].id;
    const html = render(`/w/m1/${first}`, snapshot);
    for (const label of mine) expect(html).toContain(escape(label));
    // Anything another role has and this one does not must be absent from the page.
    const others = WORKSPACE_ROLES.filter((r) => r !== role).flatMap((r) => sectionsFor(r).map((s) => s.label));
    for (const label of others.filter((l) => !mine.includes(l))) expect(html).not.toContain(`>${escape(label)}<`);
  });

  it('door staff never see money screens', () => {
    const html = render('/w/m1/scan', person([ws({ role: 'door', eventId: 'e1', eventTitle: 'Friday Night' })]));
    for (const forbidden of ['Payments', 'Reports', 'Settings', 'Inventory', 'Discounts']) {
      expect(html).not.toContain(`>${forbidden}<`);
    }
    expect(html).toContain('Door Sale');
  });
});

describe('the context bar (always show the current business, venue, event and night)', () => {
  it('names the business, venue, event and shift, and the night', () => {
    const html = render('/w/m1/scan', person([ws({ role: 'door', venueName: 'Club A', eventTitle: 'Friday Night', shiftName: 'Doors 9pm' })]));
    expect(html).toContain('Club Co · Club A · Friday Night · Doors 9pm');
    expect(html).toMatch(/(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) [A-Z][a-z]{2} \d{1,2}/);
  });

  it('labels the role', () => {
    expect(render('/w/m1/scan', person([ws({ role: 'door' })]))).toContain('Door Staff');
  });
});

describe('access', () => {
  it('a workspace the person does not hold shows "no access", not an operational screen', () => {
    const html = render('/w/m-ended/tables', person([ws({ membershipId: 'm1', role: 'server' })]));
    expect(html).toContain('You no longer have access to this workspace');
    expect(html).not.toContain('My Tables');
  });

  it('shows a spinner, not content, while access is still being checked', () => {
    const html = render('/w/m1/overview', person([ws()]), true);
    expect(html).toContain('role="status"');
    expect(html).not.toContain('My Venues');
  });
});

describe('the owner overview and verification', () => {
  it('flags a business that is under review, with its progress link', () => {
    const html = render('/w/m1/overview', person([ws()], [biz({ verificationState: 'under_review' })]));
    expect(html).toContain('Under review');
    expect(html).toContain('/business/o1/onboarding');
    expect(html).toContain('See progress');
  });

  it('shows no banner once verified', () => {
    const html = render('/w/m1/overview', person([ws()], [biz({ verificationState: 'verified' })]));
    expect(html).not.toContain('Under review');
    expect(html).not.toContain('Open business details');
  });

  it('is honest about sections that are not built yet', () => {
    const html = render('/w/m1/payments', person([ws()], [biz()]));
    expect(html).toContain('Not available on the website yet');
    expect(html).toContain('Collections, balances, receipt evidence');
  });
});

describe('the team section', () => {
  it('opens for an owner, not as a "not available" placeholder', () => {
    const html = render('/w/m1/team', person([ws()], [biz()]));
    expect(html).toContain('Loading your team');
    expect(html).not.toContain('Not available on the website yet');
  });

  it('opens for a manager, who gets the same screen scoped by the database to their club', () => {
    const html = render('/w/m1/team', person([ws({ role: 'manager', venueId: 'v1', venueName: 'Club A' })]));
    expect(html).toContain('Loading your team');
  });

  it('shows the owner the verification banner above it, but not a manager', () => {
    expect(render('/w/m1/team', person([ws()], [biz({ verificationState: 'under_review' })]))).toContain('Under review');
    expect(render('/w/m1/team', person([ws({ role: 'manager', venueId: 'v1' })], [biz({ verificationState: 'under_review' })]))).not.toContain('Under review');
  });

  it.each(['server', 'door', 'security', 'verifier'] as const)('is not a section of the %s role at all', (role) => {
    const html = render('/w/m1/team', person([ws({ role, venueId: 'v1' })]));
    expect(html).not.toContain('Loading your team');
  });
});

describe('the door screens', () => {
  const door = (over: Partial<Workspace> = {}) => person([ws({ role: 'door', venueId: 'v1', venueName: 'Club A', ...over })]);

  it('Scan opens the scanner for a door person', () => {
    const html = render('/w/m1/scan', door());
    expect(html).toContain('Loading your events');
    expect(html).not.toContain('Not available on the website yet');
  });

  it('Guests opens the guest search', () => {
    expect(render('/w/m1/guests', door())).toContain('Loading your events');
  });

  it('Door Sale is not built and says so, rather than showing something that looks like a till', () => {
    const html = render('/w/m1/door-sale', door());
    expect(html).toContain('Not available on the website yet');
    expect(html).not.toContain('Loading your events');
  });

  it('a server also has a Scan section, but it is NOT the ticket scanner (it is for tables, not built here)', () => {
    const html = render('/w/m1/scan', person([ws({ role: 'server', venueId: 'v1' })]));
    expect(html).toContain('Not available on the website yet');
    expect(html).not.toContain('Loading your events');
  });

  it.each(['owner', 'manager', 'organizer', 'security', 'verifier'] as const)('the %s role has no door scanner', (role) => {
    const first = sectionsFor(role)[0].id;
    const html = render(`/w/m1/${first}`, person([ws({ role, venueId: 'v1', orgKind: role === 'organizer' ? 'organizer' : 'venue_owner' })], [biz()]));
    expect(html).not.toContain('Loading your events');
  });

  it('the organizer also has a Guests section, which is NOT the door guest list', () => {
    const html = render('/w/m1/guests', person([ws({ role: 'organizer', orgKind: 'organizer' })], [biz({ kind: 'organizer' })]));
    expect(html).toContain('Not available on the website yet');
    expect(html).not.toContain('Loading your events');
  });

  it('shows no scanner at all once the assignment is gone', () => {
    const html = render('/w/m-ended/scan', person([ws({ membershipId: 'other', role: 'door' })]));
    expect(html).toContain('You no longer have access to this workspace');
    expect(html).not.toContain('Loading your events');
  });
});

describe('the workspace selector', () => {
  it('lists personal and every workspace with its role and state', () => {
    const snapshot = person(
      [ws({ membershipId: 'a', orgName: 'Club Co' }), ws({ membershipId: 'b', orgId: 'o2', orgName: 'Night Events', role: 'organizer', orgKind: 'organizer' })],
      [biz(), biz({ orgId: 'o2', name: 'Night Events', kind: 'organizer', verificationState: 'not_submitted' })],
    );
    const html = render('/workspaces', snapshot);
    expect(html).toContain('Personal account');
    expect(html).toContain('Club Co');
    expect(html).toContain('Night Events');
    expect(html).toContain('Venue Owner');
    expect(html).toContain('Event Organizer');
    expect(html).toContain('Finish setup');
  });
});
