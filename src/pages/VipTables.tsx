import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Users, MapPin, Wine, Crown, ShieldCheck, Zap, BadgeDollarSign, Info, CheckCircle2 } from 'lucide-react';
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

const TRUST_POINTS = [
  { icon: ShieldCheck, label: 'Verified Venues' },
  { icon: Zap, label: 'Instant Confirmation' },
  { icon: BadgeDollarSign, label: 'Best Prices' },
];

type ListingCard =
  | { kind: 'tableType'; id: string; tableType: TableTypeWithVenue }
  | { kind: 'venue'; id: string; venue: VenueRow; tableCount: number; fromCents: number | null };

const VipTables = () => {
  const [cards, setCards] = useState<ListingCard[]>([]);
  const [loading, setLoading] = useState(true);
  const [bookingTableType, setBookingTableType] = useState<TableTypeWithVenue | null>(null);

  useEffect(() => {
    supabase
      .from('site_venues')
      .select('*, site_table_types(*), site_venue_time_slots(*)')
      .eq('status', 'published')
      .then(({ data }) => {
        const venues = (data as VenueWithNested[]) ?? [];
        // A venue with any positioned (floor-plan) table gets a single summary card
        // linking to its interactive floor plan, rather than one card per physical
        // table - flooding this page with a dozen near-identical cards otherwise.
        const built: ListingCard[] = venues.flatMap((venue) => {
          const sortedTypes = venue.site_table_types.slice().sort((a, b) => a.sort_order - b.sort_order);
          const hasFloorPlan = sortedTypes.some((t) => t.floor_id && t.pos_x !== null);

          if (hasFloorPlan) {
            const prices = sortedTypes
              .map((t) => (t.pricing_mode === 'hourly' ? t.hourly_rate_cents : t.deposit_cents))
              .filter((c): c is number => typeof c === 'number' && c > 0);
            return [
              {
                kind: 'venue',
                id: venue.id,
                venue,
                tableCount: sortedTypes.length,
                fromCents: prices.length > 0 ? Math.min(...prices) : null,
              },
            ];
          }

          return sortedTypes.map((tableType) => ({
            kind: 'tableType' as const,
            id: tableType.id,
            tableType: { ...tableType, venue, timeSlots: venue.site_venue_time_slots },
          }));
        });
        setCards(built);
        setLoading(false);
      });
  }, []);

  const heroImages = Array.from(
    new Map(
      cards
        .map((card) => (card.kind === 'venue' ? card.venue : card.tableType.venue))
        .filter((venue) => venue.cover_image_url)
        .map((venue) => [venue.id, venue]),
    ).values(),
  ).slice(0, 4);

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="container mx-auto px-4 pb-16 pt-28 lg:px-6 lg:pt-36">
        <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-16">
          <div>
            <h1 className="mb-5 text-4xl font-bold leading-[1.05] tracking-tight text-white lg:text-6xl">
              Browse <span className="text-gradient">VIP Tables</span>
            </h1>
            <p className="mb-8 max-w-xl text-lg leading-relaxed text-gray-400">
              Reserve the perfect table and experience Toronto nightlife like never before. Skip the line, get
              bottle service, and secure your spot for the night.
            </p>
            <div className="flex flex-wrap items-center gap-x-6 gap-y-3">
              {TRUST_POINTS.map(({ icon: Icon, label }) => (
                <div key={label} className="flex items-center gap-2 text-sm text-gray-300">
                  <Icon className="h-4 w-4 text-primary" />
                  <span>{label}</span>
                </div>
              ))}
            </div>
          </div>

          {heroImages.length > 0 && (
            <div className="grid grid-cols-2 gap-3">
              {heroImages.map((venue, i) => (
                <div
                  key={venue.id}
                  className={`overflow-hidden rounded-2xl border border-white/10 ${
                    i === 0 ? 'col-span-2 h-48' : 'h-32'
                  }`}
                >
                  <img src={venue.cover_image_url!} alt={venue.name} className="h-full w-full object-cover" />
                </div>
              ))}
            </div>
          )}
        </div>
      </section>

      <section className="container mx-auto px-4 pb-24 lg:px-6">
        <div className="mb-8">
          <h2 className="text-2xl font-bold text-white">Available Tables</h2>
          <p className="mt-1 text-sm text-gray-400">Handpicked tables at Toronto's top venues</p>
        </div>

        {loading ? (
          <div className="text-center text-gray-400">Loading...</div>
        ) : cards.length === 0 ? (
          <div className="text-center text-gray-400">No tables available right now - check back soon.</div>
        ) : (
          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            {cards.map((card) =>
              card.kind === 'venue' ? (
                <Card
                  key={card.id}
                  className="overflow-hidden border-border bg-card transition-all duration-300 hover:border-primary/50"
                >
                  <div className="relative h-52 w-full">
                    <img
                      src={card.venue.cover_image_url ?? '/placeholder.svg'}
                      alt={card.venue.name}
                      className="h-full w-full object-cover"
                    />
                    <div className="absolute inset-x-0 top-0 h-24 bg-gradient-to-b from-black/70 to-transparent" />
                    <div className="absolute left-3 top-3 rounded-full border border-white/10 bg-black/60 px-3 py-1 text-[11px] font-bold uppercase tracking-wide text-white backdrop-blur-md">
                      Interactive Floor Plan
                    </div>
                  </div>
                  <CardContent className="p-6">
                    <div className="mb-1 flex items-center gap-1.5">
                      <h3 className="text-xl font-semibold text-white">{card.venue.name}</h3>
                      <CheckCircle2 className="h-4 w-4 shrink-0 text-primary" />
                    </div>
                    {card.venue.address && (
                      <div className="mb-3 flex items-center gap-2 text-sm text-muted-foreground">
                        <MapPin className="h-4 w-4 text-primary" />
                        <span>{card.venue.address}</span>
                      </div>
                    )}
                    <div className="mb-4 space-y-1.5 text-sm text-muted-foreground">
                      <div className="flex items-center gap-2">
                        <Crown className="h-4 w-4 text-primary" />
                        <span>{card.tableCount} tables to choose from</span>
                      </div>
                      {card.fromCents !== null && (
                        <div className="flex items-center justify-between pt-1">
                          <span>Starting from</span>
                          <span className="font-semibold text-white">${(card.fromCents / 100).toFixed(0)}</span>
                        </div>
                      )}
                    </div>
                    <Button asChild className="w-full bg-gradient-orange text-black font-bold hover:opacity-90">
                      <Link to={`/venues/${card.venue.slug || card.venue.id}`}>
                        <Info className="mr-1.5 h-4 w-4" />
                        View Tables &amp; Book
                      </Link>
                    </Button>
                  </CardContent>
                </Card>
              ) : (
                <Card
                  key={card.id}
                  className={`overflow-hidden bg-card transition-all duration-300 ${
                    card.tableType.is_featured
                      ? 'border-2 border-primary shadow-[0_0_30px_-10px_hsl(var(--primary))]'
                      : 'border-border hover:border-primary/50'
                  }`}
                >
                  <div className="relative h-52 w-full">
                    <img
                      src={card.tableType.image_url ?? card.tableType.venue.cover_image_url ?? '/placeholder.svg'}
                      alt={card.tableType.name}
                      className="h-full w-full object-cover"
                    />
                    <div className="absolute inset-x-0 top-0 h-24 bg-gradient-to-b from-black/70 to-transparent" />
                    {card.tableType.badge_label && (
                      <div
                        className={`absolute left-3 top-3 rounded-full px-3 py-1 text-[11px] font-bold uppercase tracking-wide backdrop-blur-md ${
                          card.tableType.is_featured
                            ? 'bg-gradient-orange text-black'
                            : 'border border-white/10 bg-black/60 text-white'
                        }`}
                      >
                        {card.tableType.badge_label}
                      </div>
                    )}
                  </div>
                  <CardContent className="p-6">
                    <h3 className="mb-1 text-xl font-semibold text-white">{card.tableType.name}</h3>
                    <div className="mb-3 flex items-center gap-1.5 text-sm text-muted-foreground">
                      <MapPin className="h-4 w-4 text-primary" />
                      <span>{card.tableType.venue.name}</span>
                      <CheckCircle2 className="h-3.5 w-3.5 shrink-0 text-primary" />
                    </div>
                    <div className="mb-4 space-y-1.5 text-sm text-muted-foreground">
                      <div className="flex items-center gap-2">
                        <Users className="h-4 w-4 text-primary" />
                        <span>Up to {card.tableType.max_guests} guests</span>
                      </div>
                      {card.tableType.description && (
                        <div className="flex items-center gap-2">
                          <Wine className="h-4 w-4 text-primary" />
                          <span>{card.tableType.description}</span>
                        </div>
                      )}
                      <div className="flex items-center justify-between pt-1">
                        <span>Minimum Spend</span>
                        <span className="font-semibold text-white">
                          ${(card.tableType.min_spend_cents / 100).toFixed(0)}
                        </span>
                      </div>
                    </div>
                    <div className="flex gap-2">
                      <Button asChild variant="outline" className="flex-1 border-border">
                        <Link to={`/venues/${card.tableType.venue.slug || card.tableType.venue.id}`}>
                          <Info className="mr-1.5 h-4 w-4" />
                          Details
                        </Link>
                      </Button>
                      <Button
                        className={
                          card.tableType.is_featured
                            ? 'flex-1 bg-gradient-orange text-black font-bold hover:opacity-90'
                            : 'flex-1'
                        }
                        variant={card.tableType.is_featured ? 'default' : 'outline'}
                        disabled={card.tableType.timeSlots.length === 0}
                        onClick={() => setBookingTableType(card.tableType)}
                      >
                        {card.tableType.timeSlots.length === 0 ? 'Coming Soon' : 'Buy Table'}
                      </Button>
                    </div>
                  </CardContent>
                </Card>
              ),
            )}
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
