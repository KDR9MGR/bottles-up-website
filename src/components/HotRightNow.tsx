import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useVenueLiveStatus, type VenueStatus } from '@/hooks/useVenueLiveStatus';

const statusColor: Record<VenueStatus['status'], string> = {
  Packed: 'text-red-400',
  Busy: 'text-orange-400',
  Filling: 'text-green-400',
  'No tables': 'text-gray-500',
};

const HotRightNow = () => {
  const { venueStatuses, loading } = useVenueLiveStatus();
  const [category, setCategory] = useState<string | null>(null);

  const categories = useMemo(() => {
    const set = new Set<string>();
    venueStatuses.forEach((v) => {
      if (v.venue.category) set.add(v.venue.category);
    });
    return Array.from(set);
  }, [venueStatuses]);

  const filtered = useMemo(
    () => (category ? venueStatuses.filter((v) => v.venue.category === category) : venueStatuses),
    [venueStatuses, category],
  );

  if (!loading && venueStatuses.length === 0) return null;

  return (
    <section className="container mx-auto px-4 py-14 lg:px-6">
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-2xl font-bold text-white">Hot right now</h2>
        {categories.length > 0 && (
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() => setCategory(null)}
              className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                category === null ? 'bg-gradient-orange text-black' : 'border border-gray-800 text-gray-300 hover:border-primary/50'
              }`}
            >
              All
            </button>
            {categories.map((c) => (
              <button
                key={c}
                type="button"
                onClick={() => setCategory((prev) => (prev === c ? null : c))}
                className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                  category === c ? 'bg-gradient-orange text-black' : 'border border-gray-800 text-gray-300 hover:border-primary/50'
                }`}
              >
                {c}
              </button>
            ))}
          </div>
        )}
      </div>

      {loading ? (
        <div className="text-center text-gray-400">Loading...</div>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {filtered.slice(0, 4).map((v) => (
            <Link
              key={v.venue.id}
              to={`/venues/${v.venue.slug || v.venue.id}`}
              className="overflow-hidden rounded-xl border border-gray-800 transition-colors hover:border-primary/50"
            >
              <div className="h-28 w-full bg-gray-900">
                {v.venue.cover_image_url && (
                  <img src={v.venue.cover_image_url} alt={v.venue.name} className="h-full w-full object-cover" />
                )}
              </div>
              <div className="p-3">
                <div className={`text-xs font-semibold ${statusColor[v.status]}`}>&bull; {v.status}</div>
                <div className="truncate font-medium text-white">{v.venue.name}</div>
                <div className="text-xs text-gray-500">
                  {v.totalTables > 0 ? `${v.tablesLeft} tables left` : 'No tables configured'}
                </div>
              </div>
            </Link>
          ))}
        </div>
      )}
    </section>
  );
};

export default HotRightNow;
