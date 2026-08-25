import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { isSameDay, addDays } from 'date-fns';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Calendar, MapPin, Info, Search, ShieldCheck, Sparkles, Ticket, Flame } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import BookingDialog from '@/components/BookingDialog';
import type { EventWithTiers } from '@/components/PopularEvents';

const TRUST_POINTS = [
  { icon: ShieldCheck, label: 'Verified Events' },
  { icon: Ticket, label: 'Instant Tickets' },
  { icon: Sparkles, label: 'Best Nightlife in Toronto' },
];

const SELLING_FAST_OCCUPANCY = 70;

const formatPriceFrom = (tiers: EventWithTiers['ticket_tiers']) => {
  const unlocked = tiers.filter((t) => !t.requires_access_code);
  if (unlocked.length === 0) return null;
  return Math.min(...unlocked.map((t) => t.price_cents));
};

const occupancyOf = (tiers: EventWithTiers['ticket_tiers']) => {
  const capacity = tiers.reduce((sum, t) => sum + t.capacity, 0);
  if (capacity === 0) return 0;
  const sold = tiers.reduce((sum, t) => sum + t.sold_count, 0);
  return Math.round((sold / capacity) * 100);
};

const DATE_RAIL_DAYS = 7;

const Events = () => {
  const [events, setEvents] = useState<EventWithTiers[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [activeCategory, setActiveCategory] = useState<string | null>(null);
  const [selectedDate, setSelectedDate] = useState<Date | null>(null);
  const [bookingEvent, setBookingEvent] = useState<EventWithTiers | null>(null);

  useEffect(() => {
    supabase
      .from('site_events')
      .select('*, ticket_tiers:site_ticket_tiers(*)')
      .eq('status', 'published')
      .order('start_date', { ascending: true })
      .then(({ data }) => {
        setEvents((data as EventWithTiers[]) ?? []);
        setLoading(false);
      });
  }, []);

  const categories = useMemo(() => {
    const set = new Set<string>();
    events.forEach((event) => {
      (event.category ?? '')
        .split(',')
        .map((c) => c.trim())
        .filter(Boolean)
        .forEach((c) => set.add(c));
    });
    return Array.from(set);
  }, [events]);

  const dateRail = useMemo(() => {
    const days = Array.from({ length: DATE_RAIL_DAYS }, (_, i) => addDays(new Date(), i));
    return days.map((day) => ({
      date: day,
      count: events.filter((e) => isSameDay(new Date(e.start_date), day)).length,
    }));
  }, [events]);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    return events.filter((event) => {
      const eventCategories = (event.category ?? '').split(',').map((c) => c.trim());
      const matchesCategory = !activeCategory || eventCategories.includes(activeCategory);
      const matchesDate = !selectedDate || isSameDay(new Date(event.start_date), selectedDate);
      const matchesSearch =
        !term ||
        event.title.toLowerCase().includes(term) ||
        event.venue_name.toLowerCase().includes(term);
      return matchesCategory && matchesDate && matchesSearch;
    });
  }, [events, search, activeCategory, selectedDate]);

  // The first upcoming match under the current filters gets pulled out into a
  // large featured slot instead of appearing twice (once as the hero, again in
  // the grid below).
  const featuredEvent = filtered[0] ?? null;
  const remainingEvents = featuredEvent ? filtered.slice(1) : filtered;

  const heroImages = events.filter((e) => e.cover_image_url).slice(0, 4);

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="container mx-auto px-4 pb-16 pt-28 lg:px-6 lg:pt-36">
        <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-16">
          <div>
            <h1 className="mb-5 text-4xl font-bold leading-[1.05] tracking-tight text-white lg:text-6xl">
              Browse <span className="text-gradient">Events</span>
            </h1>
            <p className="mb-8 max-w-xl text-lg leading-relaxed text-gray-400">
              Find the best nightlife experiences in Toronto. From club nights to exclusive parties and more.
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
              {heroImages.map((event, i) => (
                <div
                  key={event.id}
                  className={`overflow-hidden rounded-2xl border border-white/10 bg-black/40 ${
                    i === 0 ? 'col-span-2 h-48' : 'h-32'
                  }`}
                >
                  <img src={event.cover_image_url!} alt={event.title} className="h-full w-full object-contain" />
                </div>
              ))}
            </div>
          )}
        </div>
      </section>

      <section className="container mx-auto px-4 pb-24 lg:px-6">
        <div className="mb-6 grid grid-cols-4 gap-2 sm:grid-cols-7">
          {dateRail.map(({ date, count }, i) => {
            const active = selectedDate && isSameDay(date, selectedDate);
            return (
              <button
                key={date.toISOString()}
                type="button"
                onClick={() => setSelectedDate((prev) => (prev && isSameDay(prev, date) ? null : date))}
                className={`rounded-xl border px-2 py-2 text-center transition-colors ${
                  active ? 'border-primary bg-primary/10' : 'border-gray-800 hover:border-primary/40'
                }`}
              >
                <div className="text-[10px] uppercase tracking-wide text-gray-500">
                  {date.toLocaleDateString(undefined, { weekday: 'short' })}
                </div>
                <div className="text-lg font-bold text-white">{date.getDate()}</div>
                <div className="text-[10px] text-gray-500">{i === 0 ? 'Tonight' : count > 0 ? `${count} events` : '-'}</div>
              </button>
            );
          })}
        </div>

        {categories.length > 0 && (
          <div className="mb-6 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() => setActiveCategory(null)}
              className={`rounded-full px-4 py-2 text-sm font-medium transition-colors ${
                activeCategory === null
                  ? 'bg-gradient-orange text-black'
                  : 'border border-gray-800 text-gray-300 hover:border-primary/50'
              }`}
            >
              All Events
            </button>
            {categories.map((category) => (
              <button
                key={category}
                type="button"
                onClick={() => setActiveCategory((prev) => (prev === category ? null : category))}
                className={`rounded-full px-4 py-2 text-sm font-medium transition-colors ${
                  activeCategory === category
                    ? 'bg-gradient-orange text-black'
                    : 'border border-gray-800 text-gray-300 hover:border-primary/50'
                }`}
              >
                {category}
              </button>
            ))}
          </div>
        )}

        <div className="relative mb-10 max-w-md">
          <Search className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-500" />
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search events or venues..."
            className="border-gray-800 bg-gray-950/60 pl-10"
          />
        </div>

        <div className="mb-8 flex items-baseline justify-between">
          <h2 className="text-2xl font-bold text-white">
            {activeCategory ?? 'All'} Events
            <span className="ml-2 text-base font-normal text-gray-500">({filtered.length})</span>
          </h2>
        </div>

        {loading ? (
          <div className="text-center text-gray-400">Loading...</div>
        ) : filtered.length === 0 ? (
          <div className="text-center text-gray-400">No events match that search - try a different term or category.</div>
        ) : (
          <>
            {featuredEvent && (
              <div className="mb-10 grid gap-0 overflow-hidden rounded-2xl border border-primary/30 bg-gradient-to-br from-primary/10 to-black md:grid-cols-2">
                <Link
                  to={`/events/${featuredEvent.slug || featuredEvent.id}`}
                  className="relative flex h-56 items-center justify-center bg-black/40 md:h-full"
                >
                  <img
                    src={featuredEvent.cover_image_url ?? '/placeholder.svg'}
                    alt={featuredEvent.title}
                    className="h-full w-full object-contain"
                  />
                  <span className="absolute left-3 top-3 rounded-full bg-gradient-orange px-3 py-1 text-xs font-bold uppercase text-black">
                    Featured
                  </span>
                </Link>
                <div className="p-6">
                  <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-primary">
                    {new Date(featuredEvent.start_date).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })}
                    {' · '}
                    {new Date(featuredEvent.start_date).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}
                  </div>
                  <h3 className="mb-1 text-2xl font-bold text-white">{featuredEvent.title}</h3>
                  <p className="mb-4 text-sm text-gray-400">{featuredEvent.venue_name}</p>
                  <div className="mb-4 space-y-2">
                    {featuredEvent.ticket_tiers.slice(0, 3).map((tier) => (
                      <div key={tier.id} className="flex items-center justify-between rounded-lg border border-gray-800 px-3 py-2 text-sm">
                        <span className="text-gray-300">{tier.name}</span>
                        <span className="font-semibold text-white">
                          {tier.requires_access_code ? 'Access code' : `$${(tier.price_cents / 100).toFixed(2)}`}
                        </span>
                      </div>
                    ))}
                  </div>
                  <div className="flex gap-2">
                    <Button
                      className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90"
                      disabled={featuredEvent.ticket_tiers.length === 0}
                      onClick={() => setBookingEvent(featuredEvent)}
                    >
                      Get tickets
                    </Button>
                    <Button asChild variant="outline" className="flex-1 border-gray-700">
                      <Link to={`/events/${featuredEvent.slug || featuredEvent.id}`}>Details</Link>
                    </Button>
                  </div>
                </div>
              </div>
            )}

          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            {remainingEvents.map((event) => {
              const start = new Date(event.start_date);
              const priceFromCents = formatPriceFrom(event.ticket_tiers);
              const sellingFast = occupancyOf(event.ticket_tiers) >= SELLING_FAST_OCCUPANCY;
              return (
                <Card
                  key={event.id}
                  className="overflow-hidden border-border bg-card transition-all duration-300 hover:border-primary/50"
                >
                  <Link to={`/events/${event.slug || event.id}`} className="block">
                    <div className="relative h-48 w-full bg-black/40">
                      <img
                        src={event.cover_image_url ?? '/placeholder.svg'}
                        alt={event.title}
                        className="h-full w-full object-contain"
                      />
                      <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-transparent to-transparent" />
                      <div className="absolute left-3 top-3 flex w-14 flex-col items-center rounded-2xl border border-white/10 bg-black/70 py-2 text-center backdrop-blur-xl">
                        <span className="text-[10px] font-semibold uppercase tracking-wide text-primary">
                          {start.toLocaleDateString(undefined, { month: 'short' })}
                        </span>
                        <span className="text-lg font-bold leading-none text-white">{start.getDate()}</span>
                      </div>
                      {sellingFast && (
                        <div className="absolute right-3 top-3 flex items-center gap-1 rounded-full bg-red-600 px-2.5 py-1 text-[10px] font-bold uppercase text-white shadow-lg">
                          <Flame className="h-3 w-3" />
                          Selling Fast
                        </div>
                      )}
                      {priceFromCents !== null && (
                        <div className="absolute bottom-3 right-3 rounded-full bg-gradient-orange px-3 py-1 text-sm font-bold text-black shadow-lg">
                          From ${(priceFromCents / 100).toFixed(0)}
                        </div>
                      )}
                    </div>
                  </Link>
                  <CardContent className="p-6">
                    <Link to={`/events/${event.slug || event.id}`} className="block">
                      <h3 className="mb-3 text-xl font-semibold text-white">{event.title}</h3>
                      <div className="mb-5 space-y-2 text-sm text-muted-foreground">
                        <div className="flex items-center gap-2">
                          <MapPin className="h-4 w-4 text-primary" />
                          <span>{event.venue_name}</span>
                        </div>
                        <div className="flex items-center gap-2">
                          <Calendar className="h-4 w-4 text-primary" />
                          <span>
                            {start.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })} •{' '}
                            {start.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}
                          </span>
                        </div>
                      </div>
                    </Link>
                    <div className="flex gap-2">
                      <Button asChild variant="outline" className="flex-1 border-border">
                        <Link to={`/events/${event.slug || event.id}`}>
                          <Info className="mr-1.5 h-4 w-4" />
                          Details
                        </Link>
                      </Button>
                      <Button
                        className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90"
                        disabled={event.ticket_tiers.length === 0}
                        onClick={() => setBookingEvent(event)}
                      >
                        {event.ticket_tiers.length === 0 ? 'Coming Soon' : 'Book Now'}
                      </Button>
                    </div>
                  </CardContent>
                </Card>
              );
            })}
          </div>
          </>
        )}
      </section>

      <Footer />

      <BookingDialog event={bookingEvent} open={!!bookingEvent} onOpenChange={(open) => !open && setBookingEvent(null)} />
    </div>
  );
};

export default Events;
