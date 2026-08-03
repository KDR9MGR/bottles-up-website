import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import { Input } from '@/components/ui/input';
import { ShieldCheck, Zap, MapPinned, MapPin, Search, CheckCircle2, Crown } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];

type VenueWithTables = VenueRow & { site_table_types: TableTypeRow[] };

const CATEGORIES = ['Nightclub', 'Rooftop', 'Lounge', 'Restaurant', 'Beach Club', 'Patio'];

const TRUST_POINTS = [
  { icon: ShieldCheck, label: 'Verified Venues' },
  { icon: Zap, label: 'Live Availability' },
  { icon: MapPinned, label: 'Premium Locations' },
];

const Venues = () => {
  const [venues, setVenues] = useState<VenueWithTables[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [activeCategory, setActiveCategory] = useState<string | null>(null);

  useEffect(() => {
    supabase
      .from('site_venues')
      .select('*, site_table_types(*)')
      .eq('status', 'published')
      .then(({ data }) => {
        setVenues((data as VenueWithTables[]) ?? []);
        setLoading(false);
      });
  }, []);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    return venues.filter((venue) => {
      const matchesCategory = !activeCategory || venue.category === activeCategory;
      const matchesSearch =
        !term ||
        venue.name.toLowerCase().includes(term) ||
        (venue.address ?? '').toLowerCase().includes(term);
      return matchesCategory && matchesSearch;
    });
  }, [venues, search, activeCategory]);

  const heroImages = venues.filter((v) => v.cover_image_url).slice(0, 4);

  return (
    <div className="min-h-screen bg-black">
      <Header />

      <section className="container mx-auto px-4 pb-16 pt-28 lg:px-6 lg:pt-36">
        <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-16">
          <div>
            <h1 className="mb-5 text-4xl font-bold leading-[1.05] tracking-tight text-white lg:text-6xl">
              Browse <span className="text-gradient">Venues</span>
            </h1>
            <p className="mb-8 max-w-xl text-lg leading-relaxed text-gray-400">
              Explore Toronto's best venues. Find the perfect vibe for your night out.
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

      <section className="container mx-auto px-4 pb-8 lg:px-6">
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
            All Venues
          </button>
          {CATEGORIES.map((category) => (
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

        <div className="relative mb-10 max-w-md">
          <Search className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-500" />
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search venues or neighborhoods..."
            className="border-gray-800 bg-gray-950/60 pl-10"
          />
        </div>

        <div className="mb-8 flex items-baseline justify-between">
          <h2 className="text-2xl font-bold text-white">
            {activeCategory ?? 'All'} Venues
            <span className="ml-2 text-base font-normal text-gray-500">({filtered.length})</span>
          </h2>
        </div>

        {loading ? (
          <div className="text-center text-gray-400">Loading...</div>
        ) : filtered.length === 0 ? (
          <div className="text-center text-gray-400">No venues match that search - try a different term or category.</div>
        ) : (
          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            {filtered.map((venue) => {
              const hasTables = venue.site_table_types.some((t) => t.inventory_count > 0);
              return (
                <Link
                  key={venue.id}
                  to={`/venues/${venue.slug || venue.id}`}
                  className="group overflow-hidden rounded-xl border border-border bg-card transition-all duration-300 hover:border-primary/50"
                >
                  <div className="relative h-52 w-full overflow-hidden">
                    <img
                      src={venue.cover_image_url ?? '/placeholder.svg'}
                      alt={venue.name}
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                    />
                    <div className="absolute inset-x-0 top-0 h-24 bg-gradient-to-b from-black/70 to-transparent" />
                    <div className="absolute left-3 top-3 flex items-center gap-1 rounded-full border border-emerald-500/30 bg-emerald-950/70 px-3 py-1 text-[11px] font-bold uppercase tracking-wide text-emerald-400 backdrop-blur-md">
                      <CheckCircle2 className="h-3 w-3" />
                      Verified
                    </div>
                  </div>
                  <div className="p-6">
                    <h3 className="mb-1 text-xl font-semibold text-white">{venue.name}</h3>
                    {venue.category && <p className="mb-2 text-xs uppercase tracking-wide text-primary">{venue.category}</p>}
                    {venue.address && (
                      <div className="mb-3 flex items-center gap-2 text-sm text-muted-foreground">
                        <MapPin className="h-4 w-4 shrink-0 text-primary" />
                        <span className="truncate">{venue.address}</span>
                      </div>
                    )}
                    {hasTables && (
                      <div className="flex items-center gap-2 text-sm text-emerald-400">
                        <Crown className="h-4 w-4" />
                        <span>Tables Available</span>
                      </div>
                    )}
                  </div>
                </Link>
              );
            })}
          </div>
        )}
      </section>

      <Footer />
    </div>
  );
};

export default Venues;
