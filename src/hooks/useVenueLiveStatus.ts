import { useEffect, useMemo, useState } from 'react';
import { format } from 'date-fns';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];

export interface VenueStatus {
  venue: VenueRow;
  totalTables: number;
  tablesBookedTonight: number;
  tablesLeft: number;
  fillRate: number;
  status: 'Filling' | 'Busy' | 'Packed' | 'No tables';
}

// Fill-rate is a proxy for "how busy is this venue" derived from tonight's
// table-booking demand - there's no foot-traffic/crowd-counter system, so this
// is the honest signal actually available (see project memory: computed from
// booking fill-rate, not a fabricated live occupancy number).
const statusFor = (fillRate: number, totalTables: number): VenueStatus['status'] => {
  if (totalTables === 0) return 'No tables';
  if (fillRate >= 75) return 'Packed';
  if (fillRate >= 40) return 'Busy';
  return 'Filling';
};

export function useVenueLiveStatus() {
  const [venues, setVenues] = useState<VenueRow[]>([]);
  const [tableTypes, setTableTypes] = useState<TableTypeRow[]>([]);
  const [bookedCounts, setBookedCounts] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const load = async () => {
      const today = format(new Date(), 'yyyy-MM-dd');
      const [{ data: venuesData }, { data: tableTypesData }, { data: bookingsData }] = await Promise.all([
        supabase.from('site_venues').select('*').eq('status', 'published'),
        supabase.from('site_table_types').select('*'),
        supabase.from('site_table_bookings').select('venue_id').eq('booking_date', today).eq('status', 'paid'),
      ]);
      setVenues(venuesData ?? []);
      setTableTypes(tableTypesData ?? []);
      const counts: Record<string, number> = {};
      (bookingsData ?? []).forEach((b) => {
        counts[b.venue_id] = (counts[b.venue_id] ?? 0) + 1;
      });
      setBookedCounts(counts);
      setLoading(false);
    };
    load();
  }, []);

  const venueStatuses = useMemo<VenueStatus[]>(() => {
    return venues
      .map((venue) => {
        const totalTables = tableTypes
          .filter((t) => t.venue_id === venue.id)
          .reduce((sum, t) => sum + t.inventory_count, 0);
        const tablesBookedTonight = bookedCounts[venue.id] ?? 0;
        const tablesLeft = Math.max(0, totalTables - tablesBookedTonight);
        const fillRate = totalTables > 0 ? Math.round((tablesBookedTonight / totalTables) * 100) : 0;
        return {
          venue,
          totalTables,
          tablesBookedTonight,
          tablesLeft,
          fillRate,
          status: statusFor(fillRate, totalTables),
        };
      })
      .sort((a, b) => b.fillRate - a.fillRate);
  }, [venues, tableTypes, bookedCounts]);

  return { venueStatuses, tableTypes, loading };
}
