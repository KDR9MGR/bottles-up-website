import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions, isPreviewOrLocalOrigin } from '../_shared/cors.ts';
import { sendBottleSubstitutionRequestEmail } from '../_shared/bottleSubstitutionEmail.ts';

// Bottle Payment Options section 9: "Unavailable bottles - Offer a
// replacement or removal, obtain customer approval for changes and handle
// any price difference." Staff proposes exactly one option (a specific
// replacement bottle, or removal if replacement_bottle_id is omitted) and
// the customer approves or declines it via respond-bottle-substitution -
// nothing on the order changes until they do.
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
    const { bottle_line_id, reason, replacement_bottle_id } = await req.json();
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
    const actorEmail = admin?.email ?? doorStaff?.email ?? 'unknown';

    const { data: line, error: lineError } = await supabase
      .from('site_table_booking_bottles')
      .select(
        'id, booking_id, bottle_name, size, unit_price_cents, quantity, payment_status, cancelled_at, ' +
          'booking:site_table_bookings(customer_name, customer_email, currency, venue:site_venues(id, name))',
      )
      .eq('id', bottle_line_id)
      .maybeSingle();
    if (lineError || !line) {
      return json({ error: 'Bottle line not found' }, 404);
    }
    if (line.cancelled_at) {
      return json({ error: 'This item is already cancelled' }, 400);
    }
    if (line.payment_status === 'pending_payment') {
      return json({ error: 'Cannot flag an item while an online payment is still processing for it' }, 400);
    }

    const { data: existingPending } = await supabase
      .from('site_table_booking_bottle_substitutions')
      .select('id')
      .eq('bottle_line_id', bottle_line_id)
      .eq('status', 'pending')
      .maybeSingle();
    if (existingPending) {
      return json({ error: 'A substitution request for this item is already awaiting the customer' }, 409);
    }

    const booking = line.booking as unknown as {
      customer_name: string;
      customer_email: string;
      currency: string;
      venue: { id: string; name: string };
    };

    let replacementBottleName: string | null = null;
    let replacementSize: string | null = null;
    let replacementUnitPriceCents: number | null = null;
    let priceDiffCents: number;

    if (replacement_bottle_id) {
      const { data: replacement, error: replacementError } = await supabase
        .from('site_bottles')
        .select('id, venue_id, name, size, price_cents')
        .eq('id', replacement_bottle_id)
        .maybeSingle();
      if (replacementError || !replacement || replacement.venue_id !== booking.venue.id) {
        return json({ error: 'Replacement bottle not found for this venue' }, 400);
      }
      replacementBottleName = replacement.name;
      replacementSize = replacement.size;
      replacementUnitPriceCents = replacement.price_cents;
      priceDiffCents = (replacement.price_cents - line.unit_price_cents) * line.quantity;
    } else {
      // Removal only - the customer is being offered a refund/credit of the
      // full line, not a swap.
      priceDiffCents = -(line.unit_price_cents * line.quantity);
    }

    const { data: substitution, error: insertError } = await supabase
      .from('site_table_booking_bottle_substitutions')
      .insert({
        bottle_line_id,
        booking_id: line.booking_id,
        reason: reason.trim(),
        replacement_bottle_id: replacement_bottle_id ?? null,
        replacement_bottle_name: replacementBottleName,
        replacement_size: replacementSize,
        replacement_unit_price_cents: replacementUnitPriceCents,
        price_diff_cents: priceDiffCents,
        requested_by: userData.user.id,
      })
      .select('id, confirm_token')
      .single();
    if (insertError || !substitution) {
      console.error('flag-bottle-unavailable: insert failed', insertError);
      return json({ error: 'Failed to create the substitution request' }, 500);
    }

    const origin = req.headers.get('origin') ?? '';
    const allowedOrigins = (Deno.env.get('ALLOWED_ORIGIN') ?? '').split(',').map((o: string) => o.trim());
    const siteUrl = allowedOrigins.includes(origin) || isPreviewOrLocalOrigin(origin)
      ? origin
      : (Deno.env.get('SITE_URL') ?? 'https://bottlesupapp.com');

    const email = await sendBottleSubstitutionRequestEmail({
      toEmail: booking.customer_email,
      toName: booking.customer_name,
      venueName: booking.venue.name,
      originalBottleName: line.bottle_name,
      originalSize: line.size,
      quantity: line.quantity,
      reason: reason.trim(),
      replacementBottleName,
      replacementSize,
      priceDiffCents,
      currency: booking.currency,
      confirmUrl: `${siteUrl}/bottle-substitution/confirm/${substitution.confirm_token}`,
    });
    if (!email.sent) {
      console.error('flag-bottle-unavailable: email send failed', email.error);
    }

    await supabase.from('audit_log').insert({
      actor_id: userData.user.id,
      actor_email: actorEmail,
      action: 'table_booking.bottle_flagged_unavailable',
      entity_type: 'site_table_booking_bottles',
      entity_id: bottle_line_id,
      details: { substitution_id: substitution.id, reason: reason.trim(), replacement_bottle_id: replacement_bottle_id ?? null },
    });

    return json({ success: true, substitution_id: substitution.id, email_sent: email.sent });
  } catch (error) {
    console.error('flag-bottle-unavailable error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
