// Sends the claim-link e-mail through Resend, the same provider as every other BottlesUp e-mail. The key is read when sending (not at import) so a missing key is a clean "not configured"
// result. Provider error bodies are never returned to the browser, and the e-mail (which holds the link) is never logged.

import type { SendResult } from './teamInvitationEmail.ts';

export async function sendCompOfferEmail(to: string, subject: string, html: string, text: string): Promise<SendResult> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) {
    console.warn('RESEND_API_KEY not set - skipping complimentary offer email');
    return { sent: false, reason: 'not_configured' };
  }
  const from = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to, subject, html, text }),
    });
    if (!res.ok) {
      console.error('complimentary offer email: provider returned', res.status);
      return { sent: false, reason: 'send_failed' };
    }
    return { sent: true };
  } catch {
    console.error('complimentary offer email: request failed');
    return { sent: false, reason: 'send_failed' };
  }
}
