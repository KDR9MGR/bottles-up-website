import { Link, Navigate } from 'react-router-dom';
import { Loader2, CheckCircle2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { usePartnerAuth, partnerSignOut } from '../usePartnerAuth';

const ROLE_LABELS: Record<string, string> = {
  venue_operator: 'Venue Owner',
  promoter: 'Promoter',
  organizer: 'Organizer / Artist',
};

const PartnerOnboarding = () => {
  const { session, account, loading } = usePartnerAuth();

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black">
        <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
      </div>
    );
  }

  if (!session) {
    return <Navigate to="/partners/login" replace />;
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 py-12">
      <div className="w-full max-w-lg rounded-2xl border border-gray-800 bg-gray-900/50 p-8 text-center">
        {account ? (
          <>
            <CheckCircle2 className="mx-auto mb-4 h-10 w-10 text-green-400" />
            <h1 className="mb-1 text-2xl font-bold text-white">Application Received</h1>
            <p className="mb-6 text-sm text-gray-400">
              Signed up as <span className="text-white">{ROLE_LABELS[account.user_type] ?? account.user_type}</span>
              {' - '}
              Step {account.onboarding_step} of 8 complete.
            </p>
            <p className="mb-6 rounded-lg border border-gray-800 bg-black/40 p-4 text-sm text-gray-400">
              We're still building the rest of onboarding (profile details, ID verification, and payouts). We'll
              email {session.user.email} as soon as the next step is ready.
            </p>
          </>
        ) : (
          <>
            <h1 className="mb-1 text-2xl font-bold text-white">Application Not Found</h1>
            <p className="mb-6 text-sm text-gray-400">
              We couldn't find a partner application for this account. If you just signed up, make sure you
              completed the application form.
            </p>
            <Button asChild className="mb-4 bg-gradient-orange text-black font-bold hover:opacity-90">
              <Link to="/partners/apply">Start Application</Link>
            </Button>
          </>
        )}
        <div>
          <Button variant="ghost" size="sm" className="text-gray-400" onClick={() => partnerSignOut()}>
            Sign out
          </Button>
        </div>
      </div>
    </div>
  );
};

export default PartnerOnboarding;
