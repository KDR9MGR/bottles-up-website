import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';

// Pulls real venue names only - from published venues and published events'
// venue_name field. Never hardcode venue names here that aren't backed by
// actual data, since this renders as a "trusted by" credibility strip.
const TrustedByVenues = () => {
  const [names, setNames] = useState<string[]>([]);

  useEffect(() => {
    Promise.all([
      supabase.from('site_venues').select('name').eq('status', 'published'),
      supabase.from('site_events').select('venue_name').eq('status', 'published'),
    ]).then(([venues, events]) => {
      const fromVenues = (venues.data ?? []).map((v) => v.name);
      const fromEvents = (events.data ?? []).map((e) => e.venue_name);
      const unique = Array.from(new Set([...fromVenues, ...fromEvents].filter(Boolean)));
      setNames(unique);
    });
  }, []);

  if (names.length === 0) return null;

  return (
    <section className="border-y border-white/5 bg-black py-14">
      <div className="container mx-auto px-4 lg:px-6">
        <p className="mb-8 text-center text-xs font-semibold uppercase tracking-[0.2em] text-gray-500">
          Trusted by Toronto's Top Venues
        </p>
        <div className="flex flex-wrap items-center justify-center gap-x-12 gap-y-6">
          {names.map((name) => (
            <span
              key={name}
              className="text-lg font-bold uppercase tracking-wide text-gray-500 transition-colors duration-300 hover:text-white"
            >
              {name}
            </span>
          ))}
        </div>
      </div>
    </section>
  );
};

export default TrustedByVenues;
