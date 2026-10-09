// Business verification as the client defined it (website brief, section 3). Pure rules, no
// database or React, so they can be tested and reused by every screen that shows them.
//
//   Not Submitted            complete the required details and submit
//   Under Review             see progress and keep drafting the allowed setup
//   More Information Needed  see the specific request, update details and resubmit
//   Verified                 use features for which operational setup is also complete
//
// Verification and setup readiness are SEPARATE. A verified business can still have an
// unfinished floor plan; an unverified one can keep drafting. Legal review of the documents
// is out of scope (client note): this is the product state only.

export type VerificationState = 'not_submitted' | 'under_review' | 'more_information_needed' | 'verified';

export const VERIFICATION_STATES: readonly VerificationState[] = [
  'not_submitted', 'under_review', 'more_information_needed', 'verified',
];

export function isVerificationState(value: unknown): value is VerificationState {
  return typeof value === 'string' && (VERIFICATION_STATES as readonly string[]).includes(value);
}

export type Tone = 'neutral' | 'info' | 'warning' | 'success';

export interface StateInfo {
  label: string;
  tone: Tone;
  /** One line telling the business where it stands and what it can do. */
  summary: string;
  /** The identity details (legal name, representative, address...) can be edited. */
  canEditDetails: boolean;
  /** The "Submit for review" action is offered. */
  canSubmit: boolean;
  /** Venue and setup drafting is allowed. True in every state: setup never waits for review. */
  canDraftSetup: boolean;
}

const INFO: Record<VerificationState, StateInfo> = {
  not_submitted: {
    label: 'Not submitted',
    tone: 'neutral',
    summary: 'Complete the required details and submit your business for verification.',
    canEditDetails: true,
    canSubmit: true,
    canDraftSetup: true,
  },
  under_review: {
    label: 'Under review',
    tone: 'info',
    summary: 'We are reviewing your details. You can keep setting up your venue while you wait.',
    canEditDetails: false,
    canSubmit: false,
    canDraftSetup: true,
  },
  more_information_needed: {
    label: 'More information needed',
    tone: 'warning',
    summary: 'We need a little more from you. Update your details and submit again.',
    canEditDetails: true,
    canSubmit: true,
    canDraftSetup: true,
  },
  verified: {
    label: 'Verified',
    tone: 'success',
    summary: 'Your business is verified.',
    canEditDetails: false,
    canSubmit: false,
    canDraftSetup: true,
  },
};

export function stateInfo(state: VerificationState): StateInfo {
  return INFO[state];
}

/**
 * A business that was added by mistake can be cancelled by its owner until it has been verified: before it is submitted, or
 * after the reviewer sent it back. Once it is under review or verified it may have been relied on, so only the BottlesUp team
 * handles it. The database enforces the same rule (cancel_business); this decides whether the button is offered.
 */
export function canCancelBusiness(state: VerificationState): boolean {
  return state === 'not_submitted' || state === 'more_information_needed';
}

// ---------------------------------------------------------------------------
// What is still missing before a business can be submitted
// ---------------------------------------------------------------------------

export interface MissingItem {
  key: string;
  /** Plain-language message shown to the person, e.g. "Add your legal business name". */
  message: string;
  /** The form field to focus to fix it. */
  field: string;
}

const MISSING: Record<string, Omit<MissingItem, 'key'>> = {
  legal_name: { message: 'Add your legal business name', field: 'legal_name' },
  representative_name: { message: 'Add the name of the person representing the business', field: 'representative_name' },
  representative_phone: { message: 'Add a phone number for that person', field: 'representative_phone' },
  contact_email: { message: 'Add a contact email for the business', field: 'contact_email' },
  address: { message: 'Add the business address', field: 'address' },
  representative_confirmed: {
    message: 'Confirm that you are 18 or older and allowed to represent this business',
    field: 'representative_confirmed',
  },
  description: { message: 'Add a short description of your business', field: 'description' },
  venue: { message: 'Add a venue, or ask to claim one that already exists', field: 'venue' },
};

/**
 * Turns the keys the database reports into messages. A key this code does not know yet is
 * shown as-is rather than hidden, so a new server-side requirement can never silently vanish
 * from the screen.
 */
export function describeMissing(keys: readonly string[]): MissingItem[] {
  return keys.map((key) => {
    const known = MISSING[key];
    return known ? { key, ...known } : { key, message: `Complete: ${key.replace(/_/g, ' ')}`, field: key };
  });
}

// ---------------------------------------------------------------------------
// Restricted features: say why, and give a direct way to fix it
// ---------------------------------------------------------------------------

export interface GateContext {
  state: VerificationState;
  /** Required setup steps still to do for the venue in question. */
  requiredStepsTodo: number;
  /** Where the business onboarding page lives, for the "fix it" action. */
  onboardingPath: string;
  /** Where the venue setup checklist lives. */
  setupPath: string;
}

/**
 * `allowed` is true only when nothing blocks the action. When it is false, `reason` says why in plain words
 * and `action` is the direct way to fix it. (A plain shape rather than a discriminated union: this project
 * does not compile in strict mode, where such a union cannot be narrowed.)
 */
export interface Gate {
  allowed: boolean;
  reason: string | null;
  action: { label: string; to: string } | null;
}

const blocked = (reason: string, label: string, to: string): Gate => ({ allowed: false, reason, action: { label, to } });

/**
 * Publishing a venue needs BOTH things: a verified business and finished required setup.
 * Verification is checked first because setup cannot make up for it.
 */
export function publishVenueGate(ctx: GateContext): Gate {
  switch (ctx.state) {
    case 'not_submitted':
      return blocked('Your business has not been submitted for verification yet.', 'Submit for verification', ctx.onboardingPath);
    case 'under_review':
      return blocked('Your business is still under review. Publishing unlocks once it is verified.', 'See review progress', ctx.onboardingPath);
    case 'more_information_needed':
      return blocked('We need more information before your business can be verified.', 'See what we need', ctx.onboardingPath);
    case 'verified':
      if (ctx.requiredStepsTodo > 0) {
        const plural = ctx.requiredStepsTodo === 1 ? 'step is' : 'steps are';
        return blocked(
          `Your business is verified, but ${ctx.requiredStepsTodo} required setup ${plural} not finished.`,
          'Finish venue setup',
          ctx.setupPath,
        );
      }
      return { allowed: true, reason: null, action: null };
  }
}
