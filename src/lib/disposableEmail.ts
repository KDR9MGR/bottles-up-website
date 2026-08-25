// Fast client-side check so a partner applicant gets immediate feedback
// instead of burning a signup + confirmation email on a throwaway address.
// Not the trust boundary - create_partner_account() re-checks this same list
// server-side, since a client could just skip calling this.
const DISPOSABLE_DOMAINS = new Set([
  'mailinator.com',
  'tempmail.com',
  '10minutemail.com',
  'guerrillamail.com',
  'throwawaymail.com',
  'yopmail.com',
  'trashmail.com',
  'getnada.com',
  'fakeinbox.com',
  'maildrop.cc',
  'sharklasers.com',
  'dispostable.com',
]);

export function isDisposableEmail(email: string): boolean {
  const domain = email.trim().toLowerCase().split('@')[1];
  return !!domain && DISPOSABLE_DOMAINS.has(domain);
}
