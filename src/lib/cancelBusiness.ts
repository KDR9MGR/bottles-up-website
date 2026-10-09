// Cancelling a business that was added by mistake, and getting the person out of the way of it. Kept apart from the screen so
// the order of the steps, what is called and where the person ends up can be tested.

import { AccountError, cancelBusiness } from './account';
import { supabase } from './supabase';

/** What the account's metadata says about the sign-up once the business is gone: no business is waiting to be created. */
export const CLEARED_BUSINESS_INTENT = { signup_intent: 'personal', business_kind: null } as const;

export interface CancelBusinessSteps {
  /** The database function. Throws with a plain sentence when it refuses. */
  cancel: (orgId: string) => Promise<void>;
  /** Forget that this person signed up to create a business, so signing in again does not send them back to create one. */
  clearBusinessIntent: () => Promise<void>;
  /** Read what the person can open again. */
  refresh: () => Promise<unknown>;
}

/**
 * 1. cancel: if the database refuses, nothing else happens and the error reaches the screen.
 * 2. clear the sign-up intent: only AFTER the business is gone. Failing to do it is not an error worth stopping for: the
 *    business is cancelled either way, and the worst result is that the next sign-in offers to add a business again.
 * 3. refresh: so the workspace list no longer shows the cancelled business.
 */
export async function runCancelBusiness(orgId: string, steps: CancelBusinessSteps): Promise<void> {
  await steps.cancel(orgId);
  try {
    await steps.clearBusinessIntent();
  } catch {
    /* see above */
  }
  await steps.refresh();
}

/** The real steps: the database function, the account's own metadata, and the caller's way to re-read the account. */
export function cancelBusinessSteps(refresh: () => Promise<unknown>): CancelBusinessSteps {
  return {
    cancel: cancelBusiness,
    clearBusinessIntent: async () => {
      const { error } = await supabase.auth.updateUser({ data: { ...CLEARED_BUSINESS_INTENT } });
      if (error) throw error;
    },
    refresh,
  };
}

/** Where a person goes once the business is gone: Home decides from what they still hold (another business, or the personal account). */
export const AFTER_CANCEL_TO = '/home';

/** A plain shape rather than a discriminated union: this project does not compile in strict mode, where such a union cannot be narrowed. */
export interface CancelOutcome {
  ok: boolean;
  /** Where to go when it worked. */
  goTo: string | null;
  /** What to tell the person when it did not. */
  message: string | null;
}

/** Runs the cancellation and says what the screen should do next. Never throws: a refusal becomes a message for the person. */
export async function confirmCancelBusiness(orgId: string, steps: CancelBusinessSteps): Promise<CancelOutcome> {
  try {
    await runCancelBusiness(orgId, steps);
    return { ok: true, goTo: AFTER_CANCEL_TO, message: null };
  } catch (err) {
    return { ok: false, goTo: null, message: err instanceof AccountError ? err.message : 'Please try again.' };
  }
}
