const resendApiKey = Deno.env.get('RESEND_API_KEY');
const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

export function generateOtpCode(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

export async function sendOtpEmail(opts: {
  toEmail: string;
  toName: string;
  eventTitle: string;
  code: string;
}) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set - skipping OTP email send');
    return { sent: false, error: 'RESEND_API_KEY not set' };
  }

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316;">Your BottlesUp Entry Code</h1>
      <p>Hi ${opts.toName},</p>
      <p>Show this code to door staff to enter:</p>
      <p style="text-align: center; font-size: 40px; letter-spacing: 8px; font-weight: bold; margin: 24px 0;">${opts.code}</p>
      <p style="color: #999; text-align: center;">Expires in 5 minutes</p>
      <p style="color: #999; font-size: 13px; margin-top: 24px;">${opts.eventTitle}</p>
      <p style="color: #999; font-size: 13px;">Didn't request this? Someone may be trying to use your ticket - sign in to your BottlesUp account to check your bookings.</p>
    </div>
  `;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: fromEmail,
      to: opts.toEmail,
      subject: 'Your BottlesUp Entry Code',
      html,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    console.error('Resend send failed:', body);
    return { sent: false, error: body || `Resend request failed (${res.status})` };
  }

  return { sent: true };
}
