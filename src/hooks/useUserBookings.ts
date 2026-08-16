import { useEffect, useState } from 'react';
import { format, parseISO } from 'date-fns';
import { supabase } from '@/lib/supabase';
import type { Session } from '@supabase/supabase-js';

export interface UnifiedBooking {
  id: string;
  type: 'ticket' | 'table';
  title: string;
  venue: string;
  date: string | null; // ISO date
  time: string;
  amountCents: number;
  currency: string;
  status: string;
  guestCount?: number;
  createdAt: string;
}

// Shared by the dashboard (upcoming/past, paid only) and the profile page's
// billing history (every status). RLS on site_orders/site_table_bookings
// scopes both queries to rows whose customer_email matches the caller's
// verified auth email - no explicit filter needed.
export function useUserBookings(session: Session | null) {
  const [bookings, setBookings] = useState<UnifiedBooking[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!session) {
      setBookings([]);
      return;
    }
    setLoading(true);

    Promise.all([
      supabase
        .from('site_orders')
        .select('id, status, quantity, amount_total_cents, currency, created_at, site_ticket_tiers(name), site_events(title, venue_name, start_date)')
        .order('created_at', { ascending: false }),
      supabase
        .from('site_table_bookings')
        .select('id, status, guest_count, amount_total_cents, currency, booking_date, created_at, site_table_types(name), site_venues(name), site_venue_time_slots(start_time)')
        .order('created_at', { ascending: false }),
    ]).then(([ordersRes, tableRes]) => {
      const orders: UnifiedBooking[] = (ordersRes.data ?? []).map((o) => {
        const event = o.site_events as unknown as { title: string; venue_name: string; start_date: string } | null;
        let time = '';
        if (event?.start_date) {
          try { time = format(parseISO(event.start_date), 'h:mm a'); } catch { time = ''; }
        }
        return {
          id: o.id,
          type: 'ticket' as const,
          title: event?.title ?? 'Event Ticket',
          venue: event?.venue_name ?? '',
          date: event?.start_date ?? null,
          time,
          amountCents: o.amount_total_cents,
          currency: o.currency,
          status: o.status,
          createdAt: o.created_at,
        };
      });

      const tables: UnifiedBooking[] = (tableRes.data ?? []).map((b) => {
        const tableType = b.site_table_types as unknown as { name: string } | null;
        const venue = b.site_venues as unknown as { name: string } | null;
        const timeSlot = b.site_venue_time_slots as unknown as { start_time: string } | null;
        return {
          id: b.id,
          type: 'table' as const,
          title: tableType?.name ?? 'VIP Table',
          venue: venue?.name ?? '',
          date: b.booking_date,
          time: timeSlot?.start_time ?? '',
          amountCents: b.amount_total_cents,
          currency: b.currency,
          status: b.status,
          guestCount: b.guest_count,
          createdAt: b.created_at,
        };
      });

      const all = [...orders, ...tables].sort(
        (a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime(),
      );

      setBookings(all);
      setLoading(false);
    });
  }, [session]);

  return { bookings, loading };
}
