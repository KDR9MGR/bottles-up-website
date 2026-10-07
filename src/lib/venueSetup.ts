// The venue setup checklist (client brief, section 2). The database computes each step from
// what really exists (a floor plan, table types, bottles...) and returns it; this file adds
// the wording and the summary.
//
// Readiness is deliberately independent of verification: see verification.ts.

export type SetupStatus = 'done' | 'todo' | 'unavailable';

export interface SetupStep {
  step: string;
  status: SetupStatus;
  required: boolean;
  detail: string | null;
}

interface StepMeta {
  label: string;
  description: string;
}

// Order here is the order shown, and follows the brief's checklist.
const META: Record<string, StepMeta> = {
  profile: { label: 'Venue profile', description: 'Name, description, address and cover photo guests will see.' },
  floor_plan: { label: 'Rooms and floor plan', description: 'Upload your floor plan so tables can be placed on it.' },
  tables: { label: 'Tables and capacities', description: 'Table types with capacity, deposit and minimum spend.' },
  bottles: { label: 'Bottle menu and stock', description: 'The bottles guests can pre-order or add at the table.' },
  booking_rules: { label: 'Booking rules', description: 'The days and arrival times you accept bookings.' },
  payments: { label: 'Payment configuration', description: 'How you collect deposits and balances.' },
  team: { label: 'Team', description: 'Managers and staff for this venue.' },
  notifications: { label: 'Notifications and reports', description: 'Who receives alerts and nightly reports.' },
};

const ORDER = Object.keys(META);

export function stepLabel(step: string): string {
  return META[step]?.label ?? step.replace(/_/g, ' ');
}

export function stepDescription(step: string): string {
  return META[step]?.description ?? '';
}

/** Steps in the brief's order. A step this code does not know about is kept, at the end. */
export function orderSteps(steps: readonly SetupStep[]): SetupStep[] {
  const rank = (s: string) => {
    const i = ORDER.indexOf(s);
    return i === -1 ? ORDER.length : i;
  };
  return [...steps].sort((a, b) => rank(a.step) - rank(b.step));
}

export interface SetupSummary {
  requiredTotal: number;
  requiredDone: number;
  requiredTodo: number;
  /** 0-100, whole number. Only required steps count. */
  percent: number;
  /** Every required step is done. */
  ready: boolean;
  /** The first required step still to do, so the page can point at it. */
  nextStep: SetupStep | null;
}

export function summarizeSetup(steps: readonly SetupStep[]): SetupSummary {
  const required = orderSteps(steps).filter((s) => s.required);
  const requiredDone = required.filter((s) => s.status === 'done').length;
  const requiredTodo = required.filter((s) => s.status === 'todo').length;
  const requiredTotal = required.length;
  return {
    requiredTotal,
    requiredDone,
    requiredTodo,
    // An empty list is NOT "100% ready": nothing was measured.
    percent: requiredTotal === 0 ? 0 : Math.round((requiredDone / requiredTotal) * 100),
    ready: requiredTotal > 0 && requiredDone === requiredTotal,
    nextStep: required.find((s) => s.status === 'todo') ?? null,
  };
}

/** Plain wording for the status badge. 'unavailable' is never shown as done or pending. */
export function statusLabel(status: SetupStatus): string {
  switch (status) {
    case 'done': return 'Done';
    case 'todo': return 'To do';
    case 'unavailable': return 'Coming soon';
  }
}
