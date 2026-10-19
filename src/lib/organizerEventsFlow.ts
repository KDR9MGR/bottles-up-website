import { AccountError } from './account';
import { eventPayload, sentence, validateEventForm, type EventForm } from './organizerEvents';

export interface SubmitResult {
  ok: boolean;
  /** What is wrong, in plain words, for the form to show. Empty when it was saved. */
  problems: string[];
}

type SaveFn = (orgId: string, eventId: string | null, details: Record<string, unknown>) => Promise<unknown>;

/**
 * The form's Save: every problem is said before anything is sent; a refusal from the database comes back as a sentence for the
 * form to show (so nothing typed is lost); nothing else ever throws at the screen.
 */
export async function submitEventForm(form: EventForm, orgId: string, eventId: string | null, save: SaveFn): Promise<SubmitResult> {
  const problems = validateEventForm(form);
  if (problems.length > 0) return { ok: false, problems };
  try {
    await save(orgId, eventId, eventPayload(form));
    return { ok: true, problems: [] };
  } catch (err) {
    return {
      ok: false,
      problems: [sentence(err instanceof AccountError ? err.message : 'This could not be saved. Check your connection and try again.')],
    };
  }
}
