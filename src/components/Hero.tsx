import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { MapPin, Radio } from 'lucide-react';
import { useSiteContent } from '@/hooks/useSiteContent';
import { useVenueLiveStatus, type VenueStatus } from '@/hooks/useVenueLiveStatus';

const statusColor: Record<VenueStatus['status'], string> = {
  Packed: 'text-red-400',
  Busy: 'text-orange-400',
  Filling: 'text-green-400',
  'No tables': 'text-gray-500',
};

const Hero = () => {
  const content = useSiteContent();
  const navigate = useNavigate();
  const { venueStatuses } = useVenueLiveStatus();
  const [city, setCity] = useState('Toronto');
  const [partySize, setPartySize] = useState('2');

  const topVenues = venueStatuses.slice(0, 3);

  const handleFindTable = (e: React.FormEvent) => {
    e.preventDefault();
    navigate('/vip-tables');
  };

  return (
    <section className="relative overflow-hidden bg-black pb-20 pt-32 lg:pb-28 lg:pt-40">
      <div className="pointer-events-none absolute inset-0">
        <div className="absolute -left-40 top-0 h-[32rem] w-[32rem] rounded-full bg-orange-600/10 blur-[120px]" />
        <div className="absolute -right-32 top-1/3 h-[28rem] w-[28rem] rounded-full bg-orange-500/10 blur-[120px]" />
        <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_top,_rgba(255,255,255,0.04),_transparent_60%)]" />
      </div>

      <div className="container relative mx-auto px-4 lg:px-6">
        <div className="grid items-center gap-14 lg:grid-cols-2 lg:gap-16">
          <div className="animate-fade-in-up">
            <div className="mb-7 inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-4 py-2 backdrop-blur-xl">
              <Radio className="h-3.5 w-3.5 text-orange-500" />
              <span className="text-xs font-semibold uppercase tracking-wide text-orange-500">Live tonight in Toronto</span>
            </div>

            <h1 className="mb-6 text-5xl font-bold leading-[1.05] tracking-tight text-white lg:text-7xl">
              {content.hero_headline || (
                <>
                  Toronto's #1
                  <span className="block mt-2 text-gradient">Nightlife App</span>
                </>
              )}
            </h1>

            <p className="mb-4 text-xl font-semibold text-orange-500 lg:text-2xl">
              VIP Bookings &middot; Digital Tickets &middot; Exclusive Access
            </p>

            <p className="mb-8 max-w-xl text-lg leading-relaxed text-gray-400">
              {content.hero_subtext ||
                "Skip the lines, secure your table, and experience Toronto's hottest venues with BottlesUp."}
            </p>

            <form
              onSubmit={handleFindTable}
              className="mb-6 flex flex-col gap-3 rounded-2xl border border-white/10 bg-white/5 p-3 backdrop-blur-xl sm:flex-row sm:items-center"
            >
              <div className="flex-1 px-2">
                <div className="text-[10px] font-semibold uppercase tracking-wide text-gray-500">City</div>
                <Input
                  value={city}
                  onChange={(e) => setCity(e.target.value)}
                  className="h-7 border-0 bg-transparent p-0 text-sm text-white focus-visible:ring-0"
                />
              </div>
              <div className="h-8 w-px bg-white/10 sm:block hidden" />
              <div className="flex-1 px-2">
                <div className="text-[10px] font-semibold uppercase tracking-wide text-gray-500">Party</div>
                <Input
                  value={partySize}
                  onChange={(e) => setPartySize(e.target.value)}
                  className="h-7 border-0 bg-transparent p-0 text-sm text-white focus-visible:ring-0"
                />
              </div>
              <Button type="submit" className="h-11 rounded-xl bg-gradient-orange px-6 font-bold text-black hover:opacity-90">
                Find a table
              </Button>
            </form>

            <p className="text-xs text-gray-500">No cover fees &middot; Instant confirmation &middot; 19+ with valid ID</p>
          </div>

          <div className="animate-fade-in relative">
            <div className="overflow-hidden rounded-2xl border border-white/10 bg-gray-950">
              <div className="flex items-center justify-between border-b border-white/10 px-4 py-3">
                <span className="flex items-center gap-1.5 text-xs font-semibold text-white">
                  <MapPin className="h-3.5 w-3.5 text-orange-500" />
                  Hot right now
                </span>
              </div>
              {topVenues.length === 0 ? (
                <div className="p-6 text-center text-sm text-gray-500">Venues coming soon.</div>
              ) : (
                <div className="divide-y divide-white/5">
                  {topVenues.map((v) => (
                    <div key={v.venue.id} className="flex items-center gap-3 p-4">
                      <div className="h-12 w-12 shrink-0 overflow-hidden rounded-lg bg-gray-900">
                        {v.venue.cover_image_url && (
                          <img src={v.venue.cover_image_url} alt={v.venue.name} className="h-full w-full object-cover" />
                        )}
                      </div>
                      <div className="min-w-0 flex-1">
                        <div className="truncate font-medium text-white">{v.venue.name}</div>
                        <div className={`text-xs font-medium ${statusColor[v.status]}`}>&bull; {v.status}</div>
                      </div>
                      <div className="shrink-0 text-xs text-gray-500">
                        {v.totalTables > 0 ? `${v.tablesLeft} left` : '-'}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};

export default Hero;
