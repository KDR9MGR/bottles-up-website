import { Calendar, Users, Shield, Zap, CreditCard, MapPin, Ticket, Crown, Clock } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';

const Features = () => {
  const features = [
    {
      icon: Crown,
      title: 'VIP Table Bookings',
      description: 'Reserve premium tables at Toronto\'s hottest clubs and lounges. Skip the line and enjoy VIP treatment all night long.'
    },
    {
      icon: Ticket,
      title: 'Digital Tickets',
      description: 'Secure digital tickets for exclusive events, concerts, and parties. QR code entry for seamless venue access.'
    },
    {
      icon: Calendar,
      title: 'Event Discovery',
      description: 'Discover curated events happening across Toronto. From rooftop parties to underground shows - find your scene.'
    },
    {
      icon: MapPin,
      title: 'Toronto Hotspots',
      description: 'Entertainment District, King Street, Queen West - we\'ve got connections to the city\'s premier nightlife destinations.'
    },
    {
      icon: Users,
      title: 'Group Coordination',
      description: 'Plan nights out with friends. Split costs, coordinate arrival times, and ensure everyone\'s on the guest list.'
    },
    {
      icon: Clock,
      title: 'Real-Time Updates',
      description: 'Live venue capacity, wait times, and event updates. Make informed decisions about where to go next.'
    },
    {
      icon: Shield,
      title: 'Secure & Trusted',
      description: 'Bank-level security for all transactions. Partner verification ensures you\'re booking with legitimate venues.'
    },
    {
      icon: Zap,
      title: 'Instant Confirmation',
      description: 'Get immediate booking confirmations and digital receipts. No more waiting or uncertainty about your reservations.'
    },
    {
      icon: CreditCard,
      title: 'Flexible Payment',
      description: 'Multiple payment options including group splitting, deposits, and pay-at-venue arrangements for maximum convenience.'
    }
  ];

  const strip = features.slice(0, 6);

  return (
    <section id="features" className="bg-black py-20 lg:py-28">
      <div className="container mx-auto px-4 lg:px-6">
        <div className="mx-auto mb-14 max-w-3xl text-center">
          <span className="mb-4 inline-block text-xs font-semibold uppercase tracking-[0.2em] text-orange-500">
            Why BottlesUp
          </span>
          <h2 className="mb-6 text-4xl font-bold text-white lg:text-5xl">
            Revolutionizing <span className="text-gradient">Toronto Nightlife</span>
          </h2>
          <p className="text-lg text-gray-400 lg:text-xl">
            From Entertainment District to King Street West, BottlesUp connects you to the city's most exclusive
            venues and events. Experience Toronto nightlife like never before.
          </p>
        </div>

        {/* Feature strip */}
        <div className="mb-16 grid grid-cols-2 gap-4 rounded-3xl border border-white/10 bg-white/[0.03] p-6 backdrop-blur-xl sm:grid-cols-3 lg:grid-cols-6 lg:p-8">
          {strip.map((feature, index) => (
            <div
              key={feature.title}
              className="animate-fade-in flex flex-col items-center gap-3 rounded-2xl px-2 py-3 text-center transition-colors duration-300 hover:bg-white/5"
              style={{ animationDelay: `${index * 0.08}s` }}
            >
              <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-gradient-orange">
                <feature.icon className="h-5 w-5 text-black" />
              </div>
              <span className="text-sm font-medium text-gray-200">{feature.title}</span>
            </div>
          ))}
        </div>

        {/* Card grid */}
        <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3 lg:gap-8">
          {features.map((feature, index) => (
            <Card
              key={feature.title}
              className="group animate-fade-in hover-lift rounded-3xl border-white/10 bg-white/[0.03] backdrop-blur-xl transition-all duration-300 hover:border-orange-500/40 hover:bg-white/[0.06]"
              style={{ animationDelay: `${index * 0.1}s` }}
            >
              <CardContent className="p-7">
                <div className="glow-orange mb-5 flex h-12 w-12 items-center justify-center rounded-2xl bg-gradient-orange transition-transform duration-300 group-hover:scale-110">
                  <feature.icon className="h-6 w-6 text-black" />
                </div>
                <h3 className="mb-3 text-xl font-semibold text-white transition-colors group-hover:text-orange-500">
                  {feature.title}
                </h3>
                <p className="leading-relaxed text-gray-400">{feature.description}</p>
              </CardContent>
            </Card>
          ))}
        </div>

        {/* Call to Action */}
        <div className="mt-16 text-center">
          <p className="mb-6 text-gray-400">Ready to elevate your Toronto nightlife experience?</p>
          <button
            onClick={() => {
              const waitlistSection = document.querySelector('#waitlist');
              waitlistSection?.scrollIntoView({ behavior: 'smooth' });
            }}
            className="glow-orange transform rounded-full bg-gradient-orange px-8 py-4 font-bold text-black transition-all duration-300 hover:scale-105 hover:opacity-90"
          >
            Join the Revolution
          </button>
        </div>
      </div>
    </section>
  );
};

export default Features;
