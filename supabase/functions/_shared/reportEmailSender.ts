// Sends a report e-mail with its PDF through Resend, the same provider as every other BottlesUp e-mail. The key is read when sending (not at import) so a missing key is a clean
// "not configured" result. Provider error bodies are never returned to the browser.

import type { SendResult } from './teamInvitationEmail.ts';

export interface PdfAttachment {
  filename: string;
  /** The PDF, base64. */
  contentBase64: string;
}

export async function sendReportEmail(to: string, subject: string, html: string, text: string, attachment: PdfAttachment): Promise<SendResult> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) {
    console.warn('RESEND_API_KEY not set - skipping report email');
    return { sent: false, reason: 'not_configured' };
  }
  const from = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to, subject, html, text, attachments: [{ filename: attachment.filename, content: attachment.contentBase64 }] }),
    });
    if (!res.ok) {
      console.error('report email: provider returned', res.status);
      return { sent: false, reason: 'send_failed' };
    }
    return { sent: true };
  } catch {
    console.error('report email: request failed');
    return { sent: false, reason: 'send_failed' };
  }
}
