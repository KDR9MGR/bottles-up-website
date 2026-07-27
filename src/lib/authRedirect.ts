// Vercel 308-redirects the apex domain (bottlesupapp.com) to www, which can
// unreliably drop the #access_token fragment magic-link auth relies on in
// some email-client webviews (Gmail app, Outlook, etc.). Always target the
// canonical www domain directly so that extra redirect hop never happens.
const CANONICAL_ORIGIN = 'https://www.bottlesupapp.com';

export function getAuthRedirectBase(): string {
  return window.location.hostname === 'localhost' ? window.location.origin : CANONICAL_ORIGIN;
}
