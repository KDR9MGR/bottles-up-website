// Build-time switches for work that must not reach live visitors until its backend is deployed.
//
// ACCOUNT_ONBOARDING covers the new sign-up / log-in / business onboarding / workspace pages and
// the header and homepage entry points that lead to them. It needs these migrations applied first:
//   20261006120000_tenancy_foundation.sql
//   20261007100000_accounts_onboarding.sql
// Off by default, so merging this code changes nothing on the live site. To turn it on, set
//   VITE_ENABLE_ACCOUNT_ONBOARDING=true
// in the environment the site is built with (and in .env.local for development).

export const ACCOUNT_ONBOARDING_ENABLED = import.meta.env.VITE_ENABLE_ACCOUNT_ONBOARDING === 'true';

// App download links. The website has none today and they are not invented: set these when the apps are
// published and the badges appear. Only https addresses are accepted (see safeStoreUrl).
//   VITE_APP_STORE_URL=https://apps.apple.com/...
//   VITE_PLAY_STORE_URL=https://play.google.com/store/apps/details?id=...
export const APP_STORE_URL: string | undefined = import.meta.env.VITE_APP_STORE_URL;
export const PLAY_STORE_URL: string | undefined = import.meta.env.VITE_PLAY_STORE_URL;
