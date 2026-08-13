import type { Database } from '@/types/database';

export type SiteContent = Database['public']['Tables']['site_content']['Row'];

// Matches the current hardcoded Footer/Header copy - used if the site_content
// fetch fails or hasn't resolved yet, so the public site never renders blank.
export const SITE_CONTENT_DEFAULTS: SiteContent = {
  id: 1,
  contact_email: 'hello@bottlesupapp.com',
  contact_phone: '+14169999999',
  address: 'Toronto, ON, Canada',
  social_instagram:
    'https://www.instagram.com/bottlesupapp?utm_source=ig_web_button_share_sheet&igsh=ZDNlZDc0MzIxNw==',
  social_twitter: 'https://twitter.com/bottlesup_to',
  social_facebook: 'https://facebook.com/bottlesup.toronto',
  social_linkedin: 'https://linkedin.com/company/bottlesup-toronto',
  footer_tagline:
    "Toronto's premier nightlife app for VIP bookings and digital tickets. Elevating your night out experience across the city.",
  hero_headline: null,
  hero_subtext: null,
  payments_mode: 'test',
  bottlesup_fee_bps: 0,
  updated_at: '',
};
