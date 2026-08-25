import { Radio, MapPin, Calendar } from 'lucide-react';

const PHONE_SCREENS = [
  { label: 'Tonight', icon: Radio, lines: ['Rebel · Packed', 'Toybox · 12 tables', 'Coda · 40 min'] },
  { label: 'Map', icon: MapPin, lines: ['Map · nearby', 'Nearest · 400 m', 'Filter · tables'] },
  { label: 'Bookings', icon: Calendar, lines: ['Toybox · Sat 11 PM', 'Ticket · Sound Off', 'Past · Coda'] },
];

const AppDownloadTeaser = () => {
  return (
    <section className="container mx-auto px-4 py-14 lg:px-6">
      <div className="grid items-center gap-10 lg:grid-cols-2">
        <div>
          <h2 className="mb-3 text-2xl font-bold text-white lg:text-3xl">The whole night, in your pocket</h2>
          <p className="mb-6 max-w-md text-gray-400">
            Live capacity, table bookings and your tickets - one app.
          </p>
          <div className="flex flex-wrap gap-3">
            <span className="rounded-lg border border-gray-700 px-4 py-2 text-sm font-medium text-gray-300">
              App Store &middot; Coming soon
            </span>
            <span className="rounded-lg border border-gray-700 px-4 py-2 text-sm font-medium text-gray-300">
              Google Play &middot; Coming soon
            </span>
          </div>
        </div>

        <div className="flex justify-center gap-4">
          {PHONE_SCREENS.map(({ label, icon: Icon, lines }) => (
            <div key={label} className="w-full max-w-[140px] overflow-hidden rounded-2xl border border-gray-800 bg-gray-950">
              <div className="flex items-center justify-between border-b border-gray-800 px-3 py-2">
                <span className="text-xs font-semibold text-white">{label}</span>
                <Icon className="h-3.5 w-3.5 text-primary" />
              </div>
              <div className="space-y-2 p-3">
                {lines.map((line, i) => (
                  <div key={i} className="rounded-md bg-gray-900 px-2 py-3 text-[10px] text-gray-500">
                    {line}
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
};

export default AppDownloadTeaser;
