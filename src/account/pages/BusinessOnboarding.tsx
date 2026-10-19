import { useCallback, useEffect, useState } from 'react';
import { Navigate, useParams } from 'react-router-dom';
import { useAccount } from '@/hooks/useAccount';
import { fetchBusiness, fetchBusinessDetails, type BusinessDetails } from '@/lib/account';
import { LEAVE_ONBOARDING_LABEL, LEAVE_ONBOARDING_TO, type Business } from '@/lib/accountRouting';
import AccountShell from '../components/AccountShell';
import BusinessDetailsForm from '../components/BusinessDetailsForm';
import CancelBusiness from '../components/CancelBusiness';
import StateBadge from '../components/StateBadge';
import VenueStep from '../components/VenueStep';
import VerificationPanel from '../components/VerificationPanel';
import { FullPageSpinner } from './Home';

const Section = ({ n, title, children }: { n: number; title: string; children: React.ReactNode }) => (
  <section className="rounded-xl border border-gray-800 bg-black/30 p-4 sm:p-5">
    <h2 className="mb-4 flex items-center gap-3 text-base font-semibold text-white">
      <span className="flex h-6 w-6 items-center justify-center rounded-full bg-primary/15 text-xs text-primary">{n}</span>
      {title}
    </h2>
    {children}
  </section>
);

interface ViewProps {
  orgId: string;
  business: Business;
  details: BusinessDetails;
  onChanged: () => void | Promise<void>;
}

/** The page once the business has loaded. Separate from the loading so it can be rendered on its own in tests. */
export const OnboardingView = ({ orgId, business, details, onChanged }: ViewProps) => {
  const isVenueOwner = business.kind === 'venue_owner';

  return (
    <AccountShell
      title={business.name}
      subtitle={
        <span className="flex flex-wrap items-center gap-2">
          {isVenueOwner ? 'Venue owner' : 'Event organizer'} <StateBadge state={business.verificationState} />
        </span>
      }
      wide
      backTo={LEAVE_ONBOARDING_TO}
      backLabel={LEAVE_ONBOARDING_LABEL}
    >
      <div className="space-y-5">
        <Section n={1} title="Business details">
          <BusinessDetailsForm
            orgId={orgId}
            kind={business.kind}
            details={details}
            state={business.verificationState}
            missing={business.missing}
            onSaved={onChanged}
          />
        </Section>

        {isVenueOwner && (
          <Section n={2} title="Add or claim your venue">
            <VenueStep orgId={orgId} onChanged={onChanged} />
          </Section>
        )}

        <Section n={isVenueOwner ? 3 : 2} title="Verification">
          <VerificationPanel
            orgId={orgId}
            state={business.verificationState}
            requestMessage={business.requestMessage}
            missing={business.missing}
            onSubmitted={onChanged}
          />
        </Section>

        <CancelBusiness orgId={orgId} name={business.name} state={business.verificationState} />
      </div>
    </AccountShell>
  );
};

/**
 * Business onboarding and verification (client brief, section 2). Account, business details, add or claim a
 * venue, submit for verification. Each step saves as a draft, can be left and resumed, and says plainly what
 * is still missing. Everything is read from and written to the database; nothing here grants access.
 */
const BusinessOnboarding = () => {
  const { orgId = '' } = useParams();
  const { loading, snapshot, refresh } = useAccount();
  const [business, setBusiness] = useState<Business | null>(null);
  const [details, setDetails] = useState<BusinessDetails | null>(null);
  const [failed, setFailed] = useState(false);

  const load = useCallback(async () => {
    try {
      const [b, d] = await Promise.all([fetchBusiness(orgId), fetchBusinessDetails(orgId)]);
      setBusiness(b);
      setDetails(d);
      setFailed(!b || !d);
    } catch {
      setFailed(true);
    }
  }, [orgId]);

  useEffect(() => {
    if (snapshot.signedIn) void load();
  }, [snapshot.signedIn, load]);

  const reload = async () => {
    await Promise.all([load(), refresh()]);
  };

  if (loading) return <FullPageSpinner />;
  if (!snapshot.signedIn) return <Navigate to={`/login?next=${encodeURIComponent(`/business/${orgId}/onboarding`)}`} replace />;
  if (failed) {
    return (
      <AccountShell title="We could not find this business" subtitle="It may belong to a different account, or the link may be wrong." backTo={LEAVE_ONBOARDING_TO} backLabel={LEAVE_ONBOARDING_LABEL}>
        <p className="text-sm text-gray-400">Go back and choose one of your own workspaces.</p>
      </AccountShell>
    );
  }
  if (!business || !details) return <FullPageSpinner />;

  return <OnboardingView orgId={orgId} business={business} details={details} onChanged={reload} />;
};

export default BusinessOnboarding;
