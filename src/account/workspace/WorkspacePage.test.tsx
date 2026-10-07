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
