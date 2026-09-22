import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { sendStaffInviteEmail } from '../_shared/staffInviteEmail.ts';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const ROLES = ['door_staff', 'server', 'cashier', 'bartender', 'manager'];

// BottlesUp Server and Pay-at-Club system, section 1: "Add servers through
// the CMS" / "Change the current Door Staff page to Team & Staff." Resolves
// (or creates, via generateLink) the matching auth.users id without
// emailing a magic link - this project shares its Supabase auth.users with
// the BottlesUp mobile app, so the email may already belong to an existing
// account. Sign-in itself stays the existing passwordless flow at
// /staff/login (or /door/login); this only sends the "you've been added"
// invite email, with whatever role/assignment context was set.
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const anonClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await anonClient.auth.getUser();
  if (userError || !userData.user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const { data: admin } = await supabase
    .from('cms_admins')
    .select('id')
    .eq('id', userData.user.id)
    .maybeSingle();
  if (!admin) {
    return json({ error: 'Forbidden' }, 403);
  }

  try {
    const {
      email,
      name,
      role,
      event_id,
      assigned_tables,
      access_start_at,
      access_end_at,
      can_record_payments,
    } = await req.json();

    if (!email || typeof email !== 'string' || !EMAIL_RE.test(email)) {
      return json({ error: 'Valid email is required' }, 400);
    }
    const resolvedRole = typeof role === 'string' && ROLES.includes(role) ? role : 'door_staff';

    const { data: linkData, error: linkError } = await supabase.auth.admin.generateLink({
      type: 'magiclink',
      email,
    });
    if (linkError || !linkData?.user) {
      console.error('generateLink error:', linkError);
      return json({ error: linkError?.message ?? 'Could not resolve a user for that email' }, 500);
    }

    const { error: insertError } = await supabase
      .from('door_staff')
      .upsert(
        {
          id: linkData.user.id,
          email,
          name: name ?? null,
          role: resolvedRole,
          event_id: event_id ?? null,
          assigned_tables: assigned_tables ?? null,
          access_start_at: access_start_at ?? null,
          access_end_at: access_end_at ?? null,
          can_record_payments: !!can_record_payments,
        },
        { onConflict: 'id' },
      );

    if (insertError) {
      console.error('door_staff insert error:', insertError);
      return json({ error: 'Failed to add team member' }, 500);
    }

    await supabase.from('audit_log').insert({
      actor_id: userData.user.id,
      actor_email: userData.user.email ?? 'unknown',
      action: 'door_staff.added',
      entity_type: 'door_staff',
      entity_id: linkData.user.id,
      details: { email, role: resolvedRole, event_id, assigned_tables, can_record_payments: !!can_record_payments },
    });

    let eventTitle: string | null = null;
    if (event_id) {
      const { data: event } = await supabase.from('site_events').select('title').eq('id', event_id).maybeSingle();
      eventTitle = event?.title ?? null;
    }

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim());
    const siteUrl = allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)
      ? origin
      : (Deno.env.get('SITE_URL') ?? 'https://bottlesupapp.com');

    const email_result = await sendStaffInviteEmail({
      toEmail: email,
      toName: name ?? null,
      role: resolvedRole,
      eventTitle,
      assignedTables: assigned_tables ?? null,
      canRecordPayments: !!can_record_payments,
      accessStartAt: access_start_at ?? null,
      accessEndAt: access_end_at ?? null,
      loginUrl: `${siteUrl}/staff/login`,
    }).catch((err) => {
      console.error('manage-door-staff: invite email threw', err);
      return { sent: false, error: 'threw' };
    });
    if (!email_result.sent) {
      console.error('manage-door-staff: invite email failed', email_result.error);
    }

    return json({ success: true, email_sent: email_result.sent });
  } catch (error) {
    console.error('manage-door-staff error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
