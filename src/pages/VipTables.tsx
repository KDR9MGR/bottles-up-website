import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Users, MapPin, Wine, Crown, Zap, Award, MapPinned, Info } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import TableBookingDialog from '@/components/TableBookingDialog';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];

export type TableTypeWithVenue = TableTypeRow & {
  venue: VenueRow;
  timeSlots: TimeSlotRow[];
};

type VenueWithNested = VenueRow & {
  site_table_types: TableTypeRow[];
  site_venue_time_slots: TimeSlotRow[];
};

const HIGHLIGHTS = [
  { icon: MapPinned, label: 'Premium Locations' },
  { icon: Crown, label: 'Dedicated Host' },
  { icon: Zap, label: 'Skip The Line' },
  { icon: Award, label: 'World Class Service' },
];

const VipTables = () => {
  const [tableTypes, setTableTypes] = useState<TableTypeWithVenue[]>([]);
  const [loading, setLoading] = useState(true);
  const [bookingTableType, setBookingTableType] = useState<TableTypeWithVenue | null>(null);

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

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="container mx-auto px-4 py-24 lg:px-6">
        <div className="mb-8 text-center">
          <h1 className="text-3xl font-bold text-white lg:text-5xl">
            VIP <span className="text-gradient">Tables</span>
          </h1>
          <p className="mx-auto mt-4 max-w-2xl text-lg text-gray-400">
            Choose your table and enjoy the ultimate experience. Skip the line, get bottle service, and secure your
            spot for the night.
          </p>
        </div>

        <div className="mb-12 grid grid-cols-2 gap-4 rounded-2xl border border-gray-800 bg-gray-950/60 p-6 lg:grid-cols-4">
          {HIGHLIGHTS.map(({ icon: Icon, label }) => (
            <div key={label} className="flex flex-col items-center gap-2 text-center">
              <Icon className="h-6 w-6 text-primary" />
              <span className="text-sm text-gray-300">{label}</span>
            </div>
          ))}
        </div>

        <div className="mb-6 flex items-center justify-between">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-gray-400">Select a Table</h2>
        </div>

        {loading ? (
          <div className="text-center text-gray-400">Loading...</div>
        ) : tableTypes.length === 0 ? (
          <div className="text-center text-gray-400">No tables available right now - check back soon.</div>
        ) : (
          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            {tableTypes.map((tableType) => (
              <Card
                key={tableType.id}
                className={`overflow-hidden bg-card transition-all duration-300 ${
                  tableType.is_featured
                    ? 'border-2 border-primary shadow-[0_0_30px_-10px_hsl(var(--primary))]'
                    : 'border-border hover:border-primary/50'
                }`}
              >
                <div className="relative h-48 w-full">
                  <img
                    src={tableType.image_url ?? tableType.venue.cover_image_url ?? '/placeholder.svg'}
                    alt={tableType.name}
                    className="h-full w-full object-cover"
                  />
                  {tableType.badge_label && (
                    <div
                      className={`absolute top-3 right-3 rounded-full px-3 py-1 text-xs font-bold uppercase tracking-wide ${
                        tableType.is_featured ? 'bg-gradient-orange text-black' : 'bg-black/70 text-white'
                      }`}
                    >
                      {tableType.badge_label}
                    </div>
                  )}
                </div>
                <CardContent className="p-6">
                  <h3 className="mb-1 text-xl font-semibold text-white">{tableType.name}</h3>
                  <div className="mb-3 flex items-center gap-2 text-sm text-muted-foreground">
                    <MapPin className="h-4 w-4 text-primary" />
                    <span>{tableType.venue.name}</span>
                  </div>
                  <div className="mb-4 space-y-1.5 text-sm text-muted-foreground">
                    <div className="flex items-center gap-2">
                      <Users className="h-4 w-4 text-primary" />
                      <span>Up to {tableType.max_guests} guests</span>
                    </div>
                    {tableType.description && (
                      <div className="flex items-center gap-2">
                        <Wine className="h-4 w-4 text-primary" />
                        <span>{tableType.description}</span>
                      </div>
                    )}
                    <div className="flex items-center justify-between pt-1">
                      <span>Minimum Spend</span>
                      <span className="font-semibold text-white">${(tableType.min_spend_cents / 100).toFixed(0)}</span>
                    </div>
                  </div>
                  <div className="flex gap-2">
                    <Button asChild variant="outline" className="flex-1 border-border">
                      <Link to={`/venues/${tableType.venue.slug || tableType.venue.id}`}>
                        <Info className="mr-1.5 h-4 w-4" />
                        Details
                      </Link>
                    </Button>
                    <Button
                      className={
                        tableType.is_featured
                          ? 'flex-1 bg-gradient-orange text-black font-bold hover:opacity-90'
                          : 'flex-1'
                      }
                      variant={tableType.is_featured ? 'default' : 'outline'}
                      disabled={tableType.timeSlots.length === 0}
                      onClick={() => setBookingTableType(tableType)}
                    >
                      {tableType.timeSlots.length === 0 ? 'Coming Soon' : 'Buy Table'}
                    </Button>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        )}
      </section>

      <Footer />

      <TableBookingDialog
        tableType={bookingTableType}
        open={!!bookingTableType}
        onOpenChange={(open) => !open && setBookingTableType(null)}
      />
    </div>
  );
};

export default VipTables;
