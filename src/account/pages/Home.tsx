import { Navigate, useSearchParams } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { profileWasSkipped, readLastWorkspace, useAccount } from '@/hooks/useAccount';
import { decideLanding } from '@/lib/accountRouting';
import { withNext } from '@/lib/safeNext';
import WorkspaceSelector from '../components/WorkspaceSelector';

export const FullPageSpinner = () => (
  <div className="flex min-h-screen items-center justify-center bg-black" role="status" aria-label="Loading">
    <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
  </div>
);

/**
 * Every sign-in and email link lands here. It reads what the person holds right now and sends them
 * to the right place (client brief, section 3). It never trusts a saved destination: access is
 * re-read from the database every time.
 */
const Home = () => {
  const { loading, snapshot } = useAccount();
  const [params] = useSearchParams();
  const next = params.get('next');

  if (loading) return <FullPageSpinner />;

  const landing = decideLanding(snapshot, {
    next,
    lastKey: readLastWorkspace(),
    profileSkipped: profileWasSkipped(),
  });

  switch (landing.kind) {
    case 'signed_out':
      return <Navigate to={withNext('/login', next)} replace />;
    case 'redirect':
      return <Navigate to={landing.to} replace />;
    case 'select':
      return <WorkspaceSelector destinations={landing.destinations} />;
  }
};

export default Home;
