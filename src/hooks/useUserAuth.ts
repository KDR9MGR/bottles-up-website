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
  verified: boolean | null;
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
        .select('id, name, email, phone_number, age, avatar_url, verified')
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

// Signs out this session and every other active session/device for the
// account (the global scope revokes all refresh tokens, not just this one).
export async function userSignOutEverywhere() {
  await supabase.auth.signOut({ scope: 'global' });
}

// Triggers Supabase's standard change-email flow: a confirmation link is
// sent to the new address, and the change only takes effect once clicked.
export async function userChangeEmail(newEmail: string) {
  const { error } = await supabase.auth.updateUser({ email: newEmail });
  if (error) throw error;
}

export async function userUploadAvatar(userId: string, file: File): Promise<string> {
  const ext = file.name.split('.').pop() ?? 'jpg';
  const path = `${userId}/avatar.${ext}`;

  const { error: uploadError } = await supabase.storage
    .from('profile-pictures')
    .upload(path, file, { upsert: true, cacheControl: '3600' });
  if (uploadError) throw uploadError;

  const { data } = supabase.storage.from('profile-pictures').getPublicUrl(path);
  // Cache-bust so the new photo shows immediately instead of the browser's
  // cached copy of the previous file at the same path.
  const publicUrl = `${data.publicUrl}?t=${Date.now()}`;

  const { error: updateError } = await supabase
    .from('profiles')
    .update({ avatar_url: publicUrl })
    .eq('id', userId);
  if (updateError) throw updateError;

  return publicUrl;
}

// Permanently deletes the signed-in user's own account via the
// delete-account edge function (needs the service role key to call
// auth.admin.deleteUser, which the browser can never hold).
export async function userDeleteAccount() {
  const { data, error } = await supabase.functions.invoke('delete-account', { method: 'POST' });
  if (error) throw error;
  if (data?.error) throw new Error(data.error);
}

// Every field the user themselves entered, for the "download my data"
// export - the profile row plus every order/booking scoped to their
// verified email (RLS already restricts these to their own rows).
export async function userExportData(userId: string) {
  const [{ data: profile }, { data: orders }, { data: tableBookings }] = await Promise.all([
    supabase.from('profiles').select('*').eq('id', userId).maybeSingle(),
    supabase.from('site_orders').select('*'),
    supabase.from('site_table_bookings').select('*'),
  ]);
  return { profile, eventTickets: orders ?? [], tableBookings: tableBookings ?? [] };
}
