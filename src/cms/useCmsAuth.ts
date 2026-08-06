import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';

interface CmsAuthState {
  session: Session | null;
  isAdmin: boolean;
  loading: boolean;
}

export function useCmsAuth() {
  const [state, setState] = useState<CmsAuthState>({
    session: null,
    isAdmin: false,
    loading: true,
  });

  useEffect(() => {
    let cancelled = false;
    // Supabase silently re-validates/refreshes the session (firing this same
    // callback) whenever the browser tab regains focus - not just on real
    // sign-in/out. Flipping `loading` back to true here would make
    // RequireCmsAuth unmount the entire CMS tree (including any open form)
    // every time an admin alt-tabs away and back, wiping unsaved work. Only
    // the very first resolution should show the full-page loading state.
    let hasResolvedOnce = false;

    const resolve = async (session: Session | null) => {
      if (!session) {
        if (!cancelled) setState({ session: null, isAdmin: false, loading: false });
        hasResolvedOnce = true;
        return;
      }

      const { data, error } = await supabase
        .from('cms_admins')
        .select('id')
        .eq('id', session.user.id)
        .maybeSingle();

      if (!cancelled) {
        setState({ session, isAdmin: !error && !!data, loading: false });
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

export async function cmsSignIn(email: string, password: string) {
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
}

export async function cmsSignOut() {
  await supabase.auth.signOut();
}
