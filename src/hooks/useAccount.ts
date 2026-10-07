import { createContext, useContext } from 'react';
import type { Session } from '@supabase/supabase-js';
import type { AccountSnapshot } from '@/lib/accountRouting';

export interface AccountContextValue {
  /** True until the first session check and snapshot have finished. */
  loading: boolean;
  session: Session | null;
  snapshot: AccountSnapshot;
  /** Re-read what the person can open, for example after accepting an invitation or creating a business. */
  refresh: () => Promise<AccountSnapshot>;
}

// The provider component lives in AccountProvider.tsx; keeping the hooks here, in a file that exports no
// components, is what lets the page stay fast-refresh friendly.
export const AccountContext = createContext<AccountContextValue | null>(null);

/** For shared components (the header) that also render when account onboarding is switched off: null then. */
export function useAccountOptional(): AccountContextValue | null {
  return useContext(AccountContext);
}

export function useAccount(): AccountContextValue {
  const ctx = useContext(AccountContext);
  if (!ctx) throw new Error('useAccount must be used inside <AccountProvider>');
  return ctx;
}

const LAST_KEY_STORAGE = 'bu_last_workspace';
const PROFILE_SKIP_STORAGE = 'bu_profile_skipped';

// Remembering the last workspace is a convenience, never a grant: the key is only used when the
// database still lists that workspace for the person (see decideLanding).
export function readLastWorkspace(): string | null {
  try {
    return window.localStorage.getItem(LAST_KEY_STORAGE);
  } catch {
    return null;
  }
}

export function rememberWorkspace(key: string): void {
  try {
    window.localStorage.setItem(LAST_KEY_STORAGE, key);
  } catch {
    /* private mode or storage blocked: the selector simply asks again next time */
  }
}

export function profileWasSkipped(): boolean {
  try {
    return window.sessionStorage.getItem(PROFILE_SKIP_STORAGE) === '1';
  } catch {
    return false;
  }
}

export function skipProfileThisSession(): void {
  try {
    window.sessionStorage.setItem(PROFILE_SKIP_STORAGE, '1');
  } catch {
    /* ignore */
  }
}
