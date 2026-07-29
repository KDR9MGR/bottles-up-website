import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { MapPinned, Crown, Award, ArrowRight } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import type { TableTypeWithVenue } from '@/pages/VipTables';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];

type VenueWithNested = VenueRow & {
  site_table_types: TableTypeRow[];
  site_venue_time_slots: TimeSlotRow[];
};

const PROMO_HIGHLIGHTS = [
  { icon: MapPinned, label: 'Premium Locations' },
  { icon: Crown, label: 'Dedicated Host' },
  { icon: Award, label: 'World Class Service' },
];

const PopularVipTables = () => {
  const [tableTypes, setTableTypes] = useState<TableTypeWithVenue[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase
      .from('site_venues')
      .select('*, site_table_types(*), site_venue_time_slots(*)')
      .eq('status', 'published')
      .then(({ data }) => {
        const venues = (data as VenueWithNested[]) ?? [];
        const flattened: TableTypeWithVenue[] = venues.flatMap((venue) =>
          venue.site_table_types
            .slice()
            .sort((a, b) => a.sort_order - b.sort_order)
            .map((tableType) => ({
              ...tableType,
              venue,
              timeSlots: venue.site_venue_time_slots,
            })),
        );
        setTableTypes(flattened);
        setLoading(false);
      });
  }, []);

  if (!loading && tableTypes.length === 0) {
    return null;
  }

  const featured = tableTypes.find((t) => t.is_featured) ?? tableTypes[0];

  return (
    <section className="bg-black py-20 lg:py-28">
      <div className="container mx-auto px-4 lg:px-6">
        {loading ? (
          <div className="h-80 animate-pulse rounded-3xl border border-white/10 bg-white/[0.03]" />
        ) : (
          <div className="grid overflow-hidden rounded-3xl border border-white/10 bg-white/[0.03] backdrop-blur-xl lg:grid-cols-2">
            <div className="relative h-64 lg:h-auto">
              <img
                src={featured.image_url ?? featured.venue.cover_image_url ?? '/placeholder.svg'}
                alt={featured.venue.name}
                className="h-full w-full object-cover"
              />
              <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-black/10 to-transparent lg:bg-gradient-to-r" />
            </div>

            <div className="flex flex-col justify-center p-8 lg:p-14">
              <span className="mb-4 inline-flex w-fit items-center gap-2 rounded-full border border-orange-500/30 bg-orange-500/10 px-4 py-1.5 text-xs font-semibold uppercase tracking-wide text-orange-500">
                <Crown className="h-3.5 w-3.5" />
                VIP Tables
              </span>
              <h2 className="mb-4 text-3xl font-bold text-white lg:text-4xl">
                Book a <span className="text-gradient">VIP Table</span>
              </h2>
              <p className="mb-8 max-w-md text-lg leading-relaxed text-gray-400">
                Elevate your night with premium tables, bottle service, and unforgettable experiences at Toronto's
                hottest venues.
              </p>

              <div className="mb-8 grid grid-cols-3 gap-4">
                {PROMO_HIGHLIGHTS.map(({ icon: Icon, label }) => (
                  <div key={label} className="flex flex-col items-start gap-2">
                    <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-white/5">
                      <Icon className="h-5 w-5 text-orange-500" />
                    </div>
                    <span className="text-sm text-gray-300">{label}</span>
                  </div>
                ))}
              </div>

              <Button
                asChild
                size="lg"
                className="group h-14 w-fit rounded-full bg-gradient-orange border-0 px-8 font-bold text-black shadow-lg shadow-orange-500/20 transition-all duration-300 hover:scale-105 hover:shadow-orange-500/40"
              >
                <Link to="/vip-tables">
                  Browse VIP Tables
                  <ArrowRight className="ml-2 h-4 w-4 transition-transform group-hover:translate-x-1" />
                </Link>
              </Button>
            </div>
          </div>
        )}
      </div>
    </section>
  );
};

export default PopularVipTables;
