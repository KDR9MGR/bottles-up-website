import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Users, MapPin, Wine, ArrowRight, Info } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import TableBookingDialog from './TableBookingDialog';
import type { TableTypeWithVenue } from '@/pages/VipTables';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];

type VenueWithNested = VenueRow & {
  site_table_types: TableTypeRow[];
  site_venue_time_slots: TimeSlotRow[];
};

const PopularVipTables = () => {
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
        setTableTypes(flattened.slice(0, 3));
        setLoading(false);
      });
  }, []);

  if (!loading && tableTypes.length === 0) {
    return null;
  }

  return (
    <section className="py-16 lg:py-24">
      <div className="container mx-auto px-4 lg:px-6">
        <div className="text-center mb-16">
          <h2 className="text-3xl lg:text-5xl font-bold mb-6">
            VIP <span className="text-gradient">Tables</span>
          </h2>
          <p className="text-lg lg:text-xl text-muted-foreground max-w-3xl mx-auto">
            Skip the line, get bottle service, and own the best spot in the room.
          </p>
        </div>

        {loading ? (
          <div className="text-center text-muted-foreground">Loading...</div>
        ) : (
          <div className="grid md:grid-cols-2 lg:grid-cols-3 gap-6 lg:gap-8 mb-12">
            {tableTypes.map((tableType, index) => (
              <Card
                key={tableType.id}
                className={`overflow-hidden transition-all duration-300 group animate-fade-in ${
                  tableType.is_featured
                    ? 'border-2 border-primary shadow-[0_0_30px_-10px_hsl(var(--primary))]'
                    : 'border-border hover:border-primary/50'
                }`}
                style={{ animationDelay: `${index * 0.1}s` }}
              >
                <div className="relative">
                  <img
                    src={tableType.image_url ?? tableType.venue.cover_image_url ?? '/placeholder.svg'}
                    alt={tableType.name}
                    className="w-full h-48 object-cover group-hover:scale-105 transition-transform duration-300"
                  />
                  {tableType.badge_label && (
                    <div
                      className={`absolute top-3 right-3 px-3 py-1 rounded-full text-xs font-bold uppercase tracking-wide ${
                        tableType.is_featured ? 'bg-gradient-orange text-black' : 'bg-black/70 text-white'
                      }`}
                    >
                      {tableType.badge_label}
                    </div>
                  )}
                </div>

                <CardContent className="p-6">
                  <h3 className="text-xl font-semibold mb-2 group-hover:text-primary transition-colors">
                    {tableType.name}
                  </h3>

                  <div className="space-y-2 mb-4 text-sm text-muted-foreground">
                    <div className="flex items-center space-x-2">
                      <MapPin className="w-4 h-4 text-primary" />
                      <span>{tableType.venue.name}</span>
                    </div>
                    <div className="flex items-center space-x-2">
                      <Users className="w-4 h-4 text-primary" />
                      <span>Up to {tableType.max_guests} guests</span>
                    </div>
                    {tableType.description && (
                      <div className="flex items-center space-x-2">
                        <Wine className="w-4 h-4 text-primary" />
                        <span>{tableType.description}</span>
                      </div>
                    )}
                  </div>

                  <div className="flex items-center justify-between mb-4 text-sm">
                    <span className="text-muted-foreground">Minimum Spend</span>
                    <span className="font-semibold">${(tableType.min_spend_cents / 100).toFixed(0)}</span>
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

        <div className="text-center">
          <Button asChild variant="outline" size="lg" className="border-border">
            <Link to="/vip-tables">
              View All VIP Tables
              <ArrowRight className="ml-2 h-4 w-4" />
            </Link>
          </Button>
        </div>
      </div>

      <TableBookingDialog
        tableType={bookingTableType}
        open={!!bookingTableType}
        onOpenChange={(open) => !open && setBookingTableType(null)}
      />
    </section>
  );
};

export default PopularVipTables;
