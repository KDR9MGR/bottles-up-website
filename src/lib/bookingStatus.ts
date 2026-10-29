// What one answer from the site-booking-status function means for the booking-success page.
//  * ticket / booking: paid and confirmed, show it;
//  * held: the guest paid, but their table went to someone else while they did and a manager has been asked to sort it out: no confirmation (and no code) is shown;
//  * retry: not paid yet or no answer, ask again in a moment (up to [maxAttempts] times);
//  * give_up: still not confirmed after that, tell the guest to check their inbox.
export type StatusOutcome =
  | { kind: 'ticket'; ticket: unknown }
  | { kind: 'booking'; booking: unknown }
  | { kind: 'held' }
  | { kind: 'retry' }
  | { kind: 'give_up' };

interface StatusAnswer {
  status?: unknown;
  ticket?: unknown;
  booking?: unknown;
}

export function readBookingStatus(data: StatusAnswer | null | undefined, attempts: number, maxAttempts = 10): StatusOutcome {
  if (data?.status === 'held') return { kind: 'held' };
  if (data?.status === 'paid' && data.ticket) return { kind: 'ticket', ticket: data.ticket };
  if (data?.status === 'paid' && data.booking) return { kind: 'booking', booking: data.booking };
  return attempts + 1 < maxAttempts ? { kind: 'retry' } : { kind: 'give_up' };
}
