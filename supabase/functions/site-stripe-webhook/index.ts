import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';
import QRCode from 'npm:qrcode@1.5.3';
import { generateTicketCode, sendTicketEmail } from '../_shared/ticketEmail.ts';
import { generateConfirmationCode, sendTableBookingEmail, formatTimeSlot } from '../_shared/tableBookingEmail.ts';

const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const signature = req.headers.get('stripe-signature');
  const body = await req.text();

  const stripeSecretKey =
    Deno.env.get('STRIPE_SECRET_KEY_LIVE') ??
    Deno.env.get('STRIPE_SECRET_KEY_TEST') ??
    Deno.env.get('STRIPE_SECRET_KEY') ??
    Deno.env.get('test_SK');

  if (!stripeSecretKey) {
    return new Response('Stripe is not configured', { status: 500 });
  }

  const stripe = new Stripe(stripeSecretKey, {
    apiVersion: '2024-06-20',
    httpClient: Stripe.createFetchHttpClient(),
  });

  const webhookSecrets = [
    Deno.env.get('STRIPE_WEBHOOK_SECRET_TEST'),
    Deno.env.get('STRIPE_WEBHOOK_SECRET_LIVE'),
    Deno.env.get('STRIPE_WEBHOOK_SECRET'),
  ].filter((s): s is string => !!s);

  let event: Stripe.Event;
  try {
    let lastError: unknown;
    let verified: Stripe.Event | null = null;

    for (const secret of webhookSecrets) {
      try {
        verified = await stripe.webhooks.constructEventAsync(body, signature!, secret, undefined, cryptoProvider);
        break;
      } catch (err) {
        lastError = err;
      }
    }

    if (!verified) {
      throw lastError ?? new Error('Webhook signature verification failed');
    }

    event = verified;
  } catch (err) {
    console.error('Webhook signature verification failed:', err);
    return new Response('Invalid signature', { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session;
    const orderId = session.metadata?.order_id;
    const bookingId = session.metadata?.booking_id;

    if (!orderId && !bookingId) {
      console.error('checkout.session.completed with no order_id/booking_id metadata:', session.id);
      return new Response('ok', { status: 200 });
    }

    if (bookingId) {
      const { data: booking, error: bookingError } = await supabase
        .from('site_table_bookings')
        .select('*, table_type:site_table_types(*), venue:site_venues(*), time_slot:site_venue_time_slots(*)')
        .eq('id', bookingId)
        .single();

      if (bookingError || !booking) {
        console.error('Booking not found for webhook:', bookingId, bookingError);
        return new Response('ok', { status: 200 });
      }

      if (booking.confirmation_sent_at) {
        return new Response('ok', { status: 200 });
      }

      const confirmationCode = booking.confirmation_code ?? generateConfirmationCode();
      const alreadyPaid = booking.status === 'paid';

      if (!alreadyPaid || !booking.confirmation_code) {
        const { error: updateError } = await supabase
          .from('site_table_bookings')
          .update({
            status: 'paid',
            stripe_payment_intent_id:
              typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id,
            confirmation_code: confirmationCode,
          })
          .eq('id', bookingId);

        if (updateError) {
          console.error('Failed to update booking after payment:', updateError);
          return new Response('ok', { status: 200 });
        }
      }

      const qrDataUrl = await QRCode.toDataURL(confirmationCode, { width: 400, margin: 1 });
      const tableType = booking.table_type as { name: string };
      const venue = booking.venue as { name: string };
      const timeSlot = booking.time_slot as { start_time: string };

      const email = await sendTableBookingEmail({
        toEmail: booking.customer_email,
        toName: booking.customer_name,
        venueName: venue.name,
        tableTypeName: tableType.name,
        bookingDate: booking.booking_date,
        timeSlotLabel: formatTimeSlot(timeSlot.start_time),
        guestCount: booking.guest_count,
        depositCents: booking.amount_total_cents,
        currency: booking.currency,
        hours: booking.hours,
        confirmationCode,
        qrDataUrl,
      });

      if (email.sent) {
        await supabase.from('site_table_bookings').update({ confirmation_sent_at: new Date().toISOString() }).eq('id', bookingId);
      } else {
        console.error('Table booking email send failed:', email.error);
      }

      return new Response('ok', { status: 200 });
    }

    const { data: order, error: orderError } = await supabase
      .from('site_orders')
      .select('*, ticket_tiers:site_ticket_tiers(*, events:site_events(*))')
      .eq('id', orderId)
      .single();

    if (orderError || !order) {
      console.error('Order not found for webhook:', orderId, orderError);
      return new Response('ok', { status: 200 });
    }

    if (order.ticket_sent_at) {
      return new Response('ok', { status: 200 });
    }

    const ticketCode = order.ticket_code ?? generateTicketCode();
    const alreadyPaid = order.status === 'paid';

    if (!alreadyPaid || !order.ticket_code) {
      const { error: updateError } = await supabase
        .from('site_orders')
        .update({
          status: 'paid',
          stripe_payment_intent_id:
            typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id,
          ticket_code: ticketCode,
        })
        .eq('id', orderId);

      if (updateError) {
        console.error('Failed to update order after payment:', updateError);
        return new Response('ok', { status: 200 });
      }

      if (!alreadyPaid) {
        await supabase.rpc('increment_tier_sold', { p_tier_id: order.tier_id, p_qty: order.quantity });
      }
    }

    const qrDataUrl = await QRCode.toDataURL(ticketCode, { width: 400, margin: 1 });

    const tier = order.ticket_tiers as { name: string; events: { title: string; venue_name: string; start_date: string } };
    const email = await sendTicketEmail({
      toEmail: order.customer_email,
      toName: order.customer_name,
      eventTitle: tier.events.title,
      venueName: tier.events.venue_name,
      startDate: tier.events.start_date,
      tierName: tier.name,
      quantity: order.quantity,
      ticketCode,
      qrDataUrl,
    });

    if (email.sent) {
      await supabase.from('site_orders').update({ ticket_sent_at: new Date().toISOString() }).eq('id', orderId);
    } else {
      console.error('Ticket email send failed:', email.error);
    }
  }

  return new Response('ok', { status: 200 });
});
