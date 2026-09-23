const resendApiKey = Deno.env.get('RESEND_API_KEY');
const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

export function generateGuestCode(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = 'GT-';
  for (let i = 0; i < 8; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

// Deliberately not a copy of sendTableBookingEmail's receipt template - a
// guest didn't pay anything, so "total paid"/cost-breakdown language would
// be misleading. This just says who invited them and where, with their own
// scannable QR (guest_code, not the booking's confirmation_code) so they can
// check in independently of the person who booked.
export async function sendGuestTicketEmail(opts: {
  toEmail: string;
  toName: string;
  hostName: string;
  venueName: string;
  tableTypeName: string;
  bookingDate: string;
  timeSlotLabel: string;
  guestCode: string;
  qrDataUrl: string;
}) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set - skipping guest ticket email send');
    return { sent: false, error: 'RESEND_API_KEY not set' };
  }

  const formattedDate = new Date(`${opts.bookingDate}T00:00:00Z`).toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC',
  });

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">You're on the guest list</h1>
      <p>Hi ${opts.toName},</p>
      <p><strong>${opts.hostName}</strong> added you to their VIP table at:</p>
      <h2 style="margin-bottom: 4px;">${opts.tableTypeName} - ${opts.venueName}</h2>
      <p style="color: #999; margin-top: 0;">${formattedDate}<br/>Arrival: ${opts.timeSlotLabel}</p>
      <div style="text-align: center; margin: 24px 0;">
        <img src="cid:qrcode" alt="Guest ticket QR code" width="200" height="200" style="background: #fff; padding: 12px; border-radius: 8px;" />
      </div>
      <p style="text-align: center; font-size: 20px; letter-spacing: 2px; font-weight: bold;">${opts.guestCode}</p>
      <p style="color: #999; font-size: 13px;">This is your own ticket - show this email (QR code or the code above) at the door to check in, separately from ${opts.hostName}.</p>
    </div>
  `;

  const qrBase64 = opts.qrDataUrl.split(',')[1];

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: fromEmail,
      to: opts.toEmail,
      subject: `You're on the guest list at ${opts.venueName}`,
      html,
      attachments: [{ filename: 'guest-ticket-qr.png', content: qrBase64, content_id: 'qrcode' }],
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    console.error('Resend send failed:', body);
    return { sent: false, error: body || `Resend request failed (${res.status})` };
  }

  return { sent: true };
}
