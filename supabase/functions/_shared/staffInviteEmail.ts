const resendApiKey = Deno.env.get('RESEND_API_KEY');
const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL') ?? 'tickets@bottlesupapp.com';

const ROLE_LABELS: Record<string, string> = {
  door_staff: 'Door Staff',
  server: 'Server',
  cashier: 'Cashier',
  bartender: 'Bartender',
  manager: 'Manager',
};

// BottlesUp Server and Pay-at-Club system, section 1: "BottlesUp emails the
// invitation." Sign-in itself stays the existing passwordless magic-link
// flow at /staff/login (same underlying mechanism as door staff always
// used) - this email just tells the person they've been granted access and
// what they've been assigned, since a magic-link email alone carries none
// of that context.
export async function sendStaffInviteEmail(opts: {
  toEmail: string;
  toName: string | null;
  role: string;
  eventTitle: string | null;
  assignedTables: string | null;
  canRecordPayments: boolean;
  accessStartAt: string | null;
  accessEndAt: string | null;
  loginUrl: string;
}) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set - skipping staff invite email send');
    return { sent: false, error: 'RESEND_API_KEY not set' };
  }

  const roleLabel = ROLE_LABELS[opts.role] ?? opts.role;
  const fmtWindow = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : null);
  const accessWindow =
    opts.accessStartAt || opts.accessEndAt
      ? `${fmtWindow(opts.accessStartAt) ?? 'now'} - ${fmtWindow(opts.accessEndAt) ?? 'until removed'}`
      : null;

  const html = `
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #0a0a0a; color: #fff; border-radius: 16px;">
      <h1 style="color: #f97316; font-size: 22px;">You've been added to the team 🍾</h1>
      <p>Hi ${opts.toName ?? 'there'},</p>
      <p>BottlesUp has granted you access as <strong>${roleLabel}</strong>${opts.eventTitle ? ` for <strong>${opts.eventTitle}</strong>` : ''}.</p>
      <table style="width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 14px;">
        <tr><td style="padding: 4px 0; color: #ccc;">Role</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${roleLabel}</td></tr>
        ${opts.eventTitle ? `<tr><td style="padding: 4px 0; color: #ccc;">Event</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${opts.eventTitle}</td></tr>` : ''}
        ${opts.assignedTables ? `<tr><td style="padding: 4px 0; color: #ccc;">Assigned tables/section</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${opts.assignedTables}</td></tr>` : ''}
        ${accessWindow ? `<tr><td style="padding: 4px 0; color: #ccc;">Access window</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${accessWindow}</td></tr>` : ''}
        <tr><td style="padding: 4px 0; color: #ccc;">Can record club payments</td><td style="padding: 4px 0; color: #ccc; text-align: right;">${opts.canRecordPayments ? 'Yes' : 'No'}</td></tr>
      </table>
      <div style="text-align: center; margin: 24px 0;">
        <a href="${opts.loginUrl}" style="display: inline-block; background: #f97316; color: #000; font-weight: bold; padding: 12px 28px; border-radius: 999px; text-decoration: none;">
          Sign In
        </a>
      </div>
      <p style="color: #999; font-size: 13px;">Sign in with this email address - we'll text/email you a one-time link, no password needed.</p>
    </div>
  `;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: fromEmail,
      to: opts.toEmail,
      subject: `You've been added to the BottlesUp team as ${roleLabel}`,
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
