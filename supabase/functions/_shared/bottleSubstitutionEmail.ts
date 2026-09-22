const resendApiKey = Deno.env.get('RESEND_API_KEY');
const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

const money = (cents: number, currency: string) => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

// Bottle Payment Options section 9: "Unavailable bottles - Offer a
// replacement or removal, obtain customer approval for changes." Sent the
// moment staff flags an ordered bottle unavailable, before anything on the
// order actually changes - the change only takes effect once the customer
// approves via respond-bottle-substitution.
export async function sendBottleSubstitutionRequestEmail(opts: {
  toEmail: string;
  toName: string;
  venueName: string;
  originalBottleName: string;
  originalSize: string | null;
  quantity: number;
  reason: string;
  replacementBottleName: string | null;
  replacementSize: string | null;
  priceDiffCents: number;
  currency: string;
  confirmUrl: string;
}) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set - skipping bottle substitution request email send');
    return { sent: false, error: 'RESEND_API_KEY not set' };
  }

  const originalLabel = `${opts.originalBottleName}${opts.originalSize ? ` (${opts.originalSize})` : ''} × ${opts.quantity}`;
  const proposalHtml = opts.replacementBottleName
    ? `<p>The venue would like to replace it with <strong>${opts.replacementBottleName}${opts.replacementSize ? ` (${opts.replacementSize})` : ''}</strong>.</p>
       ${
         opts.priceDiffCents !== 0
           ? `<p style="color: ${opts.priceDiffCents > 0 ? '#f97316' : '#4ade80'};">${opts.priceDiffCents > 0 ? `This adds ${money(opts.priceDiffCents, opts.currency)} to your order.` : `This reduces your order by ${money(-opts.priceDiffCents, opts.currency)}.`}</p>`
           : `<p style="color: #999;">No price difference.</p>`
       }`
    : `<p>The venue would like to remove it from your order${opts.priceDiffCents < 0 ? ` and refund ${money(-opts.priceDiffCents, opts.currency)}` : ''}.</p>`;

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">One of your bottles is unavailable</h1>
      <p>Hi ${opts.toName},</p>
      <p><strong>${opts.venueName}</strong> let us know that <strong>${originalLabel}</strong> is no longer available. Reason given: ${opts.reason}</p>
      ${proposalHtml}
      <p>Nothing changes on your order until you approve it.</p>
      <div style="text-align: center; margin: 24px 0;">
        <a href="${opts.confirmUrl}" style="display: inline-block; background: #f97316; color: #000; font-weight: bold; padding: 12px 28px; border-radius: 999px; text-decoration: none;">
          Review This Change
        </a>
      </div>
    </div>
  `;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: fromEmail,
      to: opts.toEmail,
      subject: `Action needed: a bottle at ${opts.venueName} is unavailable`,
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
