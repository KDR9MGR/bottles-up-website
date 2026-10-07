import { describe, expect, it } from 'vitest';
import {
  describeMissing,
  isVerificationState,
  publishVenueGate,
  stateInfo,
  VERIFICATION_STATES,
  type VerificationState,
} from './verification';

describe('the four verification states (brief, section 3)', () => {
  it('there are exactly the four the client named', () => {
    expect([...VERIFICATION_STATES]).toEqual(['not_submitted', 'under_review', 'more_information_needed', 'verified']);
  });

  it.each([
    ['not_submitted', 'Not submitted', true, true],
    ['under_review', 'Under review', false, false],
    ['more_information_needed', 'More information needed', true, true],
    ['verified', 'Verified', false, false],
  ] as const)('%s: label, editable details, can submit', (state, label, canEdit, canSubmit) => {
    const info = stateInfo(state);
    expect(info.label).toBe(label);
    expect(info.canEditDetails).toBe(canEdit);
    expect(info.canSubmit).toBe(canSubmit);
  });

  it('setup drafting is allowed in every state: it never waits for review', () => {
    for (const s of VERIFICATION_STATES) expect(stateInfo(s).canDraftSetup).toBe(true);
  });

  it('every state has a plain-language summary and a tone', () => {
    for (const s of VERIFICATION_STATES) {
      expect(stateInfo(s).summary.length).toBeGreaterThan(10);
      expect(['neutral', 'info', 'warning', 'success']).toContain(stateInfo(s).tone);
    }
  });

  it('only submits when the form is editable (the two lists never disagree)', () => {
    for (const s of VERIFICATION_STATES) {
      const i = stateInfo(s);
      expect(i.canSubmit).toBe(i.canEditDetails);
    }
  });

  it('recognises valid states only', () => {
    expect(isVerificationState('verified')).toBe(true);
    expect(isVerificationState('approved')).toBe(false);
    expect(isVerificationState(null)).toBe(false);
    expect(isVerificationState(3)).toBe(false);
  });
});

describe('describeMissing', () => {
  it('turns database keys into messages with the field to fix', () => {
    const [a, b] = describeMissing(['legal_name', 'venue']);
    expect(a).toMatchObject({ key: 'legal_name', field: 'legal_name' });
    expect(a.message).toMatch(/legal business name/i);
    expect(b.message).toMatch(/venue/i);
  });

  it('covers every key the database can report', () => {
    const dbKeys = ['legal_name', 'representative_name', 'representative_phone', 'contact_email', 'address', 'representative_confirmed', 'description', 'venue'];
    for (const m of describeMissing(dbKeys)) expect(m.message.startsWith('Complete:')).toBe(false);
  });

  it('never hides a requirement it does not recognise', () => {
    expect(describeMissing(['tax_id'])).toEqual([{ key: 'tax_id', message: 'Complete: tax id', field: 'tax_id' }]);
  });

  it('is empty when nothing is missing', () => {
    expect(describeMissing([])).toEqual([]);
  });
});

describe('publishVenueGate: say why and give a direct action', () => {
  const ctx = (state: VerificationState, requiredStepsTodo = 0) => ({
    state,
    requiredStepsTodo,
    onboardingPath: '/business/o1/onboarding',
    setupPath: '/w/m1/venues',
  });

  it('blocks an unsubmitted business and points at submitting', () => {
    const g = publishVenueGate(ctx('not_submitted'));
    expect(g).toMatchObject({ allowed: false, action: { to: '/business/o1/onboarding' } });
    expect(g.reason).toBeTruthy();
  });

  it('blocks a business under review and points at the review progress', () => {
    const g = publishVenueGate(ctx('under_review'));
    expect(g.allowed).toBe(false);
    expect(g.reason).toMatch(/under review/i);
  });

  it('blocks a business that was sent back and points at what is needed', () => {
    const g = publishVenueGate(ctx('more_information_needed'));
    expect(g).toMatchObject({ allowed: false, action: { to: '/business/o1/onboarding' } });
  });

  it('verification and setup are separate: a verified business with unfinished setup is still blocked, on setup', () => {
    const g = publishVenueGate(ctx('verified', 2));
    expect(g.allowed).toBe(false);
    expect(g.reason).toMatch(/verified/);
    expect(g.reason).toMatch(/2 required setup steps are not finished/);
    expect(g.action?.to).toBe('/w/m1/venues');
  });

  it('uses the singular for one remaining step', () => {
    const g = publishVenueGate(ctx('verified', 1));
    expect(g.reason).toMatch(/1 required setup step is not finished/);
  });

  it('allows a verified business with every required step done', () => {
    expect(publishVenueGate(ctx('verified', 0))).toEqual({ allowed: true, reason: null, action: null });
  });

  it('finished setup does not make up for missing verification', () => {
    for (const s of ['not_submitted', 'under_review', 'more_information_needed'] as const) {
      expect(publishVenueGate(ctx(s, 0)).allowed).toBe(false);
    }
  });
});
