import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

// Public, unauthenticated - powers the /order/:code page (section 8's table
// QR code ordering) so it knows which venue's bottle menu to show and which
// payment modes are available, before the customer picks anything. Returns
// only the minimal display fields, not the booking's own PII/financial
// columns - unlike a broader RLS policy, this curates exactly what's exposed
// to anyone holding the code.
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
    const { confirmation_code } = await req.json();
    if (!confirmation_code || typeof confirmation_code !== 'string') {
      return json({ error: 'confirmation_code is required' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: booking, error } = await supabase
      .from('site_table_bookings')
      .select(
        'status, currency, venue:site_venues(id, name, bottle_payment_mode), table_type:site_table_types(name)',
      )
      .eq('confirmation_code', confirmation_code)
      .maybeSingle();

    if (error || !booking || booking.status !== 'paid') {
      return json({ found: false });
    }

    const venue = booking.venue as unknown as { id: string; name: string; bottle_payment_mode: string };
    const tableType = booking.table_type as unknown as { name: string };

    return json({
      found: true,
      venueId: venue.id,
      venueName: venue.name,
      bottlePaymentMode: venue.bottle_payment_mode,
      tableTypeName: tableType.name,
      currency: booking.currency,
    });
  } catch (error) {
    console.error('lookup-order-context error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
