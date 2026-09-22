import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

// Public, unauthenticated lookup by confirm_token - same "token is the
// capability" reasoning as lookup-club-payment. Powers the standalone
// /bottle-substitution/confirm/:token page.
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
    const { token } = await req.json();
    if (!token || typeof token !== 'string') {
      return json({ error: 'token is required' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: sub, error } = await supabase
      .from('site_table_booking_bottle_substitutions')
      .select(
        'id, reason, replacement_bottle_name, replacement_size, price_diff_cents, status, requested_at, ' +
          'bottle_line:site_table_booking_bottles(bottle_name, size, quantity), ' +
          'booking:site_table_bookings(customer_name, confirmation_code, currency, venue:site_venues(name))',
      )
      .eq('confirm_token', token)
      .maybeSingle();

    if (error || !sub) {
      return json({ found: false });
    }

    const bottleLine = sub.bottle_line as unknown as { bottle_name: string; size: string | null; quantity: number };
    const booking = sub.booking as unknown as {
      customer_name: string;
      confirmation_code: string;
      currency: string;
      venue: { name: string };
    };

    return json({
      found: true,
      status: sub.status,
      reason: sub.reason,
      originalBottleName: bottleLine.bottle_name,
      originalSize: bottleLine.size,
      quantity: bottleLine.quantity,
      replacementBottleName: sub.replacement_bottle_name,
      replacementSize: sub.replacement_size,
      priceDiffCents: sub.price_diff_cents,
      currency: booking.currency,
      customerName: booking.customer_name,
      confirmationCode: booking.confirmation_code,
      venueName: booking.venue.name,
    });
  } catch (error) {
    console.error('lookup-bottle-substitution error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
