import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Loader2, MailCheck } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { getAuthRedirectBase } from '@/lib/authRedirect';
import { isDisposableEmail } from '@/lib/disposableEmail';
import { isValidEmail, passwordProblem } from '@/lib/password';
import { withNext } from '@/lib/safeNext';
import type { SignupIntent } from '@/lib/accountRouting';

interface Props {
  intent: SignupIntent;
  next: string | null;
  /** Label for the name field: "Full name" for a person, "Your name" for a business representative. */
  nameLabel: string;
  submitLabel: string;
}

/**
 * Registration for both account types. The choice made on the public site is stored on the new
 * account (`signup_intent`) so that confirming the email on another device still resumes the right
 * onboarding. That value only picks which page is offered first; it grants nothing.
 */
const SignupForm = ({ intent, next, nameLabel, submitLabel }: Props) => {
  const navigate = useNavigate();
  const { toast } = useToast();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [exists, setExists] = useState(false);
  const [resending, setResending] = useState(false);

  const redirectTo = `${getAuthRedirectBase()}${withNext('/home', next)}`;
  const loginHref = withNext('/login', next);

  const metadata = {
    full_name: name.trim(),
    signup_intent: intent.kind,
    ...(intent.kind === 'business' ? { business_kind: intent.businessKind } : {}),
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setExists(false);
    const fail = (title: string, description?: string) => toast({ title, description, variant: 'destructive' });

    if (!name.trim()) return fail('Please enter your name');
    if (!isValidEmail(email)) return fail('Please enter a valid email');
    if (isDisposableEmail(email)) return fail('Please use a real email address', 'Disposable or temporary email addresses are not accepted.');
    const weak = passwordProblem(password);
    if (weak) return fail('Password too weak', weak);
    if (password !== confirm) return fail('Passwords do not match');

    setSubmitting(true);
    try {
      const { data, error } = await supabase.auth.signUp({
        email: email.trim(),
        password,
        options: { data: metadata, emailRedirectTo: redirectTo },
      });
      if (error) throw error;
      // With email confirmation on, an address that already has an account comes back as a user
      // with no identities instead of an error. Same person, same identity: send them to log in.
      if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
        setExists(true);
        return;
      }
      if (data.session) {
        navigate(withNext('/home', next), { replace: true });
        return;
      }
      setSentTo(email.trim());
    } catch (err) {
      fail('Could not create your account', err instanceof Error ? err.message : 'Please try again.');
    } finally {
      setSubmitting(false);
    }
  };

  const resend = async () => {
    if (!sentTo) return;
    setResending(true);
    const { error } = await supabase.auth.resend({ type: 'signup', email: sentTo, options: { emailRedirectTo: redirectTo } });
    setResending(false);
    toast(error ? { title: 'Could not resend', description: error.message, variant: 'destructive' } : { title: 'Verification email sent again' });
  };

  if (sentTo) {
    return (
      <div className="text-center">
        <MailCheck className="mx-auto mb-4 h-10 w-10 text-primary" />
        <h2 className="mb-2 text-lg font-semibold text-white">Check your email</h2>
        <p className="mb-6 text-sm text-gray-400">
          We sent a verification link to <span className="text-white">{sentTo}</span>. Open it on any device to
          {intent.kind === 'business' ? ' continue setting up your business.' : ' finish creating your profile.'}
        </p>
        <Button variant="outline" className="border-gray-700 text-white hover:bg-gray-900" onClick={resend} disabled={resending}>
          {resending ? 'Sending...' : 'Resend the email'}
        </Button>
        <p className="mt-6 text-xs text-gray-500">
          Wrong address?{' '}
          <button type="button" className="text-primary hover:underline" onClick={() => setSentTo(null)}>
            Go back
          </button>
        </p>
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4" noValidate>
      {exists && (
        <div role="alert" className="rounded-lg border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-200">
          There is already an account for this email. Use the same account instead of creating a second one.{' '}
          <Link to={intent.kind === 'business' ? withNext('/login', '/business/new') : loginHref} className="font-medium text-primary hover:underline">
            Log in
          </Link>
          {intent.kind === 'business' && ' and add your business to it.'}
        </div>
      )}
      <div className="space-y-2">
        <Label htmlFor="su-name" className="text-gray-300">{nameLabel}</Label>
        <Input id="su-name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" required />
      </div>
      <div className="space-y-2">
        <Label htmlFor="su-email" className="text-gray-300">Email</Label>
        <Input id="su-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" required />
      </div>
      <div className="space-y-2">
        <Label htmlFor="su-password" className="text-gray-300">Password</Label>
        <Input id="su-password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" required />
        <p className="text-xs text-gray-500">At least 8 characters, with an uppercase letter, a number, and a symbol.</p>
      </div>
      <div className="space-y-2">
        <Label htmlFor="su-confirm" className="text-gray-300">Confirm password</Label>
        <Input id="su-confirm" type="password" value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" required />
      </div>
      <Button type="submit" disabled={submitting} className="w-full bg-gradient-orange font-bold text-black hover:opacity-90">
        {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : submitLabel}
      </Button>
      <p className="text-center text-xs text-gray-500">
        Already have an account?{' '}
        <Link to={loginHref} className="text-primary hover:underline">Log in</Link>
      </p>
    </form>
  );
};

export default SignupForm;
