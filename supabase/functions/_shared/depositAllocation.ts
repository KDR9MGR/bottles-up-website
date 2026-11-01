// How much of a table deposit counts toward the bottle bill (client Phase 2 brief, section 9: "Combined allocations must sum to the payment and cannot give the same money two credits ...
// Admission-only money does not become bottle credit unless explicitly allocated that way").
//
// A venue's deposit has terms (site_venues.deposit_terms, copied onto each booking when it is made, 20261021100000). Until a combination existed the whole deposit was either a credit
// (BottlesUp's switch site_venues.deposit_is_credit on) or not. A COMBINATION (20261120100000_deposit_combination.sql) splits the deposit into three shares, in whole percents that add up
// to 100: a reservation fee and admission (neither counts toward the bottle bill) and a minimum-spend credit (the only share that does).
//
// This is the one place that works it out, so the checkout, the totals after a bottle is added and the payment that was collected cannot disagree. Everything here is integer cents. For a
// deposit that is not a combination (no terms, or any single purpose) it gives exactly what the code did before: all of the deposit when the credit switch is on, none when it is off.

export interface DepositParts {
  reservationFeePct: number;
  minimumSpendCreditPct: number;
  admissionPct: number;
}

export interface DepositSplit {
  reservationFeeCents: number;
  minimumSpendCreditCents: number;
  admissionCents: number;
}

const isShare = (v: unknown): v is number => typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= 100;

/** The three shares of a combination, read from deposit terms; null when the terms are not a valid combination (then they are treated as any single purpose). */
export function combinationParts(terms: unknown): DepositParts | null {
  if (!terms || typeof terms !== 'object') return null;
  const t = terms as Record<string, unknown>;
  if (t.purpose !== 'combination' || !t.parts || typeof t.parts !== 'object') return null;
  const p = t.parts as Record<string, unknown>;
  const fee = p.reservation_fee_pct;
  const credit = p.minimum_spend_credit_pct;
  const admission = p.admission_pct;
  if (!isShare(fee) || !isShare(credit) || !isShare(admission) || fee + credit + admission !== 100) return null;
  return { reservationFeePct: fee, minimumSpendCreditPct: credit, admissionPct: admission };
}

/**
 * The deposit split into its three shares, in cents. The credit and the admission are rounded DOWN and the reservation fee takes the remainder, so the three always add up to the
 * deposit exactly and the credit is never more than its share.
 */
export function splitDeposit(depositCents: number, parts: DepositParts): DepositSplit {
  const deposit = Math.max(Math.trunc(Number.isFinite(depositCents) ? depositCents : 0), 0);
  const minimumSpendCreditCents = Math.floor((deposit * parts.minimumSpendCreditPct) / 100);
  const admissionCents = Math.floor((deposit * parts.admissionPct) / 100);
  return { minimumSpendCreditCents, admissionCents, reservationFeeCents: deposit - minimumSpendCreditCents - admissionCents };
}

/**
 * How much of the deposit counts toward the bottle bill. [depositIsCredit] is BottlesUp's switch for the venue and still comes first: with it off nothing is credited, whatever the
 * terms say. With it on, a combination credits only its credit share and anything else credits the whole deposit (as before).
 */
export function creditedDepositCents(opts: { depositCents: number; depositIsCredit: boolean; terms?: unknown }): number {
  if (!opts.depositIsCredit) return 0;
  const parts = combinationParts(opts.terms);
  return parts ? splitDeposit(opts.depositCents, parts).minimumSpendCreditCents : opts.depositCents;
}
