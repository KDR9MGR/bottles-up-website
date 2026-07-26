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

    const resolve = async (session: Session | null) => {
      if (!session) {
        if (!cancelled) setState({ session: null, isDoorStaff: false, loading: false });
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
    };

    supabase.auth.getSession().then(({ data }) => resolve(data.session));

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
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
