import { createClient } from 'npm:@supabase/supabase-js@2';
import QRCode from 'npm:qrcode@1.5.3';
import { sendTicketEmail } from '../_shared/ticketEmail.ts';
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
    const { order_id } = await req.json();
    if (!order_id) return json({ error: 'order_id is required' }, 400);

    const { data: order, error: orderError } = await supabase
      .from('site_orders')
      .select('*, ticket_tiers:site_ticket_tiers(*, events:site_events(*))')
      .eq('id', order_id)
      .single();

    if (orderError || !order) return json({ error: 'Order not found' }, 404);
    if (order.status !== 'paid' || !order.ticket_code) {
      return json({ error: 'Order has no ticket to resend (not paid yet)' }, 400);
    }

    const qrDataUrl = await QRCode.toDataURL(order.ticket_code, { width: 400, margin: 1 });
    const tier = order.ticket_tiers as { name: string; events: { title: string; venue_name: string; start_date: string } };

    const result = await sendTicketEmail({
      toEmail: order.customer_email,
      toName: order.customer_name,
      eventTitle: tier.events.title,
      venueName: tier.events.venue_name,
      startDate: tier.events.start_date,
      tierName: tier.name,
      quantity: order.quantity,
      ticketCode: order.ticket_code,
      qrDataUrl,
    });

    if (!result.sent) {
      return json({ error: result.error ?? 'Email provider failed to send' }, 500);
    }

    await supabase.from('site_orders').update({ ticket_sent_at: new Date().toISOString() }).eq('id', order_id);

    await supabase.from('audit_log').insert({
      actor_id: userData.user.id,
      actor_email: userData.user.email ?? 'unknown',
      action: 'ticket.resent',
      entity_type: 'site_orders',
      entity_id: order_id,
      details: { ticket_code: order.ticket_code },
    });

    return json({ success: true });
  } catch (error) {
    console.error('resend-ticket-email error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
