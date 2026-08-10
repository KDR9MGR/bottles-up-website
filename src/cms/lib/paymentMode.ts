export type PaymentModeFilter = 'live' | 'test' | 'all';

// Stripe checkout session ids are prefixed by mode (cs_live_... / cs_test_...),
// so that prefix is the only reliable way to tell real money from test data -
// site_orders/site_table_bookings don't have their own mode column.
export function sessionMode(sessionId: string | null): 'live' | 'test' | 'unknown' {
  if (!sessionId) return 'unknown';
  if (sessionId.startsWith('cs_live_')) return 'live';
  if (sessionId.startsWith('cs_test_')) return 'test';
  return 'unknown';
}
