import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

type PartnerAccount = Database['public']['Tables']['partner_accounts']['Row'];

interface PartnerAuthState {
  session: Session | null;
  account: PartnerAccount | null;
  loading: boolean;
}

export function usePartnerAuth() {
  const [state, setState] = useState<PartnerAuthState>({
    session: null,
    account: null,
    loading: true,
  });

  useEffect(() => {
    let cancelled = false;

    const resolve = async (session: Session | null) => {
      if (!session) {
        if (!cancelled) setState({ session: null, account: null, loading: false });
        return;
      }
      const { data } = await supabase
        .from('partner_accounts')
        .select('*')
        .eq('id', session.user.id)
        .maybeSingle();
      if (!cancelled) setState({ session, account: data, loading: false });
    };

    supabase.auth.getSession().then(({ data }) => resolve(data.session));

    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      resolve(session);
    });

    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, []);

  return state;
}

export async function partnerSignOut() {
  await supabase.auth.signOut();
}
