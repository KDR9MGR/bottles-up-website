import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import type { Session } from '@supabase/supabase-js';
import { AccountContext, type AccountContextValue } from '@/hooks/useAccount';
import { EMPTY_SNAPSHOT, type AccountSnapshot, type Workspace } from '@/lib/accountRouting';
import BusinessNew from './BusinessNew';

const session = { user: { id: 'u1', email: 'owner@example.com' } } as unknown as Session;
const workspace = (): Workspace => ({
  membershipId: 'm1', orgId: 'o1', orgName: 'Club Co', orgKind: 'venue_owner', role: 'owner',
  venueId: null, venueName: null, eventId: null, eventTitle: null, shiftId: null, shiftName: null, accessEndAt: null,
});

function backHref(snapshot: AccountSnapshot): string | undefined {
  const value: AccountContextValue = { loading: false, session, snapshot, refresh: async () => snapshot };
  const html = renderToString(
    <AccountContext.Provider value={value}>
      <StaticRouter location="/business/new">
        <BusinessNew />
      </StaticRouter>
    </AccountContext.Provider>,
  );
  return /<a[^>]*href="([^"]*)"/.exec(html)?.[1];
}

describe('"Add your business": where back goes', () => {
  it('a person with a workspace returns to their workspace list', () => {
    expect(backHref({ ...EMPTY_SNAPSHOT, signedIn: true, profileComplete: true, workspaces: [workspace()] })).toBe('/workspaces');
  });

  it('a person with none returns to their personal account, not Home (which would send them straight back here)', () => {
    const href = backHref({ ...EMPTY_SNAPSHOT, signedIn: true, profileComplete: true, signupIntent: { kind: 'business', businessKind: 'venue_owner' } });
    expect(href).toBe('/dashboard');
  });
});
