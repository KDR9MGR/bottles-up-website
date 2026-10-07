import { useState } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { useAccount } from '@/hooks/useAccount';
import { supabase } from '@/lib/supabase';
import { getAuthRedirectBase } from '@/lib/authRedirect';
import { isValidEmail } from '@/lib/password';
import { sanitizeNext, withNext } from '@/lib/safeNext';
import AccountShell from '../components/AccountShell';

/**
 * One log-in for everyone. Where the person ends up (personal dashboard, a venue, a business, a
 * team assignment) is decided afterwards by /home from what the database says they hold.
 */
const Login = () => {
  const { session, loading } = useAccount();
  const [params] = useSearchParams();
  const next = sanitizeNext(params.get('next'), '');
  const navigate = useNavigate();
  const { toast } = useToast();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [linkSent, setLinkSent] = useState(false);

  if (!loading && session) return <Navigate to={withNext('/home', next)} replace />;

  const handlePassword = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isValidEmail(email) || !password) {
      toast({ title: 'Enter your email and password', variant: 'destructive' });
      return;
    }
    setSubmitting(true);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setSubmitting(false);
    if (error) {
      toast({ title: 'Could not log in', description: 'Check your email and password and try again.', variant: 'destructive' });
      return;
    }
    navigate(withNext('/home', next), { replace: true });
  };

  const handleMagicLink = async () => {
    if (!isValidEmail(email)) {
      toast({ title: 'Enter your email first', variant: 'destructive' });
      return;
    }
    setSubmitting(true);
    // shouldCreateUser is off on purpose: logging in must never silently create an account.
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { emailRedirectTo: `${getAuthRedirectBase()}${withNext('/home', next)}`, shouldCreateUser: false },
    });
    setSubmitting(false);
    if (error) {
      toast({
        title: 'Could not send the link',
        description: /signups? not allowed|not found/i.test(error.message) ? 'We could not find an account for that email. Create one instead.' : error.message,
        variant: 'destructive',
      });
      return;
    }
    setLinkSent(true);
  };

  if (linkSent) {
    return (
      <AccountShell title="Check your email" subtitle={<>We sent a log-in link to <span className="text-white">{email}</span>.</>}>
        <Button variant="outline" className="w-full border-gray-700 text-white hover:bg-gray-900" onClick={() => setLinkSent(false)}>
          Use a different email
        </Button>
      </AccountShell>
    );
  }

  return (
    <AccountShell title="Log in" subtitle="Use your BottlesUp account. It works on the website and in the app.">
      <form onSubmit={handlePassword} className="space-y-4" noValidate>
        <div className="space-y-2">
          <Label htmlFor="li-email" className="text-gray-300">Email</Label>
          <Input id="li-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" required />
        </div>
        <div className="space-y-2">
          <Label htmlFor="li-password" className="text-gray-300">Password</Label>
          <Input id="li-password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" />
        </div>
        <Button type="submit" disabled={submitting} className="w-full bg-gradient-orange font-bold text-black hover:opacity-90">
          {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Log in'}
        </Button>
        <Button type="button" variant="ghost" disabled={submitting} onClick={handleMagicLink} className="w-full text-gray-300 hover:bg-white/5 hover:text-white">
          Email me a log-in link instead
        </Button>
      </form>
      <p className="mt-6 text-center text-xs text-gray-500">
        New to BottlesUp?{' '}
        <Link to={withNext('/signup', next)} className="text-primary hover:underline">Create an account</Link>
      </p>
    </AccountShell>
  );
};

export default Login;
