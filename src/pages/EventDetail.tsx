import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Calendar, MapPin, Ticket } from 'lucide-react';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { supabase } from '@/lib/supabase';
import BookingDialog from '@/components/BookingDialog';
import type { EventWithTiers } from '@/components/PopularEvents';

const EventDetail = () => {
  const { id } = useParams<{ id: string }>();
  const [event, setEvent] = useState<EventWithTiers | null>(null);
  const [loading, setLoading] = useState(true);
  const [bookingOpen, setBookingOpen] = useState(false);

  useEffect(() => {
    if (!id) return;
    setLoading(true);
    
    // Try by slug first, then by id
    const loadEvent = async () => {
      // First try with slug
      let { data } = await supabase
        .from('site_events')
        .select('*, ticket_tiers:site_ticket_tiers(*)')
        .eq('slug', id)
        .eq('status', 'published')
        .maybeSingle();
      
      if (!data) {
        // If no event by slug, try id
        ({ data } = await supabase
          .from('site_events')
          .select('*, ticket_tiers:site_ticket_tiers(*)')
          .eq('id', id)
          .eq('status', 'published')
          .maybeSingle());
      }
      
      setEvent(data as EventWithTiers | null);
      setLoading(false);
    };
    
    loadEvent();
  }, [id]);

  if (loading) {
    return (
      <div className="min-h-screen bg-black">
        <Header />
        <div className="flex h-[60vh] items-center justify-center text-gray-400">Loading event...</div>
        <Footer />
      </div>
    );
  }

  if (!event) {
    return (
      <div className="min-h-screen bg-black">
        <Header />
        <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 px-4 text-center">
          <h1 className="text-2xl font-bold text-white">Event not found</h1>
          <p className="text-gray-400">This event may have been removed or isn't published yet.</p>
          <Button asChild className="bg-gradient-orange text-black font-bold hover:opacity-90">
            <Link to="/#events">Back to Events</Link>
          </Button>
        </div>
        <Footer />
      </div>
    );
  }

  const priceFrom = event.ticket_tiers.length
    ? Math.min(...event.ticket_tiers.map((t) => t.price_cents))
    : null;
  const soldOut =
    event.ticket_tiers.length > 0 && event.ticket_tiers.every((t) => t.sold_count >= t.capacity);

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="relative">
        <div className="relative h-[45vh] min-h-[320px] w-full overflow-hidden lg:h-[55vh]">
          <img
            src={event.banner_image_url ?? event.cover_image_url ?? '/placeholder.svg'}
            alt={event.title}
            className="h-full w-full object-cover"
          />
          <div className="absolute inset-0 bg-gradient-to-t from-black via-black/60 to-black/10" />
        </div>

        <div className="container relative mx-auto -mt-24 px-4 pb-4 lg:px-6">
          <Link
            to="/#events"
            className="mb-4 inline-flex items-center gap-2 text-sm text-gray-300 transition-colors hover:text-primary"
          >
            <ArrowLeft className="h-4 w-4" />
            Back to Events
          </Link>

          {event.category && (
            <span className="mb-3 inline-block rounded-full bg-primary/20 px-3 py-1 text-xs font-medium text-primary">
              {event.category}
            </span>
          )}

          <h1 className="text-3xl font-bold text-white lg:text-5xl">{event.title}</h1>

          <div className="mt-4 flex flex-wrap items-center gap-x-6 gap-y-2 text-gray-300">
            <div className="flex items-center gap-2">
              <MapPin className="h-4 w-4 text-primary" />
              <span>
                {event.venue_name}
                {event.address ? `, ${event.address}` : ''}
              </span>
            </div>
            <div className="flex items-center gap-2">
              <Calendar className="h-4 w-4 text-primary" />
              <span>
                {new Date(event.start_date).toLocaleDateString(undefined, {
                  weekday: 'long',
                  month: 'long',
                  day: 'numeric',
                  year: 'numeric',
                })}{' '}
                •{' '}
                {new Date(event.start_date).toLocaleTimeString(undefined, {
                  hour: 'numeric',
                  minute: '2-digit',
                })}
              </span>
            </div>
          </div>
        </div>
      </section>

      <section className="container mx-auto px-4 py-10 lg:px-6">
        <div className="grid gap-10 lg:grid-cols-3">
          <div className="space-y-8 lg:col-span-2">
            <div>
              <h2 className="mb-3 text-xl font-semibold text-white">About this event</h2>
              <p className="whitespace-pre-line leading-relaxed text-gray-400">{event.description}</p>
            </div>

            {event.gallery && event.gallery.length > 0 && (
              <div>
                <h2 className="mb-3 text-xl font-semibold text-white">Gallery</h2>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                  {event.gallery.map((url) => (
                    <img
                      key={url}
                      src={url}
                      alt={event.title}
                      className="aspect-square w-full rounded-lg object-cover"
                    />
                  ))}
                </div>
              </div>
            )}
          </div>

          <div>
            <Card className="sticky top-24 border-border bg-card">
              <CardContent className="space-y-4 p-6">
                <div className="flex items-center gap-2 text-white">
                  <Ticket className="h-5 w-5 text-primary" />
                  <span className="font-semibold">Tickets</span>
                </div>

                {event.ticket_tiers.length === 0 ? (
                  <p className="text-sm text-muted-foreground">Ticket sales open soon - check back shortly.</p>
                ) : (
                  <div className="space-y-2">
                    {event.ticket_tiers.map((tier) => {
                      const remaining = tier.capacity - tier.sold_count;
                      return (
                        <div
                          key={tier.id}
                          className="flex items-center justify-between rounded-lg border border-border px-3 py-2"
                        >
                          <div>
                            <div className="text-sm font-medium text-white">{tier.name}</div>
                            <div className="text-xs text-muted-foreground">
                              {remaining > 0 ? `${remaining} left` : 'Sold out'}
                            </div>
                          </div>
                          <div className="font-semibold text-white">${(tier.price_cents / 100).toFixed(2)}</div>
                        </div>
                      );
                    })}
                  </div>
                )}

                {priceFrom !== null && (
                  <div className="text-sm text-muted-foreground">
                    Starting from <span className="font-semibold text-white">${(priceFrom / 100).toFixed(0)}</span>
                  </div>
                )}

                <Button
                  className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
                  disabled={event.ticket_tiers.length === 0 || soldOut}
                  onClick={() => setBookingOpen(true)}
                >
                  {soldOut
                    ? 'Sold Out'
                    : event.ticket_tiers.length === 0
                      ? 'Tickets Coming Soon'
                      : 'Book Now'}
                </Button>
              </CardContent>
            </Card>
          </div>
        </div>
      </section>

      <Footer />

      <BookingDialog event={bookingOpen ? event : null} open={bookingOpen} onOpenChange={setBookingOpen} />
    </div>
  );
};

export default EventDetail;
