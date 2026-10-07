import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { fetchAccountSnapshot } from '@/lib/account';
import { EMPTY_SNAPSHOT, type AccountSnapshot } from '@/lib/accountRouting';
import { AccountContext, type AccountContextValue } from './useAccount';

/**
 * One shared view of "who is signed in and what can they open", so every account page asks the
 * database once instead of each running its own query. Access is always re-read from the
 * database; nothing here is trusted from a previous visit.
 */
export function AccountProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<{ loading: boolean; session: Session | null; snapshot: AccountSnapshot }>({
    loading: true,
    session: null,
    snapshot: EMPTY_SNAPSHOT,
  });
  const sessionRef = useRef<Session | null>(null);
  const latest = useRef(0);

  const load = useCallback(async (session: Session | null): Promise<AccountSnapshot> => {
    sessionRef.current = session;
    const ticket = ++latest.current;
    const snapshot = await fetchAccountSnapshot(session);
    // A newer sign-in or sign-out may have started while this one was loading: ignore the stale answer.
    if (ticket === latest.current) setState({ loading: false, session, snapshot });
    return snapshot;
  }, []);

  useEffect(() => {
    let cancelled = false;
    supabase.auth.getSession().then(({ data }) => {
      if (!cancelled) void load(data.session);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      // Supabase re-validates the session whenever the tab regains focus. Re-reading access on
      // every one of those would flash loading states over open forms, so only real changes of
      // who is signed in trigger a reload.
      // INITIAL_SESSION is covered by getSession() above.
      if (event === 'TOKEN_REFRESHED' || event === 'INITIAL_SESSION') return;
      if (event === 'SIGNED_IN' && session?.user.id === sessionRef.current?.user.id) return;
      void load(session);
    });
    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, [load]);

  const refresh = useCallback(() => load(sessionRef.current), [load]);

  const value = useMemo<AccountContextValue>(() => ({ ...state, refresh }), [state, refresh]);
  return <AccountContext.Provider value={value}>{children}</AccountContext.Provider>;
}
