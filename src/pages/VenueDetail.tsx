import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, MapPin, Users, Wine, Crown } from 'lucide-react';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { supabase } from '@/lib/supabase';
import TableBookingDialog from '@/components/TableBookingDialog';
import VenueFloorPlanPicker from '@/components/VenueFloorPlanPicker';
import Lightbox from '@/components/Lightbox';
import type { Database } from '@/types/database';
import type { TableTypeWithVenue } from './VipTables';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];
type FloorRow = Database['public']['Tables']['site_venue_floors']['Row'];

type VenueWithNested = VenueRow & {
  site_table_types: TableTypeRow[];
  site_venue_time_slots: TimeSlotRow[];
  site_venue_floors: FloorRow[];
};

const VenueDetail = () => {
  const { id } = useParams<{ id: string }>();
  const [venue, setVenue] = useState<VenueWithNested | null>(null);
  const [loading, setLoading] = useState(true);
  const [bookingTableType, setBookingTableType] = useState<TableTypeWithVenue | null>(null);
  const [bookingInitialDate, setBookingInitialDate] = useState<Date | undefined>(undefined);
  const [bookingInitialSlotId, setBookingInitialSlotId] = useState<string | undefined>(undefined);
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  useEffect(() => {
    if (!id) return;
    setLoading(true);

    const loadVenue = async () => {
      // Try by slug first, then by id - same lookup pattern as EventDetail.
      let { data } = await supabase
        .from('site_venues')
        .select('*, site_table_types(*), site_venue_time_slots(*), site_venue_floors(*)')
        .eq('slug', id)
        .eq('status', 'published')
        .maybeSingle();

      if (!data) {
        ({ data } = await supabase
          .from('site_venues')
          .select('*, site_table_types(*), site_venue_time_slots(*), site_venue_floors(*)')
          .eq('id', id)
          .eq('status', 'published')
          .maybeSingle());
      }

      setVenue(data as VenueWithNested | null);
      setLoading(false);
    };

    loadVenue();
  }, [id]);

  if (loading) {
    return (
      <div className="min-h-screen bg-black">
        <Header />
        <div className="flex h-[60vh] items-center justify-center text-gray-400">Loading venue...</div>
        <Footer />
      </div>
    );
  }

  if (!venue) {
    return (
      <div className="min-h-screen bg-black">
        <Header />
        <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 px-4 text-center">
          <h1 className="text-2xl font-bold text-white">Venue not found</h1>
          <p className="text-gray-400">This venue may have been removed or isn't published yet.</p>
          <Button asChild className="bg-gradient-orange text-black font-bold hover:opacity-90">
            <Link to="/vip-tables">Back to VIP Tables</Link>
          </Button>
        </div>
        <Footer />
      </div>
    );
  }

  const tableTypes = venue.site_table_types.slice().sort((a, b) => a.sort_order - b.sort_order);
  const hasFloorPlan = tableTypes.some((t) => t.floor_id && t.pos_x !== null);

  const toBookingTableType = (tableType: TableTypeRow): TableTypeWithVenue => ({
    ...tableType,
    venue,
    timeSlots: venue.site_venue_time_slots,
  });

  const openBooking = (tableType: TableTypeRow, initialDate?: Date, initialSlotId?: string) => {
    setBookingInitialDate(initialDate);
    setBookingInitialSlotId(initialSlotId);
    setBookingTableType(toBookingTableType(tableType));
  };

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="relative">
        <div className="relative h-[45vh] min-h-[320px] w-full overflow-hidden lg:h-[55vh]">
          <img
            src={venue.cover_image_url ?? '/placeholder.svg'}
            alt={venue.name}
            className="h-full w-full object-cover"
          />
          <div className="absolute inset-0 bg-gradient-to-t from-black via-black/60 to-black/10" />
        </div>

        <div className="container relative mx-auto -mt-24 px-4 pb-4 lg:px-6">
          <Link
            to="/vip-tables"
            className="mb-4 inline-flex items-center gap-2 text-sm text-gray-300 transition-colors hover:text-primary"
          >
            <ArrowLeft className="h-4 w-4" />
            Back to VIP Tables
          </Link>

          <h1 className="text-3xl font-bold text-white lg:text-5xl">{venue.name}</h1>

          {venue.address && (
            <div className="mt-4 flex items-center gap-2 text-gray-300">
              <MapPin className="h-4 w-4 text-primary" />
              <span>{venue.address}</span>
            </div>
          )}
        </div>
      </section>

      <section className="container mx-auto px-4 py-10 lg:px-6">
        <div className={`grid gap-10 ${hasFloorPlan ? '' : 'lg:grid-cols-3'}`}>
          <div className={hasFloorPlan ? 'space-y-8' : 'space-y-8 lg:col-span-2'}>
            {venue.description && (
              <div>
                <h2 className="mb-3 text-xl font-semibold text-white">About this venue</h2>
                <p className="whitespace-pre-line leading-relaxed text-gray-400">{venue.description}</p>
              </div>
            )}

            {venue.gallery && venue.gallery.length > 0 && (
              <div>
                <h2 className="mb-3 text-xl font-semibold text-white">Gallery</h2>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                  {venue.gallery.map((url, i) => (
                    <button
                      key={url}
                      type="button"
                      onClick={() => setLightboxIndex(i)}
                      className="aspect-square overflow-hidden rounded-lg"
                    >
                      <img
                        src={url}
                        alt={venue.name}
                        className="h-full w-full object-cover transition-transform hover:scale-105"
                      />
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>

          {!hasFloorPlan && (
            <div>
              <Card className="sticky top-24 border-border bg-card">
                <CardContent className="space-y-4 p-6">
                  <div className="flex items-center gap-2 text-white">
                    <Crown className="h-5 w-5 text-primary" />
                    <span className="font-semibold">Table Options</span>
                  </div>

                  {tableTypes.length === 0 ? (
                    <p className="text-sm text-muted-foreground">Table bookings open soon - check back shortly.</p>
                  ) : (
                    <div className="space-y-3">
                      {tableTypes.map((tableType) => {
                        const noSlots = venue.site_venue_time_slots.length === 0;
                        return (
                          <div key={tableType.id} className="rounded-lg border border-border p-3">
                            <div className="mb-2 flex items-start justify-between gap-2">
                              <Link to={`/tables/${tableType.id}`} className="text-sm font-medium text-white hover:text-primary">
                                {tableType.name}
                              </Link>
                              {tableType.badge_label && (
                                <span
                                  className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide ${
                                    tableType.is_featured ? 'bg-gradient-orange text-black' : 'bg-black/70 text-white'
                                  }`}
                                >
                                  {tableType.badge_label}
                                </span>
                              )}
                            </div>
                            <div className="mb-3 space-y-1 text-xs text-muted-foreground">
                              <div className="flex items-center gap-1.5">
                                <Users className="h-3.5 w-3.5 text-primary" />
                                <span>Up to {tableType.max_guests} guests</span>
                              </div>
                              {tableType.description && (
                                <div className="flex items-center gap-1.5">
                                  <Wine className="h-3.5 w-3.5 text-primary" />
                                  <span>{tableType.description}</span>
                                </div>
                              )}
                              <div className="flex items-center justify-between pt-1">
                                <span>Minimum Spend</span>
                                <span className="font-semibold text-white">
                                  ${(tableType.min_spend_cents / 100).toFixed(0)}
                                </span>
                              </div>
                            </div>
                            <div className="flex gap-2">
                              <Button asChild size="sm" variant="outline" className="flex-1">
                                <Link to={`/tables/${tableType.id}`}>Details</Link>
                              </Button>
                              <Button
                                size="sm"
                                className={
                                  tableType.is_featured
                                    ? 'flex-1 bg-gradient-orange text-black font-bold hover:opacity-90'
                                    : 'flex-1'
                                }
                                variant={tableType.is_featured ? 'default' : 'outline'}
                                disabled={noSlots}
                                onClick={() => openBooking(tableType)}
                              >
                                {noSlots ? 'Coming Soon' : 'Buy Table'}
                              </Button>
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </CardContent>
              </Card>
            </div>
          )}
        </div>

        {hasFloorPlan && (
          <div className="mt-10">
            <h2 className="mb-4 flex items-center gap-2 text-xl font-semibold text-white">
              <Crown className="h-5 w-5 text-primary" />
              Select Your Table
            </h2>
            <VenueFloorPlanPicker
              venue={venue}
              floors={venue.site_venue_floors}
              tableTypes={tableTypes}
              timeSlots={venue.site_venue_time_slots}
              onSelectTable={openBooking}
            />
          </div>
        )}
      </section>

      <Footer />

      <TableBookingDialog
        tableType={bookingTableType}
        open={!!bookingTableType}
        onOpenChange={(open) => !open && setBookingTableType(null)}
        initialDate={bookingInitialDate}
        initialSlotId={bookingInitialSlotId}
      />

      {lightboxIndex !== null && (
        <Lightbox
          images={venue.gallery ?? []}
          index={lightboxIndex}
          onIndexChange={setLightboxIndex}
          onClose={() => setLightboxIndex(null)}
        />
      )}
    </div>
  );
};

export default VenueDetail;
