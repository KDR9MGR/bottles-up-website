import { Button } from '@/components/ui/button';
import { ArrowRight, Play, Star, Users, Calendar, MapPin, Wifi, Bell, Home, Ticket, Crown, User } from 'lucide-react';
import { useSiteContent } from '@/hooks/useSiteContent';

const PHONE_NAV_ITEMS = [
  { icon: Home, label: 'Home' },
  { icon: Calendar, label: 'Events' },
  { icon: Crown, label: 'Tables' },
  { icon: Ticket, label: 'Tickets' },
  { icon: User, label: 'Profile' },
];

const Hero = () => {
  const content = useSiteContent();

  const scrollToWaitlist = () => {
    const waitlistSection = document.querySelector('#waitlist');
    waitlistSection?.scrollIntoView({ behavior: 'smooth' });
  };

  return (
    <section className="relative overflow-hidden bg-black pb-20 pt-32 lg:pb-28 lg:pt-40">
      {/* Ambient background glow */}
      <div className="pointer-events-none absolute inset-0">
        <div className="absolute -left-40 top-0 h-[32rem] w-[32rem] rounded-full bg-orange-600/10 blur-[120px]" />
        <div className="absolute -right-32 top-1/3 h-[28rem] w-[28rem] rounded-full bg-orange-500/10 blur-[120px]" />
        <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_top,_rgba(255,255,255,0.04),_transparent_60%)]" />
      </div>

      <div className="container relative mx-auto px-4 lg:px-6">
        <div className="grid items-center gap-14 lg:grid-cols-2 lg:gap-16">
          {/* Content */}
          <div className="animate-fade-in-up">
            <div className="mb-7 inline-flex items-center gap-3 rounded-full border border-white/10 bg-white/5 px-4 py-2 backdrop-blur-xl">
              <div className="flex items-center gap-1.5">
                <MapPin className="h-3.5 w-3.5 text-orange-500" />
                <span className="text-xs font-semibold uppercase tracking-wide text-orange-500">Toronto</span>
              </div>
              <div className="h-1 w-1 rounded-full bg-gray-600" />
              <div className="flex items-center gap-0.5">
                {[...Array(5)].map((_, i) => (
                  <Star key={i} className="h-3.5 w-3.5 fill-orange-500 text-orange-500" />
                ))}
              </div>
              <div className="h-1 w-1 rounded-full bg-gray-600" />
              <span className="text-xs text-gray-400">Coming Soon</span>
            </div>

            <h1 className="mb-6 text-5xl font-bold leading-[1.05] tracking-tight text-white lg:text-7xl">
              {content.hero_headline || (
                <>
                  Toronto's Premier
                  <span className="block mt-2 text-gradient">Nightlife App</span>
                </>
              )}
            </h1>

            <p className="mb-4 text-xl font-semibold text-orange-500 lg:text-2xl">
              VIP Bookings • Digital Tickets • Exclusive Access
            </p>

            <p className="mb-10 max-w-xl text-lg leading-relaxed text-gray-400">
              {content.hero_subtext ||
                "Skip the lines, secure your table, and experience Toronto's hottest venues with BottlesUp. From King Street to Entertainment District - your night out, elevated."}
            </p>

            <div className="mb-10 flex flex-col gap-4 sm:flex-row">
              <Button
                size="lg"
                onClick={scrollToWaitlist}
                className="group h-14 rounded-full bg-gradient-orange px-8 text-base font-bold text-black shadow-lg shadow-orange-500/30 transition-all duration-300 hover:scale-105 hover:shadow-orange-500/50"
              >
                Join Early Access
                <ArrowRight className="ml-2 h-4 w-4 transition-transform group-hover:translate-x-1" />
              </Button>
              <Button
                size="lg"
                variant="outline"
                className="group h-14 rounded-full border-white/15 bg-white/5 px-8 text-base text-white backdrop-blur-xl transition-all duration-300 hover:border-orange-500/60 hover:bg-orange-500/10 hover:text-orange-400"
              >
                <Play className="mr-2 h-4 w-4" />
                See Preview
              </Button>
            </div>

            <div className="flex flex-wrap items-center gap-6">
              <div className="flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm text-gray-300 backdrop-blur-xl">
                <Users className="h-4 w-4 text-orange-500" />
                <span>500+ Early Users</span>
              </div>
              <div className="flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm text-gray-300 backdrop-blur-xl">
                <Calendar className="h-4 w-4 text-orange-500" />
                <span>50+ Partner Venues</span>
              </div>
            </div>
          </div>

          {/* Visual - CSS-drawn phone mockup showcasing our own branding, not a
              copied screenshot or asset. */}
          <div className="animate-fade-in relative">
            <div className="relative mx-auto max-w-[300px]">
              <div className="relative rounded-[3rem] border-[6px] border-white/10 bg-gradient-to-b from-gray-900 to-black p-2.5 shadow-2xl shadow-black/60">
                <div className="absolute left-1/2 top-2.5 z-20 h-5 w-24 -translate-x-1/2 rounded-full bg-black" />

                <div className="relative overflow-hidden rounded-[2.25rem] border border-white/10 bg-black">
                  <div className="absolute inset-0 bg-gradient-to-br from-orange-500/10 via-transparent to-transparent" />

                  {/* Status bar */}
                  <div className="relative flex items-center justify-between px-6 pb-1 pt-5 text-[10px] font-medium text-gray-400">
                    <span>9:41</span>
                    <Wifi className="h-3 w-3" />
                  </div>

                  {/* App header */}
                  <div className="relative flex items-center justify-between px-5 pt-4">
                    <div className="flex items-center gap-1.5">
                      <img src="/app_logo.svg" alt="BottlesUp Logo" className="h-5 w-5" />
                      <span className="text-sm font-bold text-gradient">BottlesUp</span>
                    </div>
                    <Bell className="h-4 w-4 text-gray-500" />
                  </div>

                  {/* Content */}
                  <div className="relative px-5 pb-3 pt-6">
                    <p className="mb-3 text-[10px] font-semibold uppercase tracking-wide text-gray-500">
                      Upcoming Event
                    </p>
                    <div className="rounded-2xl border border-white/10 bg-white/5 p-3.5 backdrop-blur-xl">
                      <div className="mb-3 h-20 rounded-xl bg-gradient-to-br from-orange-500/30 via-orange-900/20 to-black" />
                      <div className="mb-1 text-sm font-bold text-white">Trending This Week</div>
                      <p className="mb-3 text-xs text-gray-400">Toronto's hottest venues, every night.</p>
                      <div className="rounded-full bg-gradient-orange py-1.5 text-center text-xs font-bold text-black">
                        Book Now
                      </div>
                    </div>

                    <div className="mt-4 grid grid-cols-2 gap-3">
                      <div className="rounded-xl border border-white/10 bg-white/5 p-3 text-center backdrop-blur-xl">
                        <div className="text-sm font-bold text-orange-500">VIP</div>
                        <div className="text-[10px] text-gray-500">Tables</div>
                      </div>
                      <div className="rounded-xl border border-white/10 bg-white/5 p-3 text-center backdrop-blur-xl">
                        <div className="text-sm font-bold text-orange-500">Digital</div>
                        <div className="text-[10px] text-gray-500">Tickets</div>
                      </div>
                    </div>
                  </div>

                  {/* Bottom nav */}
                  <div className="relative flex items-center justify-around border-t border-white/10 bg-white/[0.03] px-2 pb-1 pt-2.5 backdrop-blur-xl">
                    {PHONE_NAV_ITEMS.map((item, i) => (
                      <div
                        key={item.label}
                        className={`flex flex-col items-center gap-1 ${i === 0 ? 'text-orange-500' : 'text-gray-600'}`}
                      >
                        <item.icon className="h-4 w-4" />
                        <span className="text-[8px] font-medium">{item.label}</span>
                      </div>
                    ))}
                  </div>
                  <div className="relative flex justify-center pb-2 pt-1.5">
                    <div className="h-1 w-24 rounded-full bg-white/20" />
                  </div>
                </div>
              </div>

              {/* Floating cards */}
              <div
                className="animate-float absolute -right-5 -top-5 rounded-2xl border border-orange-500/30 bg-black/70 px-4 py-3 shadow-xl shadow-black/40 backdrop-blur-xl"
                style={{ animationDelay: '0.5s' }}
              >
                <div className="flex items-center gap-2">
                  <div className="h-2.5 w-2.5 animate-pulse rounded-full bg-orange-500" />
                  <span className="text-sm font-medium text-white">Live</span>
                </div>
              </div>

              <div
                className="animate-float absolute -bottom-5 -left-5 rounded-2xl border border-green-500/30 bg-black/70 px-4 py-3 shadow-xl shadow-black/40 backdrop-blur-xl"
                style={{ animationDelay: '1s' }}
              >
                <div className="flex items-center gap-2">
                  <div className="h-2.5 w-2.5 animate-pulse rounded-full bg-green-500" />
                  <span className="text-sm font-medium text-white">Available</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};

export default Hero;
