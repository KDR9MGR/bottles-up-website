import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { cancelBottleLine } from '../_shared/bottleCancellation.ts';

// Bottle Payment Options section 9: staff-initiated cancellation of a single
// bottle line (e.g. a mistaken entry, or the customer changed their mind).
// Staff-authenticated the same way as every other CMS/door action in this
// feature. Refunding a paid item is a deliberate, separate step (see
// refund-table-booking-payment) - this only ever marks the line cancelled
// and recomputes totals, never moves money.
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

  try {
    const { bottle_line_id, reason } = await req.json();
    if (!bottle_line_id || typeof bottle_line_id !== 'string') {
      return json({ error: 'bottle_line_id is required' }, 400);
    }
    if (!reason || typeof reason !== 'string' || !reason.trim()) {
      return json({ error: 'A reason is required' }, 400);
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

    const [{ data: admin }, { data: doorStaff }] = await Promise.all([
      supabase.from('cms_admins').select('id, email').eq('id', userData.user.id).maybeSingle(),
      supabase.from('door_staff').select('id, email').eq('id', userData.user.id).maybeSingle(),
    ]);
    if (!admin && !doorStaff) {
      return json({ error: 'Forbidden' }, 403);
    }

    const result = await cancelBottleLine(supabase, {
      bottleLineId: bottle_line_id,
      reason: reason.trim(),
      actorId: userData.user.id,
      actorEmail: admin?.email ?? doorStaff?.email ?? 'unknown',
    });

    if (!result.success) {
      return json({ error: result.error }, 400);
    }
    return json({
      success: true,
      refund_suggested: result.wasPaid,
      line_total_cents: result.lineTotalCents,
      new_amount_total_cents: result.newAmountTotalCents,
      balance_due_cents: result.balanceDueCents,
    });
  } catch (error) {
    console.error('cancel-bottle-line error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
