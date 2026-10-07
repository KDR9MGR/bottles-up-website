import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { Loader2, MailWarning } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useToast } from '@/hooks/use-toast';
import { rememberWorkspace, useAccount } from '@/hooks/useAccount';
import { acceptInvitation, AccountError, type InviteOutcome } from '@/lib/account';
import { landingSection, workspacePath } from '@/lib/roleNavigation';
import { withNext } from '@/lib/safeNext';
import { supabase } from '@/lib/supabase';
import AccountShell from '../components/AccountShell';
import { FullPageSpinner } from './Home';

const PROBLEM: Partial<Record<InviteOutcome, { title: string; body: string }>> = {
  invalid: { title: 'This link is not valid', body: 'It may have been copied incorrectly. Ask the person who invited you to send it again.' },
  revoked: { title: 'This invitation was cancelled', body: 'Ask the person who invited you for a new one.' },
  expired: { title: 'This invitation has expired', body: 'Invitations are only valid for a limited time. Ask for a new link.' },
  email_mismatch: { title: 'Signed in with a different email', body: 'This invitation was sent to another email address. Log out and sign in with the invited address.' },
};

/**
 * Staff join through an invitation, never by choosing a role. The person has to be signed in with the
 * invited email, the link has to be unused and unexpired, and the database decides the role and scope.
 * Temporary staff use the same page with an individual, expiring link.
 */
const AcceptInvite = () => {
  const { loading, session, refresh } = useAccount();
  const [params] = useSearchParams();
  const token = params.get('token') ?? '';
  const navigate = useNavigate();
  const { toast } = useToast();
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState<InviteOutcome | null>(null);

  if (loading) return <FullPageSpinner />;

  const here = `/accept-invite?token=${encodeURIComponent(token)}`;

  if (!token) {
    return (
      <AccountShell title="This link is not valid" subtitle="There is no invitation in this link. Ask the person who invited you to send it again.">
        <Button asChild variant="outline" className="w-full border-gray-700 text-white hover:bg-gray-900"><Link to="/">Back to website</Link></Button>
      </AccountShell>
    );
  }

  if (!session) {
    return (
      <AccountShell title="You have been invited" subtitle="Log in, or create an account with the email this invitation was sent to, to accept it.">
        <div className="space-y-3">
          <Button asChild className="w-full bg-gradient-orange font-bold text-black hover:opacity-90"><Link to={withNext('/login', here)}>Log in</Link></Button>
          <Button asChild variant="outline" className="w-full border-gray-700 text-white hover:bg-gray-900"><Link to={withNext('/signup/personal', here)}>Create an account</Link></Button>
        </div>
      </AccountShell>
    );
  }

  const accept = async () => {
    setBusy(true);
    try {
      const result = await acceptInvitation(token);
      if (result.outcome === 'ok' || result.outcome === 'already_accepted') {
        const snapshot = await refresh();
        const joined = snapshot.workspaces.find((w) => w.membershipId === result.membershipId);
        if (joined) {
          rememberWorkspace(joined.membershipId);
          navigate(workspacePath(joined.membershipId, landingSection(joined.role)), { replace: true });
        } else {
          navigate('/home', { replace: true });
        }
        return;
      }
      setOutcome(result.outcome);
    } catch (err) {
      toast({ title: 'Could not accept the invitation', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const problem = outcome ? PROBLEM[outcome] : null;
  if (problem) {
    return (
      <AccountShell title={problem.title} subtitle={problem.body}>
        <MailWarning className="mx-auto mb-5 h-10 w-10 text-amber-400" />
        {outcome === 'email_mismatch' ? (
          <Button
            className="w-full bg-gradient-orange font-bold text-black hover:opacity-90"
            onClick={async () => { await supabase.auth.signOut(); navigate(withNext('/login', here), { replace: true }); }}
          >
            Log out and use the invited email
          </Button>
        ) : (
          <Button asChild variant="outline" className="w-full border-gray-700 text-white hover:bg-gray-900"><Link to="/home">Go to my account</Link></Button>
        )}
      </AccountShell>
    );
  }

  return (
    <AccountShell title="Accept your invitation" subtitle={<>You are signed in as <span className="text-white">{session.user.email}</span>. The invitation must have been sent to this address.</>}>
      <Button onClick={accept} disabled={busy} className="w-full bg-gradient-orange font-bold text-black hover:opacity-90">
        {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Accept invitation'}
      </Button>
      <p className="mt-4 text-center text-xs text-gray-500">
        Wrong account?{' '}
        <button type="button" className="text-primary hover:underline" onClick={async () => { await supabase.auth.signOut(); }}>
          Log out
        </button>
      </p>
    </AccountShell>
  );
};

export default AcceptInvite;
