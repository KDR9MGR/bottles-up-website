// When the homepage account prompt is shown (client brief, section 1): prominently to signed-out
// visitors, never to someone already signed in, and without repeated interruptions once dismissed.

export const PROMPT_DISMISS_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;

export interface PromptState {
  /** The first session check has finished. Until then nobody is shown anything (no flash for signed-in people). */
  loading: boolean;
  signedIn: boolean;
  /** When the visitor last dismissed it, as stored (epoch milliseconds as text), or null. */
  dismissedAt: string | null;
  now: number;
}

export function shouldShowAccountPrompt(s: PromptState): boolean {
  if (s.loading || s.signedIn) return false;
  if (s.dismissedAt === null) return true;
  const at = Number(s.dismissedAt);
  // A damaged or future value must not hide the prompt forever.
  if (!Number.isFinite(at) || at <= 0 || at > s.now) return true;
  return s.now - at >= PROMPT_DISMISS_DAYS * DAY_MS;
}

/** Accepts only a plain https address, so a store link from configuration can never be a script URL. */
export function safeStoreUrl(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' ? url.toString() : null;
  } catch {
    return null;
  }
}
