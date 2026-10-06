import { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { X } from 'lucide-react';
import { useAccountOptional } from '@/hooks/useAccount';
import { shouldShowAccountPrompt } from '@/lib/accountPrompt';
import { currentPathAsNext, withNext } from '@/lib/safeNext';

const STORAGE_KEY = 'bu_account_prompt_dismissed_at';

function readDismissed(): string | null {
  try {
    return window.localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

/**
 * The homepage account prompt (client brief, section 1): Create a Personal Account, Create a Business
 * Account, or Log In. Shown to signed-out visitors only, and once dismissed it stays away for 30 days.
 */
const AccountPrompt = () => {
  const account = useAccountOptional();
  const location = useLocation();
  const [dismissedAt, setDismissedAt] = useState<string | null>(readDismissed);
  const [closing, setClosing] = useState(false);

  const show = shouldShowAccountPrompt({
    loading: account === null || account.loading,
    signedIn: account?.snapshot.signedIn ?? false,
    dismissedAt,
    now: Date.now(),
  });
  if (!show || closing) return null;

  const next = currentPathAsNext(location);
  const dismiss = () => {
    const stamp = String(Date.now());
    try {
      window.localStorage.setItem(STORAGE_KEY, stamp);
    } catch {
      /* storage blocked: it is hidden for this visit only */
    }
    setDismissedAt(stamp);
    setClosing(true);
  };

  return (
    <aside
      aria-label="Create an account"
      className="fixed inset-x-3 bottom-3 z-40 mx-auto max-w-xl rounded-2xl border border-white/10 bg-zinc-950/95 p-4 shadow-2xl backdrop-blur sm:bottom-5"
    >
      <button type="button" onClick={dismiss} aria-label="Dismiss" className="absolute right-3 top-3 rounded-full p-1 text-gray-500 hover:bg-white/10 hover:text-white">
        <X className="h-4 w-4" />
      </button>
      <p className="pr-8 text-sm font-medium text-white">Book tables and tickets, or run your venue, with one BottlesUp account.</p>
      <div className="mt-3 flex flex-wrap gap-2">
        <Link to={withNext('/signup/personal', next)} className="rounded-full bg-gradient-orange px-4 py-2 text-sm font-bold text-black hover:opacity-90">
          Create a Personal Account
        </Link>
        <Link to={withNext('/signup/business', next)} className="rounded-full border border-gray-700 px-4 py-2 text-sm text-white hover:bg-white/5">
          Create a Business Account
        </Link>
      </div>
      <p className="mt-3 text-xs text-gray-400">
        Already have an account?{' '}
        <Link to={withNext('/login', next)} className="text-primary hover:underline">Log in</Link>
      </p>
    </aside>
  );
};

export default AccountPrompt;
