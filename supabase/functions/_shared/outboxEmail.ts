// Sends one outbox message through Resend, the same provider as every other BottlesUp e-mail. The key is read when sending (not at import) so a
// missing key is a clean "not configured" result. Provider error bodies are logged without the message content and never returned.

export function outboxEmailConfigured(): boolean {
  return !!Deno.env.get('RESEND_API_KEY');
}

export interface SendResult {
  sent: boolean;
  reason?: 'not_configured' | 'send_failed';
}

export async function sendOutboxEmail(to: string, subject: string, html: string, text: string): Promise<SendResult> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) return { sent: false, reason: 'not_configured' };
  const from = Deno.env.get('OUTBOX_FROM_EMAIL') ?? Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to, subject, html, text }),
    });
    if (!res.ok) {
      console.error('outbox email: provider returned', res.status);
      return { sent: false, reason: 'send_failed' };
    }
    return { sent: true };
  } catch {
    console.error('outbox email: request failed');
    return { sent: false, reason: 'send_failed' };
  }
}
