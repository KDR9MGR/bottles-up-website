import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { cancelBottleLine } from '../_shared/bottleCancellation.ts';
import { recomputeTableBookingTotals } from '../_shared/bookingTotals.ts';

// Public, unauthenticated - the confirm_token is the capability, same
// pattern as respond-club-payment. Only ever transitions a substitution
// request out of 'pending' - once answered, it's locked. Approving a
// removal reuses cancelBottleLine() (the exact same path a staff-initiated
// cancellation takes) so "cancelled" always means one thing across this
// feature.
Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  try {
    const { token, action } = await req.json();
    if (!token || typeof token !== 'string') {
      return json({ error: 'token is required' }, 400);
    }
    if (action !== 'approve' && action !== 'decline') {
      return json({ error: 'Invalid action' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: sub, error: subError } = await supabase
      .from('site_table_booking_bottle_substitutions')
      .select(
        'id, bottle_line_id, booking_id, status, replacement_bottle_id, replacement_bottle_name, ' +
          'replacement_size, replacement_unit_price_cents, ' +
          'bottle_line:site_table_booking_bottles(id, quantity, unit_price_cents, cancelled_at), ' +
          'booking:site_table_bookings(customer_email)',
      )
      .eq('confirm_token', token)
      .maybeSingle();

    if (subError || !sub) {
      return json({ error: 'Substitution request not found' }, 404);
    }
    if (sub.status !== 'pending') {
      return json({ success: false, error: 'already_responded', status: sub.status });
    }

    const bottleLine = sub.bottle_line as unknown as { id: string; quantity: number; unit_price_cents: number; cancelled_at: string | null };
    const booking = sub.booking as unknown as { customer_email: string };

    if (bottleLine.cancelled_at) {
      return json({ error: 'This item was already cancelled' }, 400);
    }

    if (action === 'decline') {
      const { error: updateError } = await supabase
        .from('site_table_booking_bottle_substitutions')
        .update({ status: 'declined', responded_at: new Date().toISOString() })
        .eq('id', sub.id);
      if (updateError) {
        console.error('respond-bottle-substitution: decline update failed', updateError);
        return json({ error: 'Failed to record your response' }, 500);
      }
      await supabase.from('audit_log').insert({
        actor_email: booking.customer_email,
        action: 'table_booking.bottle_substitution_declined',
        entity_type: 'site_table_booking_bottle_substitutions',
        entity_id: sub.id,
      });
      return json({ success: true, status: 'declined' });
    }

    // Approve.
    if (sub.replacement_bottle_id) {
      const newLineTotal = (sub.replacement_unit_price_cents ?? bottleLine.unit_price_cents) * bottleLine.quantity;
      const { error: updateLineError } = await supabase
        .from('site_table_booking_bottles')
        .update({
          bottle_id: sub.replacement_bottle_id,
          bottle_name: sub.replacement_bottle_name,
          size: sub.replacement_size,
          unit_price_cents: sub.replacement_unit_price_cents,
          line_total_cents: newLineTotal,
        })
        .eq('id', bottleLine.id);
      if (updateLineError) {
        console.error('respond-bottle-substitution: line swap failed', updateLineError);
        return json({ error: 'Failed to apply the replacement' }, 500);
      }

      const totals = await recomputeTableBookingTotals(supabase, sub.booking_id);
      const { error: bookingUpdateError } = await supabase
        .from('site_table_bookings')
        .update({
          bottle_subtotal_cents: totals.bottleSubtotalCents,
          tax_cents: totals.taxCents,
          bottlesup_fee_cents: totals.bottlesupFeeCents,
          amount_total_cents: totals.amountTotalCents,
        })
        .eq('id', sub.booking_id);
      if (bookingUpdateError) {
        console.error('respond-bottle-substitution: totals update failed', bookingUpdateError);
        return json({ error: 'Failed to update totals' }, 500);
      }
    } else {
      const cancelResult = await cancelBottleLine(supabase, {
        bottleLineId: bottleLine.id,
        reason: 'Customer approved removal after the bottle was flagged unavailable',
        actorId: null,
        actorEmail: booking.customer_email,
      });
      if (!cancelResult.success) {
        return json({ error: cancelResult.error ?? 'Failed to remove this item' }, 500);
      }
    }

    const { error: updateSubError } = await supabase
      .from('site_table_booking_bottle_substitutions')
      .update({ status: 'approved', responded_at: new Date().toISOString() })
      .eq('id', sub.id);
    if (updateSubError) {
      console.error('respond-bottle-substitution: approve update failed', updateSubError);
      return json({ error: 'Failed to record your response' }, 500);
    }

    await supabase.from('audit_log').insert({
      actor_email: booking.customer_email,
      action: 'table_booking.bottle_substitution_approved',
      entity_type: 'site_table_booking_bottle_substitutions',
      entity_id: sub.id,
      details: { replacement_bottle_id: sub.replacement_bottle_id ?? null },
    });

    return json({ success: true, status: 'approved' });
  } catch (error) {
    console.error('respond-bottle-substitution error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
