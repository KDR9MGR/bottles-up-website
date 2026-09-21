import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { addBottlesToBooking, type BottleRequest } from '../_shared/bottleOrdering.ts';

// Bottle Payment Options section 3: a customer adds bottles to their OWN
// already-paid booking from "My Bookings". Section 8: staff opens the table
// and taps Add Bottles - same endpoint, since the only thing that differs is
// authorization and how the payment mode gets resolved, both handled in the
// shared addBottlesToBooking() core. Requires a signed-in session - the
// service-role client below is only used after ownership/role is verified,
// exactly like every other money-touching function in this codebase never
// trusts the client for prices.
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
    const { booking_id, bottles: requestedBottles, bottle_payment_choice } = await req.json();

    if (!booking_id || typeof booking_id !== 'string') {
      return json({ error: 'booking_id is required' }, 400);
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

    const anonClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await anonClient.auth.getUser();
    if (userError || !userData.user?.email) {
      return json({ error: 'Unauthorized' }, 401);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const [{ data: admin }, { data: doorStaff }] = await Promise.all([
      supabase.from('cms_admins').select('id').eq('id', userData.user.id).maybeSingle(),
      supabase.from('door_staff').select('id').eq('id', userData.user.id).maybeSingle(),
    ]);
    const isStaff = !!admin || !!doorStaff;

    // Ownership check - the anon client above only proves who the caller is,
    // never which bookings they're allowed to touch. This mirrors the RLS
    // policy that already scopes a customer's own SELECT access (verified
    // email = booking.customer_email). Staff can add to any booking.
    if (!isStaff) {
      const { data: booking } = await supabase
        .from('site_table_bookings')
        .select('customer_email')
        .eq('id', booking_id)
        .maybeSingle();
      if (!booking) {
        return json({ error: 'Booking not found' }, 404);
      }
      if (booking.customer_email.toLowerCase() !== userData.user.email.toLowerCase()) {
        return json({ error: 'Forbidden' }, 403);
      }
    }

    const origin = req.headers.get('origin') ?? '';
    const result = await addBottlesToBooking(supabase, {
      bookingId: booking_id,
      bottleRequests,
      isStaff,
      requestedPaymentChoice: bottle_payment_choice === 'pay_at_club' ? 'pay_at_club' : undefined,
      actorId: userData.user.id,
      actorEmail: userData.user.email,
      origin,
      allowedOriginEnv: Deno.env.get('ALLOWED_ORIGIN') ?? '',
      siteUrlEnv: Deno.env.get('SITE_URL') ?? '',
    });

    return json(result.body, result.status);
  } catch (error) {
    console.error('add-table-booking-bottles error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
