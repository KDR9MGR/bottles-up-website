import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { addBottlesToBooking, type BottleRequest } from '../_shared/bottleOrdering.ts';

// Bottle Payment Options section 8: "customers can also order through...a
// table QR code" - no account needed, anyone physically at the table (the
// booking's own guest, or anyone they hand the code to) can order more
// bottles by scanning a QR code that encodes this booking's confirmation
// code. The confirmation code is the capability here, same "code/token is
// the capability" pattern as a Stripe checkout session id, a club payment's
// confirm_token, or the confirmation code already used for door check-in
// elsewhere in this app - unguessable, generated server-side, known only to
// whoever received the original booking confirmation.
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
    const { confirmation_code, bottles: requestedBottles, bottle_payment_choice } = await req.json();

    if (!confirmation_code || typeof confirmation_code !== 'string') {
      return json({ error: 'confirmation_code is required' }, 400);
    }
    if (!Array.isArray(requestedBottles) || requestedBottles.length === 0) {
      return json({ error: 'Select at least one bottle' }, 400);
    }
    const bottleRequests: BottleRequest[] = [];
    for (const b of requestedBottles) {
      const qty = Number(b?.quantity);
      if (typeof b?.bottle_id !== 'string' || !b.bottle_id || !Number.isInteger(qty) || qty < 1) {
        return json({ error: 'Invalid bottle selection' }, 400);
      }
      bottleRequests.push({ bottle_id: b.bottle_id, quantity: qty });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: booking, error: bookingError } = await supabase
      .from('site_table_bookings')
      .select('id, customer_email')
      .eq('confirmation_code', confirmation_code)
      .maybeSingle();

    if (bookingError || !booking) {
      return json({ error: 'No booking found for that code' }, 404);
    }

    const origin = req.headers.get('origin') ?? '';
    const result = await addBottlesToBooking(supabase, {
      bookingId: booking.id,
      bottleRequests,
      isStaff: false,
      requestedPaymentChoice: bottle_payment_choice === 'pay_at_club' ? 'pay_at_club' : undefined,
      actorId: null,
      actorEmail: booking.customer_email,
      origin,
      allowedOriginEnv: Deno.env.get('ALLOWED_ORIGIN') ?? '',
      siteUrlEnv: Deno.env.get('SITE_URL') ?? '',
    });

    return json(result.body, result.status);
  } catch (error) {
    console.error('order-bottles-by-code error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
