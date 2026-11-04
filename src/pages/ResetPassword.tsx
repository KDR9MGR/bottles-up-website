import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { CheckCircle2, Loader2, MailWarning, Smartphone } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { supabase } from '@/lib/supabase';
import {
  APP_NAME,
  completeReset,
  didFail,
  isMobileBrowser,
  newPasswordProblem,
  openAppUrl,
  openInAppUrl,
  parseResetLink,
  type RecoveryAuth,
  type ResetLink,
} from '@/lib/passwordReset';
import AccountShell from '@/account/components/AccountShell';

/**
 * Where the button in the "reset your password" email lands, for the BottlesUp app, the BottlesUp Business app and the website
 * alike. On a phone it offers to open the app; anywhere else (or without the app) the new password is chosen right here.
 * The rules live in lib/passwordReset.ts, where they are tested.
 */
const ResetPassword = () => {
  const location = useLocation();
  const [link, setLink] = useState<ResetLink>(() => parseResetLink(location.search, location.hash));
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  // True once the token has been spent and a reset session exists in this browser but the password is not set yet.
  const sessionOpen = useRef(false);

  const auth = useMemo<RecoveryAuth>(
    () => ({
      verifyOtp: async (params) => ({ error: (await supabase.auth.verifyOtp(params)).error }),
      hasSession: async () => (await supabase.auth.getSession()).data.session !== null,
      updatePassword: async (value) => ({ error: (await supabase.auth.updateUser({ password: value })).error }),
      signOutHere: async () => {
        await supabase.auth.signOut({ scope: 'local' });
      },
    }),
    [],
  );

  // The address holds a one-time token and this page is not for search engines.
  useEffect(() => {
    const previousTitle = document.title;
    document.title = 'Choose a new password | BottlesUp';
    const robots = document.createElement('meta');
    robots.name = 'robots';
    robots.content = 'noindex';
    const referrer = document.createElement('meta');
    referrer.name = 'referrer';
    referrer.content = 'no-referrer';
    document.head.append(robots, referrer);
    return () => {
      document.title = previousTitle;
      robots.remove();
      referrer.remove();
    };
  }, []);

  // A link that came through Supabase's own template carries a session in the address, which supabase-js has read by now.
  // If it did not, the link is no good.
  useEffect(() => {
    if (link.kind !== 'session') return;
    let cancelled = false;
    void auth.hasSession().then((has) => {
      if (!cancelled && !has) setLink({ kind: 'failed', app: link.app });
      else sessionOpen.current = true;
    });
    return () => {
      cancelled = true;
    };
  }, [auth, link]);

  // Leaving before the password is set must not leave a signed-in reset session on this browser.
  useEffect(() => {
    const leave = () => {
      if (sessionOpen.current) void supabase.auth.signOut({ scope: 'local' });
    };
    window.addEventListener('pagehide', leave);
    return () => {
      window.removeEventListener('pagehide', leave);
      leave();
    };
  }, []);

  const appName = APP_NAME[link.app];
  const onPhone = isMobileBrowser(navigator.userAgent);
  const inAppUrl = onPhone ? openInAppUrl(link) : null;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const invalid = newPasswordProblem(password, confirm);
    if (invalid) {
      setProblem(invalid);
      return;
    }
    setProblem(null);
    setBusy(true);
    const result = await completeReset(auth, link, password);
    setBusy(false);
    if (!didFail(result)) {
      sessionOpen.current = false;
      setPassword('');
      setConfirm('');
      setDone(true);
      return;
    }
    if (result.sessionOpened) {
      // The token is spent; carry on from the session so the next try needs no new email.
      sessionOpen.current = true;
      setLink({ kind: 'session', app: link.app });
    }
    if (!result.canRetry) {
      sessionOpen.current = false;
      setLink({ kind: 'failed', app: link.app });
      return;
    }
    setProblem(result.message);
  };

  if (done) {
    const appUrl = onPhone ? openAppUrl(link.app) : null;
    return (
      <AccountShell title="Password updated" subtitle={`You can now log in to ${appName} with your new password.`}>
        <div className="space-y-4">
          <div className="flex items-center gap-3 rounded-lg border border-green-900/60 bg-green-950/30 p-4 text-sm text-green-300">
            <CheckCircle2 className="h-5 w-5 shrink-0" />
            <span>Your password was changed. If this wasn&apos;t you, reset it again right away.</span>
          </div>
          {appUrl && (
            <Button asChild className="w-full bg-gradient-orange font-bold text-black hover:opacity-90">
              <a href={appUrl}>Open {appName}</a>
            </Button>
          )}
        </div>
      </AccountShell>
    );
  }

  if (link.kind === 'failed' || link.kind === 'missing') {
    return (
      <AccountShell
        title={link.kind === 'failed' ? 'This link has expired' : 'This link is not complete'}
        subtitle={
          link.kind === 'failed'
            ? `Reset links work once and only for a short time. Open ${appName} and choose “Forgot password” to get a new one.`
            : `Open the link from your email again, or open ${appName} and choose “Forgot password” to get a new one.`
        }
      >
        <div className="flex items-center gap-3 rounded-lg border border-gray-800 bg-gray-900/60 p-4 text-sm text-gray-300">
          <MailWarning className="h-5 w-5 shrink-0 text-primary" />
          <span>Only the newest email works. If you asked for several, use the last one.</span>
        </div>
      </AccountShell>
    );
  }

  return (
    <AccountShell title="Choose a new password" subtitle={`For your ${appName} account.`}>
      <div className="space-y-5">
        {inAppUrl && (
          <div className="space-y-2 rounded-lg border border-gray-800 bg-gray-900/60 p-4">
            <Button asChild variant="outline" className="w-full border-gray-700 text-white hover:bg-gray-900">
              <a href={inAppUrl}>
                <Smartphone className="mr-2 h-4 w-4" />
                Open in the {appName} app
              </a>
            </Button>
            <p className="text-center text-xs text-gray-400">Don&apos;t have the app? Choose your new password below.</p>
          </div>
        )}

        <form onSubmit={submit} className="space-y-4" noValidate>
          <div className="space-y-2">
            <Label htmlFor="rp-password" className="text-gray-300">New password</Label>
            <Input
              id="rp-password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="new-password"
              autoFocus={!inAppUrl}
              aria-describedby="rp-hint"
            />
            <p id="rp-hint" className="text-xs text-gray-500">At least 8 characters.</p>
          </div>
          <div className="space-y-2">
            <Label htmlFor="rp-confirm" className="text-gray-300">Confirm new password</Label>
            <Input id="rp-confirm" type="password" value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" />
          </div>
          {problem && (
            <p role="alert" className="text-sm text-red-400">
              {problem}
            </p>
          )}
          <Button type="submit" disabled={busy} className="w-full bg-gradient-orange font-bold text-black hover:opacity-90">
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Update password'}
          </Button>
        </form>

        <p className="text-center text-xs text-gray-500">
          Didn&apos;t ask for this? You can close this page: your password stays the same. <Link to="/" className="text-primary hover:underline">Back to website</Link>
        </p>
      </div>
    </AccountShell>
  );
};

export default ResetPassword;
