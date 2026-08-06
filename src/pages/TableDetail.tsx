import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  ArrowLeft,
  MapPin,
  Users,
  Crown,
  Share2,
  CheckCircle2,
  Phone,
  Globe,
  Clock,
  Navigation,
  Mail,
  Wine,
  Eye,
  Lock,
  Armchair,
  Sparkles,
} from 'lucide-react';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import TableBookingDialog from '@/components/TableBookingDialog';
import type { TableTypeWithVenue } from '@/pages/VipTables';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];
type FloorRow = Database['public']['Tables']['site_venue_floors']['Row'];

type TableTypeWithRelations = TableTypeRow & {
  venue: VenueRow;
  floor: FloorRow | null;
};

const formatTimeSlot = (startTime: string) => {
  const [h, m] = startTime.split(':').map((v) => parseInt(v, 10));
  const period = h >= 12 ? 'PM' : 'AM';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${m.toString().padStart(2, '0')} ${period}`;
};

const DAY_ABBR = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const TableDetail = () => {
  const { id } = useParams<{ id: string }>();
  const { toast } = useToast();
  const [table, setTable] = useState<TableTypeWithRelations | null>(null);
  const [timeSlots, setTimeSlots] = useState<TimeSlotRow[]>([]);
  const [otherTables, setOtherTables] = useState<TableTypeRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [bookingOpen, setBookingOpen] = useState(false);

  useEffect(() => {
    if (!id) return;
    setLoading(true);

    const load = async () => {
      const { data } = await supabase
        .from('site_table_types')
        .select('*, venue:site_venues!inner(*), floor:site_venue_floors(*)')
        .eq('id', id)
        .eq('venue.status', 'published')
        .maybeSingle();

      const loaded = data as TableTypeWithRelations | null;
      setTable(loaded);
      setLoading(false);

      if (loaded) {
        const { data: slots } = await supabase
          .from('site_venue_time_slots')
          .select('*')
          .eq('venue_id', loaded.venue_id);
        setTimeSlots(slots ?? []);

        const { data: siblings } = await supabase
          .from('site_table_types')
          .select('*')
          .eq('venue_id', loaded.venue_id)
          .neq('id', loaded.id)
          .order('sort_order', { ascending: true })
          .limit(4);
        setOtherTables(siblings ?? []);
      }
    };

    load();
  }, [id]);

  const handleShare = async () => {
    const url = window.location.href;
    if (navigator.share) {
      try {
        await navigator.share({ title: table?.name, url });
      } catch {
        // user cancelled the native share sheet - nothing to do
      }
      return;
    }
    await navigator.clipboard.writeText(url);
    toast({ title: 'Link copied to clipboard' });
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-black">
        <Header />
        <div className="flex h-[60vh] items-center justify-center text-gray-400">Loading table...</div>
        <Footer />
      </div>
    );
  }

  if (!table) {
    return (
      <div className="min-h-screen bg-black">
        <Header />
        <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 px-4 text-center">
          <h1 className="text-2xl font-bold text-white">Table not found</h1>
          <p className="text-gray-400">This table may have been removed or isn't published yet.</p>
          <Button asChild className="bg-gradient-orange text-black font-bold hover:opacity-90">
            <Link to="/vip-tables">Back to VIP Tables</Link>
          </Button>
        </div>
        <Footer />
      </div>
    );
  }

  const isHourly = table.pricing_mode === 'hourly';
  const priceLabel = isHourly
    ? `$${((table.hourly_rate_cents ?? 0) / 100).toFixed(0)}/hr`
    : `$${(table.deposit_cents / 100).toFixed(0)} deposit`;
  const perPerson =
    table.max_guests > 0 ? Math.round(table.min_spend_cents / table.max_guests / 100) : null;
  const location = table.floor ? `${table.floor.label} - ${table.venue.name}` : table.venue.name;
  const bestTimes = timeSlots
    .slice()
    .sort((a, b) => a.day_of_week - b.day_of_week)
    .map((s) => `${DAY_ABBR[s.day_of_week]} ${formatTimeSlot(s.start_time)}`)
    .join(', ');
  const amenitiesList = (table.amenities ?? '')
    .split(',')
    .map((a) => a.trim())
    .filter(Boolean);
  const mapsUrl = table.venue.address
    ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${table.venue.name}, ${table.venue.address}`)}`
    : null;

  const bookingTableType: TableTypeWithVenue = { ...table, venue: table.venue, timeSlots };

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="container mx-auto px-4 pt-24 lg:px-6 lg:pt-32">
        <Link
          to={`/venues/${table.venue.slug || table.venue.id}`}
          className="mb-4 inline-flex items-center gap-2 text-sm text-gray-300 transition-colors hover:text-primary"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to {table.venue.name}
        </Link>

        <div className="relative overflow-hidden rounded-2xl border border-border">
          <img
            src={table.image_url ?? table.venue.cover_image_url ?? '/placeholder.svg'}
            alt={table.name}
            className="h-64 w-full object-cover lg:h-80"
          />
          <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-transparent to-transparent" />
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={handleShare}
            className="absolute right-4 top-4 border-white/20 bg-black/60 text-white backdrop-blur-md hover:bg-black/80"
          >
            <Share2 className="mr-1.5 h-4 w-4" />
            Share
          </Button>
        </div>

        <div className="mt-6">
          <div className="mb-3 flex flex-wrap items-center gap-2">
            <span className="flex items-center gap-1 rounded-full border border-emerald-500/30 bg-emerald-950/70 px-3 py-1 text-xs font-bold uppercase tracking-wide text-emerald-400">
              <CheckCircle2 className="h-3.5 w-3.5" />
              Verified Venue
            </span>
            {table.badge_label && (
              <span className="rounded-full bg-gradient-orange px-3 py-1 text-xs font-bold uppercase tracking-wide text-black">
                {table.badge_label}
              </span>
            )}
          </div>

          <h1 className="text-3xl font-bold text-white lg:text-5xl">{table.name}</h1>
          <p className="mt-2 text-lg text-gray-400">
            <Link to={`/venues/${table.venue.slug || table.venue.id}`} className="hover:text-primary">
              {table.venue.name}
            </Link>
          </p>

          <div className="mt-4 flex items-center gap-2 text-gray-300">
            <MapPin className="h-4 w-4 text-primary" />
            <span>{location}</span>
          </div>
        </div>
      </section>

      <section className="container mx-auto px-4 py-10 lg:px-6">
        <div className="grid gap-10 lg:grid-cols-3">
          <div className="space-y-8 lg:col-span-2">
            <Card className="border-border bg-card">
              <CardContent className="grid grid-cols-2 gap-4 p-6 sm:grid-cols-4">
                <div>
                  <div className="text-xs text-muted-foreground">Price</div>
                  <div className="font-semibold text-white">{priceLabel}</div>
                </div>
                <div>
                  <div className="text-xs text-muted-foreground">Guests</div>
                  <div className="font-semibold text-white">
                    {table.min_guests ? `${table.min_guests}-${table.max_guests}` : `Up to ${table.max_guests}`}
                  </div>
                </div>
                {isHourly && (
                  <div>
                    <div className="text-xs text-muted-foreground">Minimum</div>
                    <div className="font-semibold text-white">{table.min_hours ?? 1} hr</div>
                  </div>
                )}
                {bestTimes && (
                  <div className="col-span-2 sm:col-span-1">
                    <div className="text-xs text-muted-foreground">Available</div>
                    <div className="text-sm font-semibold text-white">{bestTimes}</div>
                  </div>
                )}
              </CardContent>
            </Card>

            {table.description && (
              <div>
                <h2 className="mb-3 text-xl font-semibold text-white">What's Included</h2>
                <p className="whitespace-pre-line leading-relaxed text-gray-400">{table.description}</p>
              </div>
            )}

            {(table.seating_type || table.table_view || table.privacy_level || amenitiesList.length > 0) && (
              <div>
                <h2 className="mb-3 text-xl font-semibold text-white">Table Details</h2>
                <div className="grid gap-3 sm:grid-cols-2">
                  {table.seating_type && (
                    <div className="flex items-center gap-2 text-sm text-gray-300">
                      <Armchair className="h-4 w-4 text-primary" />
                      <span>{table.seating_type}</span>
                    </div>
                  )}
                  {table.table_view && (
                    <div className="flex items-center gap-2 text-sm text-gray-300">
                      <Eye className="h-4 w-4 text-primary" />
                      <span>View: {table.table_view}</span>
                    </div>
                  )}
                  {table.privacy_level && (
                    <div className="flex items-center gap-2 text-sm text-gray-300">
                      <Lock className="h-4 w-4 text-primary" />
                      <span>{table.privacy_level}</span>
                    </div>
                  )}
                </div>
                {amenitiesList.length > 0 && (
                  <div className="mt-3 flex flex-wrap gap-2">
                    {amenitiesList.map((a) => (
                      <span key={a} className="flex items-center gap-1 rounded-full bg-primary/10 px-3 py-1 text-xs text-primary">
                        <Sparkles className="h-3 w-3" />
                        {a}
                      </span>
                    ))}
                  </div>
                )}
              </div>
            )}

            <div>
              <h2 className="mb-3 text-xl font-semibold text-white">Pricing Breakdown</h2>
              <div className="space-y-2 rounded-lg border border-border p-4 text-sm">
                <div className="flex items-center justify-between text-gray-300">
                  <span>Minimum Spend</span>
                  <span className="font-semibold text-white">${(table.min_spend_cents / 100).toFixed(0)}</span>
                </div>
                {perPerson !== null && perPerson > 0 && (
                  <div className="flex items-center justify-between text-gray-400">
                    <span>Approx. per person ({table.max_guests} guests)</span>
                    <span>${perPerson}</span>
                  </div>
                )}
                <div className="flex items-center justify-between text-gray-300">
                  <span>{isHourly ? 'Hourly Rate' : 'Deposit'}</span>
                  <span className="font-semibold text-white">{priceLabel}</span>
                </div>
              </div>
              {table.policy_note && <p className="mt-3 text-xs text-muted-foreground">{table.policy_note}</p>}
            </div>

            <Card className="border-border bg-card">
              <CardContent className="space-y-3 p-6">
                <h2 className="text-lg font-semibold text-white">Venue Info</h2>
                {table.venue.address && (
                  <div className="flex items-center gap-2 text-sm text-gray-300">
                    <MapPin className="h-4 w-4 shrink-0 text-primary" />
                    <span>{table.venue.address}</span>
                  </div>
                )}
                {table.venue.hours_note && (
                  <div className="flex items-center gap-2 text-sm text-gray-300">
                    <Clock className="h-4 w-4 shrink-0 text-primary" />
                    <span>{table.venue.hours_note}</span>
                  </div>
                )}
                {table.venue.dress_code && (
                  <div className="flex items-center gap-2 text-sm text-gray-300">
                    <Users className="h-4 w-4 shrink-0 text-primary" />
                    <span>Dress code: {table.venue.dress_code}</span>
                  </div>
                )}
                <div className="flex flex-wrap gap-3 pt-1">
                  {table.venue.phone && (
                    <a href={`tel:${table.venue.phone}`} className="flex items-center gap-1.5 text-sm text-primary hover:underline">
                      <Phone className="h-4 w-4" />
                      {table.venue.phone}
                    </a>
                  )}
                  {table.venue.website_url && (
                    <a
                      href={table.venue.website_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="flex items-center gap-1.5 text-sm text-primary hover:underline"
                    >
                      <Globe className="h-4 w-4" />
                      Website
                    </a>
                  )}
                  {mapsUrl && (
                    <a href={mapsUrl} target="_blank" rel="noopener noreferrer" className="flex items-center gap-1.5 text-sm text-primary hover:underline">
                      <Navigation className="h-4 w-4" />
                      Get Directions
                    </a>
                  )}
                  <a href="mailto:hello@bottlesupapp.com" className="flex items-center gap-1.5 text-sm text-primary hover:underline">
                    <Mail className="h-4 w-4" />
                    Support
                  </a>
                </div>
              </CardContent>
            </Card>

            {otherTables.length > 0 && (
              <div>
                <h2 className="mb-4 text-xl font-semibold text-white">Other Tables at {table.venue.name}</h2>
                <div className="grid gap-4 sm:grid-cols-2">
                  {otherTables.map((other) => (
                    <Link
                      key={other.id}
                      to={`/tables/${other.id}`}
                      className="group overflow-hidden rounded-lg border border-border bg-card transition-colors hover:border-primary/50"
                    >
                      <div className="h-28 w-full overflow-hidden">
                        <img
                          src={other.image_url ?? table.venue.cover_image_url ?? '/placeholder.svg'}
                          alt={other.name}
                          className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                        />
                      </div>
                      <div className="p-3">
                        <div className="truncate text-sm font-medium text-white">{other.name}</div>
                        <div className="text-xs text-muted-foreground">Up to {other.max_guests} guests</div>
                      </div>
                    </Link>
                  ))}
                </div>
              </div>
            )}
          </div>

          <div>
            <Card className="sticky top-24 border-border bg-card">
              <CardContent className="space-y-4 p-6">
                <div className="flex items-center gap-2 text-white">
                  <Crown className="h-5 w-5 text-primary" />
                  <span className="font-semibold">Reserve This Table</span>
                </div>
                <div className="space-y-1.5 text-sm text-muted-foreground">
                  <div className="flex items-center gap-2">
                    <Users className="h-4 w-4 text-primary" />
                    <span>
                      {table.min_guests ? `${table.min_guests}-${table.max_guests}` : `Up to ${table.max_guests}`} guests
                    </span>
                  </div>
                  {table.description && (
                    <div className="flex items-center gap-2">
                      <Wine className="h-4 w-4 text-primary" />
                      <span className="line-clamp-2">{table.description}</span>
                    </div>
                  )}
                </div>
                <div className="text-lg font-semibold text-white">{priceLabel}</div>
                <Button
                  className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
                  disabled={timeSlots.length === 0}
                  onClick={() => setBookingOpen(true)}
                >
                  {timeSlots.length === 0 ? 'Coming Soon' : 'Reserve This Table'}
                </Button>
                <p className="text-center text-xs text-muted-foreground">Secure checkout via Stripe</p>
              </CardContent>
            </Card>
          </div>
        </div>
      </section>

      <Footer />

      <TableBookingDialog tableType={bookingOpen ? bookingTableType : null} open={bookingOpen} onOpenChange={setBookingOpen} />
    </div>
  );
};

export default TableDetail;
