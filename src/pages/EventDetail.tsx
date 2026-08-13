import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Calendar, MapPin, Ticket, Crown, Share2, CheckCircle2 } from 'lucide-react';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import BookingDialog from '@/components/BookingDialog';
import Lightbox from '@/components/Lightbox';
import type { EventWithTiers } from '@/components/PopularEvents';

const EventDetail = () => {
  const { id } = useParams<{ id: string }>();
  const { toast } = useToast();
  const [event, setEvent] = useState<EventWithTiers | null>(null);
  const [relatedEvents, setRelatedEvents] = useState<EventWithTiers[]>([]);
  const [loading, setLoading] = useState(true);
  const [bookingOpen, setBookingOpen] = useState(false);
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  useEffect(() => {
    if (!id) return;
    setLoading(true);
    setLightboxIndex(null);

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

      const loaded = data as EventWithTiers | null;
      setEvent(loaded);
      setLoading(false);

      if (loaded) {
        const { data: related } = await supabase
          .from('site_events')
          .select('*, ticket_tiers:site_ticket_tiers(*)')
          .eq('status', 'published')
          .neq('id', loaded.id)
          .order('start_date', { ascending: true })
          .limit(4);
        setRelatedEvents((related as EventWithTiers[]) ?? []);
      }
    };

    loadEvent();
  }, [id]);

  const handleShare = async () => {
    const url = window.location.href;
    if (navigator.share) {
      try {
        await navigator.share({ title: event?.title, url });
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
            <Link to="/events">Back to Events</Link>
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
  const tags = (event.category ?? '')
    .split(',')
    .map((t) => t.trim())
    .filter(Boolean);
  const gallery = event.gallery ?? [];
  const start = new Date(event.start_date);

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="container mx-auto px-4 pt-24 lg:px-6 lg:pt-32">
        <div className="mb-4 flex items-center justify-between">
          <Link
            to="/events"
            className="inline-flex items-center gap-2 text-sm text-gray-300 transition-colors hover:text-primary"
          >
            <ArrowLeft className="h-4 w-4" />
            Back to Events
          </Link>
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={handleShare}
            className="border-border bg-transparent text-white hover:bg-white/10"
          >
            <Share2 className="mr-1.5 h-4 w-4" />
            Share
          </Button>
        </div>

        <div className="flex items-center justify-center overflow-hidden rounded-2xl border border-border bg-black/40">
          <img
            src={event.banner_image_url ?? event.cover_image_url ?? '/placeholder.svg'}
            alt={event.title}
            className="max-h-[60vh] w-full object-contain sm:max-h-[70vh]"
          />
        </div>

        <div className="mt-6">
          <div className="mb-3 flex flex-wrap items-center gap-2">
            <span className="flex items-center gap-1 rounded-full border border-emerald-500/30 bg-emerald-950/70 px-3 py-1 text-xs font-bold uppercase tracking-wide text-emerald-400">
              <CheckCircle2 className="h-3.5 w-3.5" />
              Verified Event
            </span>
            {tags.map((tag) => (
              <span key={tag} className="rounded-full bg-primary/20 px-3 py-1 text-xs font-medium text-primary">
                {tag}
              </span>
            ))}
          </div>

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
                {start.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}{' '}
                • {start.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}
              </span>
            </div>
          </div>
        </div>
      </section>

      <section className="container mx-auto px-4 py-10 lg:px-6">
        <div className="grid gap-10 lg:grid-cols-3">
          <div className="lg:col-span-2">
            <Tabs defaultValue="overview">
              <TabsList>
                <TabsTrigger value="overview">Overview</TabsTrigger>
                {gallery.length > 0 && <TabsTrigger value="gallery">Gallery</TabsTrigger>}
              </TabsList>

              <TabsContent value="overview" className="space-y-8 pt-6">
                <div>
                  <h2 className="mb-3 text-xl font-semibold text-white">About this event</h2>
                  <p className="whitespace-pre-line leading-relaxed text-gray-400">{event.description}</p>
                </div>

                <Card className="border-border bg-card">
                  <CardContent className="flex items-center gap-4 p-6">
                    <Crown className="h-8 w-8 shrink-0 text-primary" />
                    <div className="flex-1">
                      <div className="font-semibold text-white">Want the VIP treatment?</div>
                      <p className="text-sm text-muted-foreground">
                        Reserve a table with bottle service and a dedicated host for the night.
                      </p>
                    </div>
                    <Button asChild variant="outline" className="shrink-0 border-border">
                      <Link to="/vip-tables">Browse VIP Tables</Link>
                    </Button>
                  </CardContent>
                </Card>
              </TabsContent>

              {gallery.length > 0 && (
                <TabsContent value="gallery" className="pt-6">
                  <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                    {gallery.map((url, i) => (
                      <button
                        key={url}
                        type="button"
                        onClick={() => setLightboxIndex(i)}
                        className="aspect-square overflow-hidden rounded-lg"
                      >
                        <img
                          src={url}
                          alt={event.title}
                          className="h-full w-full object-cover transition-transform hover:scale-105"
                        />
                      </button>
                    ))}
                  </div>
                </TabsContent>
              )}
            </Tabs>
          </div>

          <div>
            <Card className="sticky top-24 border-border bg-card">
              <CardContent className="space-y-4 p-6">
                <div className="flex items-center gap-2 text-white">
                  <Ticket className="h-5 w-5 text-primary" />
                  <span className="font-semibold">Select Your Experience</span>
                </div>

                {event.ticket_tiers.length === 0 ? (
                  <p className="text-sm text-muted-foreground">Ticket sales open soon - check back shortly.</p>
                ) : (
                  <div className="space-y-2">
                    {event.ticket_tiers.map((tier, i) => {
                      const remaining = tier.capacity - tier.sold_count;
                      const popular = i === Math.min(1, event.ticket_tiers.length - 1) && event.ticket_tiers.length > 1;
                      return (
                        <div
                          key={tier.id}
                          className={`relative rounded-lg border px-3 py-2 ${
                            popular ? 'border-primary bg-primary/5' : 'border-border'
                          }`}
                        >
                          {popular && (
                            <span className="absolute -top-2.5 left-3 rounded-full bg-gradient-orange px-2 py-0.5 text-[10px] font-bold uppercase text-black">
                              Popular
                            </span>
                          )}
                          <div className="flex items-center justify-between">
                            <div className="text-sm font-medium text-white">{tier.name}</div>
                            <div className="font-semibold text-white">${(tier.price_cents / 100).toFixed(2)}</div>
                          </div>
                          {event.show_ticket_count && (
                            <div className="text-xs text-muted-foreground">
                              {remaining > 0 ? `${remaining} left` : 'Sold out'}
                            </div>
                          )}
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
                      : 'View Tickets'}
                </Button>
                <p className="text-center text-xs text-muted-foreground">Secure checkout via Stripe</p>
              </CardContent>
            </Card>
          </div>
        </div>

        {relatedEvents.length > 0 && (
          <div className="mt-14">
            <h2 className="mb-6 text-xl font-semibold text-white">You Might Also Like</h2>
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              {relatedEvents.map((related) => {
                const relatedPriceFrom = related.ticket_tiers.length
                  ? Math.min(...related.ticket_tiers.map((t) => t.price_cents))
                  : null;
                return (
                  <Link
                    key={related.id}
                    to={`/events/${related.slug || related.id}`}
                    className="group overflow-hidden rounded-lg border border-border bg-card transition-colors hover:border-primary/50"
                  >
                    <div className="h-32 w-full overflow-hidden">
                      <img
                        src={related.cover_image_url ?? '/placeholder.svg'}
                        alt={related.title}
                        className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      />
                    </div>
                    <div className="p-3">
                      <div className="truncate text-sm font-medium text-white">{related.title}</div>
                      <div className="truncate text-xs text-muted-foreground">{related.venue_name}</div>
                      {relatedPriceFrom !== null && (
                        <div className="mt-1 text-xs text-primary">From ${(relatedPriceFrom / 100).toFixed(0)}</div>
                      )}
                    </div>
                  </Link>
                );
              })}
            </div>
          </div>
        )}
      </section>

      <Footer />

      <BookingDialog event={bookingOpen ? event : null} open={bookingOpen} onOpenChange={setBookingOpen} />

      {lightboxIndex !== null && (
        <Lightbox
          images={gallery}
          index={lightboxIndex}
          onIndexChange={setLightboxIndex}
          onClose={() => setLightboxIndex(null)}
        />
      )}
    </div>
  );
};

export default EventDetail;
