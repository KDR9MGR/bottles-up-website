// Sends the invitation email through Resend, the same provider as every other BottlesUp email. The key is read when
// sending (not at import) so a missing key is a clean "not configured" result and the screen can fall back to
// showing the link. Provider error bodies are never returned to the browser.

export interface SendResult {
  sent: boolean;
  /** 'not_configured' when no API key is set, 'send_failed' when the provider refused. */
  reason?: 'not_configured' | 'send_failed';
}

export async function sendTeamInvitationEmail(to: string, subject: string, html: string, text: string): Promise<SendResult> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) {
    console.warn('RESEND_API_KEY not set - skipping team invitation email');
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
      console.error('team invitation email: provider returned', res.status);
      return { sent: false, reason: 'send_failed' };
    }
    return { sent: true };
  } catch {
    console.error('team invitation email: request failed');
    return { sent: false, reason: 'send_failed' };
  }
}
