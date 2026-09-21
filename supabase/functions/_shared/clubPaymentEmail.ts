const resendApiKey = Deno.env.get('RESEND_API_KEY');
const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

const methodLabel: Record<string, string> = {
  cash: 'Cash',
  debit: 'Debit',
  credit: 'Credit',
  split: 'Split payment',
};

// Sent right after staff records a club payment (section 5) - asks the payer
// to confirm the recorded details or report an issue (section 6). Never
// implies the payment is already confirmed; that only happens if they act.
export async function sendClubPaymentConfirmationEmail(opts: {
  toEmail: string;
  toName: string;
  venueName: string;
  tableTypeName: string;
  confirmationCode: string;
  billedAmountCents: number;
  amountPaidCents: number;
  paymentMethod: string;
  currency: string;
  confirmUrl: string;
}) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set - skipping club payment confirmation email send');
    return { sent: false, error: 'RESEND_API_KEY not set' };
  }

  const money = (cents: number) => `$${(cents / 100).toFixed(2)} ${opts.currency.toUpperCase()}`;

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">Please confirm your payment</h1>
      <p>Hi ${opts.toName},</p>
      <p>The venue recorded a payment for your reservation at <strong>${opts.tableTypeName} - ${opts.venueName}</strong> (confirmation <strong>${opts.confirmationCode}</strong>):</p>
      <table style="width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 14px;">
        <tr><td style="padding: 4px 0; color: #ccc;">Billed amount</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${money(opts.billedAmountCents)}</td></tr>
        <tr><td style="padding: 4px 0; color: #ccc;">Amount paid</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${money(opts.amountPaidCents)}</td></tr>
        <tr><td style="padding: 4px 0; color: #ccc;">Payment method</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${methodLabel[opts.paymentMethod] ?? opts.paymentMethod}</td></tr>
      </table>
      <p>Please confirm this looks right, or let us know if something's off.</p>
      <div style="text-align: center; margin: 24px 0;">
        <a href="${opts.confirmUrl}" style="display: inline-block; background: #f97316; color: #000; font-weight: bold; padding: 12px 28px; border-radius: 999px; text-decoration: none;">
          Review This Payment
        </a>
      </div>
      <p style="color: #999; font-size: 13px;">If you didn't expect this email, you can ignore it - it doesn't charge you anything.</p>
    </div>
  `;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: fromEmail,
      to: opts.toEmail,
      subject: `Please confirm your payment at ${opts.venueName}`,
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

// "then notify the manager" - there's no per-venue manager contact in the
// schema yet, so this goes to the platform's own general contact address
// (site_content.contact_email) rather than inventing one.
export async function sendClubPaymentDisputeNotificationEmail(opts: {
  toEmail: string;
  venueName: string;
  tableTypeName: string;
  confirmationCode: string;
  customerName: string;
  customerEmail: string;
  billedAmountCents: number;
  amountPaidCents: number;
  paymentMethod: string;
  currency: string;
  disputeReason: string;
  hasEvidence: boolean;
}) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set - skipping club payment dispute notification email send');
    return { sent: false, error: 'RESEND_API_KEY not set' };
  }

  const money = (cents: number) => `$${(cents / 100).toFixed(2)} ${opts.currency.toUpperCase()}`;

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #ef4444; font-size: 22px;">Payment disputed</h1>
      <p><strong>${opts.customerName}</strong> (${opts.customerEmail}) reported an issue with a club payment recorded at <strong>${opts.tableTypeName} - ${opts.venueName}</strong> (confirmation <strong>${opts.confirmationCode}</strong>).</p>
      <table style="width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 14px;">
        <tr><td style="padding: 4px 0; color: #ccc;">Billed amount</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${money(opts.billedAmountCents)}</td></tr>
        <tr><td style="padding: 4px 0; color: #ccc;">Amount paid</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${money(opts.amountPaidCents)}</td></tr>
        <tr><td style="padding: 4px 0; color: #ccc;">Payment method</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${methodLabel[opts.paymentMethod] ?? opts.paymentMethod}</td></tr>
      </table>
      <p style="color: #fca5a5;"><strong>Reason given:</strong> ${opts.disputeReason}</p>
      ${opts.hasEvidence ? '<p style="color: #999; font-size: 13px;">The customer also attached a photo - view it in the CMS booking detail.</p>' : ''}
    </div>
  `;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: fromEmail,
      to: opts.toEmail,
      subject: `Payment disputed at ${opts.venueName} - ${opts.confirmationCode}`,
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
