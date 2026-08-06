import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';

interface DoorAuthState {
  session: Session | null;
  isDoorStaff: boolean;
  loading: boolean;
}

export function useDoorAuth() {
  const [state, setState] = useState<DoorAuthState>({
    session: null,
    isDoorStaff: false,
    loading: true,
  });

  useEffect(() => {
    let cancelled = false;
    // Supabase silently re-validates/refreshes the session (firing this same
    // callback) whenever the browser tab regains focus - not just on real
    // sign-in/out. Flipping `loading` back to true here would unmount the
    // scan screen (losing any in-progress state) every time a door staffer's
    // device backgrounds and comes back. Only the very first resolution
    // should show the full-page loading state.
    let hasResolvedOnce = false;

    const resolve = async (session: Session | null) => {
      if (!session) {
        if (!cancelled) setState({ session: null, isDoorStaff: false, loading: false });
        hasResolvedOnce = true;
        return;
      }

      const { data, error } = await supabase
        .from('door_staff')
        .select('id')
        .eq('id', session.user.id)
        .maybeSingle();

      if (!cancelled) {
        setState({ session, isDoorStaff: !error && !!data, loading: false });
      }
      hasResolvedOnce = true;
    };

    supabase.auth.getSession().then(({ data }) => resolve(data.session));

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
      if (hasResolvedOnce) {
        resolve(session);
        return;
      }
      setState((prev) => ({ ...prev, loading: true }));
      resolve(session);
    });

    return () => {
      cancelled = true;
      subscription.subscription.unsubscribe();
    };
  }, []);

  return state;
}

export async function doorSignOut() {
  await supabase.auth.signOut();
}
