import { useEffect, useState } from 'react';
import type { Session, User } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';

export interface UserProfile {
  id: string;
  name: string;
  email: string;
  phone_number: string | null;
  age: number | null;
  avatar_url: string | null;
}

interface UserAuthState {
  session: Session | null;
  user: User | null;
  profile: UserProfile | null;
  loading: boolean;
}

export function useUserAuth() {
  const [state, setState] = useState<UserAuthState>({
    session: null,
    user: null,
    profile: null,
    loading: true,
  });

  useEffect(() => {
    let cancelled = false;

    const fetchProfile = async (user: User): Promise<UserProfile | null> => {
      const { data } = await supabase
        .from('profiles')
        .select('id, name, email, phone_number, age, avatar_url')
        .eq('id', user.id)
        .maybeSingle();
      return data as UserProfile | null;
    };

    const resolve = async (session: Session | null) => {
      if (!session) {
        if (!cancelled) setState({ session: null, user: null, profile: null, loading: false });
        return;
      }
      const profile = await fetchProfile(session.user);
      if (!cancelled) setState({ session, user: session.user, profile, loading: false });
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

  const refreshProfile = async () => {
    if (!state.user) return;
    const { data } = await supabase
      .from('profiles')
      .select('id, name, email, phone_number, age, avatar_url')
      .eq('id', state.user.id)
      .maybeSingle();
    setState((prev) => ({ ...prev, profile: data as UserProfile | null }));
  };

  return { ...state, refreshProfile };
}

export async function userSignUp(name: string, email: string, password: string) {
  const { data, error } = await supabase.auth.signUp({ email, password });
  if (error) throw error;
  if (data.user) {
    await supabase.from('profiles').upsert({
      id: data.user.id,
      name,
      email,
    });
  }
}

export async function userSignIn(email: string, password: string) {
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
}

export async function userSignInWithMagicLink(email: string, redirectTo: string) {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: redirectTo },
  });
  if (error) throw error;
}

export async function userSignOut() {
  await supabase.auth.signOut();
}
