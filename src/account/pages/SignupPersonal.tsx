import { Navigate, useSearchParams } from 'react-router-dom';
import { useAccount } from '@/hooks/useAccount';
import { sanitizeNext, withNext } from '@/lib/safeNext';
import AccountShell from '../components/AccountShell';
import SignupForm from '../components/SignupForm';

const SignupPersonal = () => {
  const { session, loading } = useAccount();
  const [params] = useSearchParams();
  const next = sanitizeNext(params.get('next'), '');
  if (!loading && session) return <Navigate to={withNext('/home', next)} replace />;

  return (
    <AccountShell
      title="Create a personal account"
      subtitle="Next you will verify your email and set up your profile."
      backTo={withNext('/signup', next)}
      backLabel="Back"
    >
      <SignupForm intent={{ kind: 'personal' }} next={next} nameLabel="Full name" submitLabel="Create account" />
    </AccountShell>
  );
};

export default SignupPersonal;
