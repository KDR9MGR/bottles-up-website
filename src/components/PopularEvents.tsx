import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Calendar, MapPin, Info } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import BookingDialog from './BookingDialog';

type EventRow = Database['public']['Tables']['site_events']['Row'];
type TierRow = Database['public']['Tables']['site_ticket_tiers']['Row'];
export type EventWithTiers = EventRow & { ticket_tiers: TierRow[] };

const formatPriceFrom = (tiers: TierRow[]) => {
  if (tiers.length === 0) return null;
  const min = Math.min(...tiers.map((t) => t.price_cents));
  return `$${(min / 100).toFixed(0)}`;
};

const PopularEvents = () => {
  const [events, setEvents] = useState<EventWithTiers[]>([]);
  const [loading, setLoading] = useState(true);
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

  if (!loading && events.length === 0) {
    return null;
  }

  return (
    <section id="events" className="relative bg-black py-20 lg:py-28">
      <div className="container mx-auto px-4 lg:px-6">
        <div className="mx-auto mb-14 max-w-3xl text-center">
          <span className="mb-4 inline-block text-xs font-semibold uppercase tracking-[0.2em] text-orange-500">
            Trending Events
          </span>
          <h2 className="mb-6 text-4xl font-bold text-white lg:text-5xl">
            What's <span className="text-gradient">Hot Right Now</span>
          </h2>
          <p className="text-lg text-gray-400 lg:text-xl">
            Don't miss out on the hottest events in your city. Book now before they sell out!
          </p>
        </div>

        <div className="mb-4 grid gap-6 md:grid-cols-2 lg:grid-cols-3 lg:gap-8">
          {events.map((event, index) => {
            const start = new Date(event.start_date);
            return (
              <Card
                key={event.id}
                className="group animate-fade-in hover-lift overflow-hidden rounded-3xl border-white/10 bg-white/[0.03] backdrop-blur-xl transition-all duration-300 hover:border-orange-500/40"
                style={{ animationDelay: `${index * 0.1}s` }}
              >
                <div className="relative">
                  <img
                    src={event.cover_image_url ?? '/placeholder.svg'}
                    alt={event.title}
                    className="h-52 w-full object-cover transition-transform duration-500 group-hover:scale-105"
                  />
                  <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-transparent to-transparent" />

                  <div className="absolute left-3 top-3 flex w-14 flex-col items-center rounded-2xl border border-white/10 bg-black/70 py-2 text-center backdrop-blur-xl">
                    <span className="text-[10px] font-semibold uppercase tracking-wide text-orange-500">
                      {start.toLocaleDateString(undefined, { month: 'short' })}
                    </span>
                    <span className="text-lg font-bold leading-none text-white">{start.getDate()}</span>
                  </div>

                  {formatPriceFrom(event.ticket_tiers) && (
                    <div className="absolute bottom-3 right-3 rounded-full bg-gradient-orange px-3 py-1 text-sm font-bold text-black shadow-lg">
                      From {formatPriceFrom(event.ticket_tiers)}
                    </div>
                  )}
                </div>

                <CardContent className="p-6">
                  <h3 className="mb-3 text-xl font-semibold text-white transition-colors group-hover:text-orange-500">
                    {event.title}
                  </h3>

                  <div className="mb-5 space-y-2 text-sm text-gray-400">
                    <div className="flex items-center gap-2">
                      <MapPin className="h-4 w-4 text-orange-500" />
                      <span>{event.venue_name}</span>
                    </div>
                    <div className="flex items-center gap-2">
                      <Calendar className="h-4 w-4 text-orange-500" />
                      <span>
                        {start.toLocaleDateString(undefined, {
                          weekday: 'short',
                          month: 'short',
                          day: 'numeric',
                        })}{' '}
                        •{' '}
                        {start.toLocaleTimeString(undefined, {
                          hour: 'numeric',
                          minute: '2-digit',
                        })}
                      </span>
                    </div>
                  </div>

                  <div className="flex gap-2">
                    <Button asChild variant="outline" className="flex-1 rounded-full border-white/15 bg-white/5">
                      <Link to={`/events/${event.slug || event.id}`}>
                        <Info className="mr-1.5 h-4 w-4" />
                        Details
                      </Link>
                    </Button>
                    <Button
                      className="flex-1 rounded-full bg-gradient-orange border-0 font-bold text-black transition-all duration-300 hover:scale-105"
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
      </div>

      <BookingDialog
        event={bookingEvent}
        open={!!bookingEvent}
        onOpenChange={(open) => !open && setBookingEvent(null)}
      />
    </section>
  );
};

export default PopularEvents;
