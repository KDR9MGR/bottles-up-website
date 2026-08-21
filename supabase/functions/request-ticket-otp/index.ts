import { createClient } from 'npm:@supabase/supabase-js@2';
import bcrypt from 'npm:bcryptjs@2.4.3';
import { generateOtpCode, sendOtpEmail } from '../_shared/otpEmail.ts';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';

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
  if (userError || !userData.user?.email) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  try {
    const { order_id } = await req.json();
    if (!order_id) return json({ error: 'order_id is required' }, 400);

    const { data: order, error: orderError } = await supabase
      .from('site_orders')
      .select('id, customer_name, customer_email, is_non_transferable, status, checked_in_at, site_events(title)')
      .eq('id', order_id)
      .single();

    if (orderError || !order) return json({ error: 'Order not found' }, 404);

    // Only the verified owner of the booking can request a code for it - RLS
    // already scopes a signed-in customer's *reads* to their own email
    // (see "users read own orders by verified email"), but this function runs
    // as service-role, so that check has to be repeated explicitly here.
    if (order.customer_email.toLowerCase() !== userData.user.email.toLowerCase()) {
      return json({ error: 'Unauthorized' }, 403);
    }
    if (!order.is_non_transferable) {
      return json({ error: 'This ticket does not require an entry code' }, 400);
    }
    if (order.status !== 'paid') {
      return json({ error: 'Ticket is not paid' }, 400);
    }
    if (order.checked_in_at) {
      return json({ error: 'Ticket has already been used' }, 400);
    }

    const code = generateOtpCode();
    const codeHash = bcrypt.hashSync(code, 10);

    // Only one live code per booking at a time.
    await supabase
      .from('ticket_otp_codes')
      .update({ status: 'expired' })
      .eq('order_id', order_id)
      .eq('status', 'active');

    await supabase.from('ticket_otp_codes').insert({
      order_id,
      code_hash: codeHash,
      sent_to_email: order.customer_email,
      expires_at: new Date(Date.now() + 5 * 60_000).toISOString(),
    });

    const event = order.site_events as unknown as { title: string } | null;
    const result = await sendOtpEmail({
      toEmail: order.customer_email,
      toName: order.customer_name,
      eventTitle: event?.title ?? 'your event',
      code,
    });

    if (!result.sent) {
      return json({ error: result.error ?? 'Email provider failed to send' }, 500);
    }

    return json({
      success: true,
      email_preview: order.customer_email.replace(/(.{2}).*(@.*)/, '$1***$2'),
      expires_in_seconds: 300,
    });
  } catch (error) {
    console.error('request-ticket-otp error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
