const resendApiKey = Deno.env.get('RESEND_API_KEY');
const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

export function generateTicketCode(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no ambiguous 0/O/1/I
  let code = 'BU-';
  for (let i = 0; i < 8; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

export async function sendTicketEmail(opts: {
  toEmail: string;
  toName: string;
  eventTitle: string;
  venueName: string;
  startDate: string;
  tierName: string;
  quantity: number;
  ticketCode: string;
  qrDataUrl: string;
}) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set - skipping ticket email send');
    return { sent: false, error: 'RESEND_API_KEY not set' };
  }

  // Explicit timeZone matters here: this runs on the Edge Function server (UTC),
  // not in the venue's timezone, so without it the printed date/time would be
  // whatever the server's clock says - e.g. showing the 27th for a 10pm-on-the-26th
  // Toronto event.
  const formattedDate = new Date(opts.startDate).toLocaleString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'America/Toronto',
  });

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316;">Your BottlesUp Ticket 🍾</h1>
      <p>Hi ${opts.toName},</p>
      <p>You're confirmed for:</p>
      <h2 style="margin-bottom: 4px;">${opts.eventTitle}</h2>
      <p style="color: #999; margin-top: 0;">${opts.venueName}<br/>${formattedDate}</p>
      <p><strong>${opts.tierName}</strong> &times; ${opts.quantity}</p>
      <div style="text-align: center; margin: 24px 0;">
        <img src="cid:qrcode" alt="Ticket QR code" width="200" height="200" style="background: #fff; padding: 12px; border-radius: 8px;" />
      </div>
      <p style="text-align: center; font-size: 20px; letter-spacing: 2px; font-weight: bold;">${opts.ticketCode}</p>
      <p style="color: #999; font-size: 13px;">Show this email (QR code or the code above) at the door. See you there!</p>
    </div>
  `;

  // Most email clients (Gmail included) strip inline data: URI images out of HTML
  // emails as a spam-filtering measure, so the QR never rendered. Attaching it and
  // referencing it via cid: is the standard, actually-reliable way to inline an image.
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
      subject: `Your ticket for ${opts.eventTitle}`,
      html,
      attachments: [{ filename: 'ticket-qr.png', content: qrBase64, content_id: 'qrcode' }],
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    console.error('Resend send failed:', body);
    return { sent: false, error: body || `Resend request failed (${res.status})` };
  }

  return { sent: true };
}
