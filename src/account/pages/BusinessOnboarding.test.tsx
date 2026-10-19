import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import { AccountContext, type AccountContextValue } from '@/hooks/useAccount';
import { EMPTY_SNAPSHOT, type Business } from '@/lib/accountRouting';
import type { BusinessDetails } from '@/lib/account';
import { VERIFICATION_STATES } from '@/lib/verification';
import { OnboardingView } from './BusinessOnboarding';

const biz = (over: Partial<Business> = {}): Business => ({
  orgId: 'o1', name: 'Eonics Lounge', kind: 'venue_owner', verificationState: 'not_submitted', requestMessage: null, missing: ['legal_name'], venueCount: 0, pendingClaims: 0, ...over,
});
const details: BusinessDetails = {
  legal_name: null, description: null, logo_url: null, representative_name: null, representative_role: null, representative_phone: null,
  contact_email: null, contact_phone: null, address: null, city: null, website: null, social_links: {}, representative_confirmed_at: null,
};

function render(business: Business): string {
  const snapshot = { ...EMPTY_SNAPSHOT, signedIn: true, profileComplete: true };
  const value: AccountContextValue = { loading: false, session: null, snapshot, refresh: async () => snapshot };
  return renderToString(
    <AccountContext.Provider value={value}>
      <StaticRouter location="/business/o1/onboarding">
        <OnboardingView orgId="o1" business={business} details={details} onChanged={() => undefined} />
      </StaticRouter>
    </AccountContext.Provider>,
  );
}

const backLink = (html: string) => /<a[^>]*href="([^"]*)"[^>]*>(?:<svg[\s\S]*?<\/svg>)?([^<]*)<\/a>/.exec(html);

describe('the business onboarding page', () => {
  it('"back" goes to the workspace list, not to Home (which sent the person straight back here)', () => {
    const link = backLink(render(biz()));
    expect(link?.[1]).toBe('/workspaces');
    expect(link?.[2]).toBe('All workspaces');
  });

  it.each(VERIFICATION_STATES)('"back" is the same in every state (%s)', (state) => {
    expect(backLink(render(biz({ verificationState: state })))?.[1]).toBe('/workspaces');
  });

  it('names the business and what it is', () => {
    const html = render(biz());
    expect(html).toContain('Eonics Lounge');
    expect(html).toContain('Venue owner');
  });

  it.each(['not_submitted', 'more_information_needed'] as const)('%s: the person can cancel the business, and is told what that deletes', (state) => {
    const html = render(biz({ verificationState: state }));
    expect(html).toContain('Added this business by mistake?');
    expect(html).toContain('Cancel this business');
    expect(html).toContain('This cannot be undone');
    expect(html).not.toContain('data-testid="cancel-unavailable"');
  });

  it.each(['under_review', 'verified'] as const)('%s: cancelling is not offered, and the page says who to ask instead', (state) => {
    const html = render(biz({ verificationState: state }));
    expect(html).not.toContain('Cancel this business');
    expect(html).toContain('data-testid="cancel-unavailable"');
    expect(html).toContain('Contact BottlesUp');
  });

  it('an event organizer can cancel its business too', () => {
    const html = render(biz({ kind: 'organizer', name: 'Night Events' }));
    expect(html).toContain('Event organizer');
    expect(html).toContain('Cancel this business');
  });

  it('the confirmation is not shown until the button is pressed', () => {
    expect(render(biz())).not.toContain('Yes, cancel it');
  });
});

// The page is rendered on the server here, so a click cannot be simulated. This is the one place a slip would delete a business
// with a single click, so the wiring is checked in the source: the button only opens the confirmation, and the cancellation is
// started from the confirmation and from nowhere else.
describe('the cancel button is wired to the confirmation, not to the cancellation', () => {
  const src = readFileSync(join(__dirname, '..', 'components', 'CancelBusiness.tsx'), 'utf8');

  it('the button opens the confirmation', () => {
    expect(src).toMatch(/onClick=\{\(\) => setOpen\(true\)\}/);
  });

  it('the cancellation is started by the confirmation only', () => {
    expect(src).toMatch(/onConfirm=\{\(\) => void confirm\(\)\}/);
    expect((src.match(/\bconfirm\(\)/g) ?? []).length).toBe(1);
  });

  it('the confirmation can be used again after a refusal: the busy flag is cleared whatever the outcome', () => {
    const afterAnswer = src.slice(src.indexOf('confirmCancelBusiness('), src.indexOf('if (outcome.ok)'));
    expect(afterAnswer).toContain('setBusy(false)');
  });

  it('closing or keeping the confirmation just closes it', () => {
    expect(src).toMatch(/onClose=\{\(\) => setOpen\(false\)\}/);
  });
});
