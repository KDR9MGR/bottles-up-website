import { Navigate } from 'react-router-dom';
import { useAccount } from '@/hooks/useAccount';
import WorkspaceSelector from '../components/WorkspaceSelector';
import { FullPageSpinner } from './Home';

/** The selector on its own address, for the explicit "switch workspace" action. */
const WorkspacesPage = () => {
  const { loading, snapshot } = useAccount();
  if (loading) return <FullPageSpinner />;
  if (!snapshot.signedIn) return <Navigate to="/login?next=%2Fworkspaces" replace />;
  return <WorkspaceSelector />;
};

export default WorkspacesPage;
