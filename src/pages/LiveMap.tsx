import { Link } from 'react-router-dom';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Button } from '@/components/ui/button';
import { MapPin, Radio } from 'lucide-react';
import { useVenueLiveStatus, type VenueStatus } from '@/hooks/useVenueLiveStatus';

const statusColor: Record<VenueStatus['status'], string> = {
  Packed: 'bg-red-500',
  Busy: 'bg-orange-500',
  Filling: 'bg-green-500',
  'No tables': 'bg-gray-600',
};

const LiveMap = () => {
  const { venueStatuses, loading } = useVenueLiveStatus();

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="container mx-auto px-4 pb-16 pt-28 lg:px-6 lg:pt-36">
        <div className="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-primary">
          <Radio className="h-3.5 w-3.5" />
          Live &middot; updates when you reload
        </div>
        <h1 className="mb-3 text-4xl font-bold text-white lg:text-5xl">Where's busy right now?</h1>
        <p className="max-w-xl text-gray-400">
          Table-booking demand for tonight at every venue on BottlesUp - not a crowd counter, just how fast tables
          are filling up.
        </p>
      </section>

      <section className="container mx-auto px-4 pb-24 lg:px-6">
        <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
          {/* Abstract illustrative map - no real geo/maps API configured, so this
              is a stylized grid rather than actual map tiles. */}
          <div className="relative hidden h-[500px] overflow-hidden rounded-2xl border border-gray-800 bg-gray-950 lg:block">
            <div
              className="absolute inset-0 opacity-30"
              style={{
                backgroundImage:
                  'linear-gradient(rgba(255,255,255,0.06) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.06) 1px, transparent 1px)',
                backgroundSize: '40px 40px',
              }}
            />
            {venueStatuses.slice(0, 8).map((v, i) => {
              // Deterministic pseudo-scatter so pins don't overlap identically each render.
              const left = 15 + ((i * 37) % 70);
              const top = 15 + ((i * 53) % 70);
              return (
                <div
                  key={v.venue.id}
                  className="absolute flex -translate-x-1/2 -translate-y-1/2 items-center gap-1.5 rounded-full border border-gray-700 bg-black/80 px-2.5 py-1 text-xs text-white shadow-lg"
                  style={{ left: `${left}%`, top: `${top}%` }}
                >
                  <span className={`h-2 w-2 rounded-full ${statusColor[v.status]}`} />
                  {v.venue.name}
                </div>
              );
            })}
          </div>

          <div className="space-y-3">
            <div className="flex items-baseline justify-between">
              <h2 className="text-lg font-semibold text-white">Live venues</h2>
              <span className="text-xs text-gray-500">Sorted by demand</span>
            </div>

            {loading ? (
              <div className="text-center text-gray-400">Loading...</div>
            ) : venueStatuses.length === 0 ? (
              <div className="text-center text-gray-500">No published venues yet.</div>
            ) : (
              venueStatuses.map((v) => (
                <div key={v.venue.id} className="flex items-center gap-3 rounded-xl border border-gray-800 p-3">
                  <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-lg bg-gray-900 text-gray-600">
                    <MapPin className="h-5 w-5" />
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-1.5">
                      <span className={`h-1.5 w-1.5 rounded-full ${statusColor[v.status]}`} />
                      <span className="text-xs font-medium text-gray-400">{v.status}</span>
                    </div>
                    <div className="truncate font-medium text-white">{v.venue.name}</div>
                    <div className="text-xs text-gray-500">
                      {v.totalTables > 0 ? `${v.tablesLeft} tables left` : 'No tables configured'}
                    </div>
                  </div>
                  <Button asChild size="sm" className="shrink-0 bg-gradient-orange text-black font-bold hover:opacity-90">
                    <Link to={`/venues/${v.venue.slug || v.venue.id}`}>Book</Link>
                  </Button>
                </div>
              ))
            )}
          </div>
        </div>
      </section>

      <Footer />
    </div>
  );
};

export default LiveMap;
