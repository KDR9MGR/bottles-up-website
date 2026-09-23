import { createClient } from 'npm:@supabase/supabase-js@2';
import QRCode from 'npm:qrcode@1.5.3';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { formatTimeSlot } from '../_shared/tableBookingEmail.ts';
import { generateGuestCode, sendGuestTicketEmail } from '../_shared/guestTicketEmail.ts';

// Public, unauthenticated - powers the /booking/:code page's guest-list
// section the same way lookup-order-context/order-bottles-by-code power the
// bottle-ordering half of that trust model: whoever holds the booking's
// confirmation_code can act on it, no login required. Three actions:
//   list   - booking summary + current guest roster + remaining capacity
//   add    - add up to the table's remaining capacity, email each guest
//            their own QR ticket
//   resend - re-send one already-added guest's ticket email
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
    const payload = await req.json();
    const confirmationCode = payload?.confirmation_code;
    const action = payload?.action;

    if (!confirmationCode || typeof confirmationCode !== 'string') {
      return json({ error: 'confirmation_code is required' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: booking, error: bookingError } = await supabase
      .from('site_table_bookings')
      .select(
        'id, status, customer_name, customer_email, guest_count, booking_date, ' +
          'venue:site_venues(name), table_type:site_table_types(name, max_guests), ' +
          'time_slot:site_venue_time_slots(start_time)',
      )
      .eq('confirmation_code', confirmationCode)
      .maybeSingle();

    if (bookingError || !booking || booking.status !== 'paid') {
      return json({ error: 'No confirmed booking found for that code' }, 404);
    }

    const venue = booking.venue as unknown as { name: string };
    const tableType = booking.table_type as unknown as { name: string; max_guests: number | null };
    const timeSlot = booking.time_slot as unknown as { start_time: string };
    const maxGuests = tableType.max_guests ?? booking.guest_count;

    const { data: existingGuests, error: guestsError } = await supabase
      .from('guest_tickets')
      .select('id, guest_name, guest_email, ticket_sent_at, checked_in_at')
      .eq('booking_id', booking.id)
      .order('created_at', { ascending: true });

    if (guestsError) {
      console.error('manage-guest-tickets: failed to load existing guests', guestsError);
      return json({ error: 'Failed to load guest list' }, 500);
    }

    const remainingCapacity = Math.max(maxGuests - 1 - (existingGuests?.length ?? 0), 0);

    if (action === 'list' || !action) {
      return json({
        booking: {
          customerName: booking.customer_name,
          venueName: venue.name,
          tableTypeName: tableType.name,
          bookingDate: booking.booking_date,
          timeSlotLabel: formatTimeSlot(timeSlot.start_time),
          maxGuests,
          remainingCapacity,
        },
        guests: existingGuests ?? [],
      });
    }

    if (action === 'add') {
      const requested = payload?.guests;
      if (!Array.isArray(requested) || requested.length === 0) {
        return json({ error: 'Add at least one guest' }, 400);
      }
      const guestsToAdd: { name: string; email: string }[] = [];
      for (const g of requested) {
        const name = typeof g?.name === 'string' ? g.name.trim() : '';
        const email = typeof g?.email === 'string' ? g.email.trim() : '';
        if (!name || !email || !email.includes('@')) {
          return json({ error: 'Each guest needs a name and a valid email' }, 400);
        }
        guestsToAdd.push({ name, email });
      }

      if (guestsToAdd.length > remainingCapacity) {
        return json(
          { error: `Only ${remainingCapacity} guest ticket${remainingCapacity === 1 ? '' : 's'} left for this table` },
          400,
        );
      }

      const inserted: { id: string; guest_name: string; guest_email: string; guest_code: string }[] = [];
      for (const guest of guestsToAdd) {
        let row: { id: string; guest_name: string; guest_email: string; guest_code: string } | null = null;
        for (let attempt = 0; attempt < 3 && !row; attempt++) {
          const { data, error } = await supabase
            .from('guest_tickets')
            .insert({ booking_id: booking.id, guest_name: guest.name, guest_email: guest.email, guest_code: generateGuestCode() })
            .select('id, guest_name, guest_email, guest_code')
            .single();
          if (!error) {
            row = data;
          } else if (error.code !== '23505') {
            console.error('manage-guest-tickets: insert failed', error);
            return json({ error: 'Failed to add guest' }, 500);
          }
        }
        if (!row) {
          return json({ error: 'Failed to generate a unique ticket code, please try again' }, 500);
        }
        inserted.push(row);
      }

      const results = await Promise.all(
        inserted.map(async (guest) => {
          const qrDataUrl = await QRCode.toDataURL(guest.guest_code, { width: 400, margin: 1 });
          const email = await sendGuestTicketEmail({
            toEmail: guest.guest_email,
            toName: guest.guest_name,
            hostName: booking.customer_name,
            venueName: venue.name,
            tableTypeName: tableType.name,
            bookingDate: booking.booking_date,
            timeSlotLabel: formatTimeSlot(timeSlot.start_time),
            guestCode: guest.guest_code,
            qrDataUrl,
          });
          if (email.sent) {
            await supabase.from('guest_tickets').update({ ticket_sent_at: new Date().toISOString() }).eq('id', guest.id);
          } else {
            console.error('manage-guest-tickets: email send failed for', guest.id, email.error);
          }
          return { id: guest.id, guest_name: guest.guest_name, guest_email: guest.guest_email, sent: email.sent };
        }),
      );

      return json({ success: true, results });
    }

    if (action === 'resend') {
      const guestId = payload?.guest_id;
      if (!guestId || typeof guestId !== 'string') {
        return json({ error: 'guest_id is required' }, 400);
      }
      const { data: guest, error: guestError } = await supabase
        .from('guest_tickets')
        .select('id, guest_name, guest_email, guest_code, booking_id')
        .eq('id', guestId)
        .eq('booking_id', booking.id)
        .maybeSingle();

      if (guestError || !guest) {
        return json({ error: 'Guest not found on this booking' }, 404);
      }

      const qrDataUrl = await QRCode.toDataURL(guest.guest_code, { width: 400, margin: 1 });
      const email = await sendGuestTicketEmail({
        toEmail: guest.guest_email,
        toName: guest.guest_name,
        hostName: booking.customer_name,
        venueName: venue.name,
        tableTypeName: tableType.name,
        bookingDate: booking.booking_date,
        timeSlotLabel: formatTimeSlot(timeSlot.start_time),
        guestCode: guest.guest_code,
        qrDataUrl,
      });

      if (!email.sent) {
        return json({ error: "Couldn't resend that ticket, please try again" }, 500);
      }
      await supabase.from('guest_tickets').update({ ticket_sent_at: new Date().toISOString() }).eq('id', guest.id);
      return json({ success: true });
    }

    return json({ error: 'Unknown action' }, 400);
  } catch (error) {
    console.error('manage-guest-tickets error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
