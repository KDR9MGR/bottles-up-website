import { Link, Navigate, useSearchParams } from 'react-router-dom';
import { Briefcase, ChevronRight, User } from 'lucide-react';
import { useAccount } from '@/hooks/useAccount';
import { sanitizeNext, withNext } from '@/lib/safeNext';
import AccountShell from '../components/AccountShell';

const Choice = ({ to, icon: Icon, title, body }: { to: string; icon: typeof User; title: string; body: string }) => (
  <Link
    to={to}
    className="group flex items-center gap-4 rounded-xl border border-gray-800 bg-black/40 p-4 transition-colors hover:border-primary/60"
  >
    <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
      <Icon className="h-5 w-5" />
    </span>
    <span className="min-w-0 flex-1">
      <span className="block font-medium text-white">{title}</span>
      <span className="block text-sm text-gray-400">{body}</span>
    </span>
    <ChevronRight className="h-5 w-5 text-gray-600 transition-colors group-hover:text-primary" />
  </Link>
);

/** "Create a Personal Account" or "Create a Business Account" (client brief, section 1). */
const Signup = () => {
  const { session, loading } = useAccount();
  const [params] = useSearchParams();
  const next = sanitizeNext(params.get('next'), '');

  // Same identity everywhere: someone already signed in adds a business to their account.
  if (!loading && session) return <Navigate to={withNext('/home', next)} replace />;

  return (
    <AccountShell title="Create an account" subtitle="Choose the kind of account you need.">
      <div className="space-y-3">
        <Choice to={withNext('/signup/personal', next)} icon={User} title="Personal account" body="Discover venues and events, book tables and tickets." />
        <Choice to={withNext('/signup/business', next)} icon={Briefcase} title="Business account" body="Run a venue or organize events on BottlesUp." />
      </div>
      <p className="mt-6 text-center text-xs text-gray-500">
        Already have an account?{' '}
        <Link to={withNext('/login', next)} className="text-primary hover:underline">Log in</Link>
      </p>
    </AccountShell>
  );
};

export default Signup;
