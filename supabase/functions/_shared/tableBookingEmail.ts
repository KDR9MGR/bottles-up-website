const resendApiKey = Deno.env.get('RESEND_API_KEY');
const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

export function formatTimeSlot(startTime: string): string {
  const [h, m] = startTime.split(':').map((v) => parseInt(v, 10));
  const period = h >= 12 ? 'PM' : 'AM';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${m.toString().padStart(2, '0')} ${period}`;
}

export function generateConfirmationCode(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no ambiguous 0/O/1/I
  let code = 'BT-';
  for (let i = 0; i < 8; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

export interface BottleLineItem {
  bottle_name: string;
  size: string | null;
  quantity: number;
  unit_price_cents: number;
  line_total_cents: number;
}

export async function sendTableBookingEmail(opts: {
  toEmail: string;
  toName: string;
  venueName: string;
  tableTypeName: string;
  bookingDate: string; // YYYY-MM-DD
  timeSlotLabel: string; // e.g. "10:00 PM"
  guestCount: number;
  depositCents: number;
  bottleSubtotalCents?: number;
  taxCents?: number;
  bottlesupFeeCents?: number;
  totalCents: number;
  bottles?: BottleLineItem[];
  currency: string;
  hours?: number | null;
  confirmationCode: string;
  qrDataUrl: string;
}) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set - skipping table booking email send');
    return { sent: false, error: 'RESEND_API_KEY not set' };
  }

  const formattedDate = new Date(`${opts.bookingDate}T00:00:00Z`).toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC',
  });
  const money = (cents: number) => `$${(cents / 100).toFixed(2)} ${opts.currency.toUpperCase()}`;
  const depositLabel = opts.hours ? `Table (${opts.hours} hour${opts.hours === 1 ? '' : 's'})` : 'Table deposit';
  const durationLine = opts.hours
    ? `<br/>Duration: ${opts.hours} hour${opts.hours === 1 ? '' : 's'}`
    : '';

  const bottleRows = (opts.bottles ?? [])
    .map(
      (b) => `
        <tr>
          <td style="padding: 4px 0; color: #ccc;">${b.bottle_name}${b.size ? ` (${b.size})` : ''} &times; ${b.quantity}</td>
          <td style="padding: 4px 0; color: #ccc; text-align: right;">${money(b.line_total_cents)}</td>
        </tr>`,
    )
    .join('');

  const summaryRow = (label: string, cents: number | undefined) =>
    cents
      ? `<tr><td style="padding: 4px 0; color: #ccc;">${label}</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${money(cents)}</td></tr>`
      : '';

  const orderSummaryHtml = `
    <table style="width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 14px;">
      <tr>
        <td style="padding: 4px 0; color: #ccc;">${depositLabel}</td>
        <td style="padding: 4px 0; color: #ccc; text-align: right;">${money(opts.depositCents)}</td>
      </tr>
      ${bottleRows}
      ${summaryRow('Tax', opts.taxCents)}
      ${summaryRow('BottlesUp fee', opts.bottlesupFeeCents)}
      <tr>
        <td style="padding: 8px 0 0; color: #fff; font-weight: bold; border-top: 1px solid #333;">Total paid</td>
        <td style="padding: 8px 0 0; color: #fff; font-weight: bold; text-align: right; border-top: 1px solid #333;">${money(opts.totalCents)}</td>
      </tr>
    </table>
  `;

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316;">Your VIP Table is Confirmed 🍾</h1>
      <p>Hi ${opts.toName},</p>
      <p>You're confirmed for:</p>
      <h2 style="margin-bottom: 4px;">${opts.tableTypeName} - ${opts.venueName}</h2>
      <p style="color: #999; margin-top: 0;">${formattedDate}<br/>Arrival: ${opts.timeSlotLabel}${durationLine}</p>
      <p><strong>${opts.guestCount}</strong> guests</p>
      ${orderSummaryHtml}
      <div style="text-align: center; margin: 24px 0;">
        <img src="cid:qrcode" alt="Booking QR code" width="200" height="200" style="background: #fff; padding: 12px; border-radius: 8px;" />
      </div>
      <p style="text-align: center; font-size: 20px; letter-spacing: 2px; font-weight: bold;">${opts.confirmationCode}</p>
      <p style="color: #999; font-size: 13px;">Show this email (QR code or the code above) at the door. See you there!</p>
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
      subject: `Your VIP table at ${opts.venueName} is confirmed`,
      html,
      attachments: [{ filename: 'booking-qr.png', content: qrBase64, content_id: 'qrcode' }],
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    console.error('Resend send failed:', body);
    return { sent: false, error: body || `Resend request failed (${res.status})` };
  }

  return { sent: true };
}
