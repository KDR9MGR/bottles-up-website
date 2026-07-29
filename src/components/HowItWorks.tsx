import { Card, CardContent } from '@/components/ui/card';
import { Search, Calendar, CreditCard, PartyPopper } from 'lucide-react';

const HowItWorks = () => {
  const steps = [
    {
      icon: Search,
      title: 'Discover',
      description: 'Browse through curated events and venues in your area or any city you plan to visit.'
    },
    {
      icon: Calendar,
      title: 'Select',
      description: 'Choose your perfect event, pick your preferred date and time, and select your party size.'
    },
    {
      icon: CreditCard,
      title: 'Book',
      description: 'Secure your spot with our safe payment system. Pay now or choose our flexible payment options.'
    },
    {
      icon: PartyPopper,
      title: 'Enjoy',
      description: 'Show up and party! Skip the lines with your digital ticket and enjoy VIP treatment.'
    }
  ];

  return (
    <section id="how-it-works" className="bg-black py-20 lg:py-28">
      <div className="container mx-auto px-4 lg:px-6">
        <div className="mx-auto mb-16 max-w-2xl text-center">
          <span className="mb-4 inline-block text-xs font-semibold uppercase tracking-[0.2em] text-orange-500">
            How It Works
          </span>
          <h2 className="mb-6 text-4xl font-bold text-white lg:text-5xl">
            A Better Night Out, <span className="text-gradient">In 4 Steps</span>
          </h2>
          <p className="text-lg text-gray-400 lg:text-xl">
            Getting started with BottlesUp is simple. Follow these four easy steps to book your next unforgettable
            night out.
          </p>
        </div>

        <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-4 lg:gap-8">
          {steps.map((step, index) => (
            <div key={step.title} className="relative">
              <Card
                className="group animate-fade-in hover-lift rounded-3xl border-white/10 bg-white/[0.03] backdrop-blur-xl transition-all duration-300 hover:border-orange-500/40"
                style={{ animationDelay: `${index * 0.1}s` }}
              >
                <CardContent className="p-8 text-center">
                  <div className="relative mx-auto mb-5 h-16 w-16">
                    <div className="glow-orange flex h-16 w-16 items-center justify-center rounded-full bg-gradient-orange transition-transform duration-300 group-hover:scale-110">
                      <step.icon className="h-8 w-8 text-black" />
                    </div>
                    <div className="absolute -right-2 -top-2 flex h-7 w-7 items-center justify-center rounded-full border-2 border-black bg-orange-500 text-sm font-bold text-black">
                      {index + 1}
                    </div>
                  </div>

                  <h3 className="mb-3 text-xl font-semibold text-white transition-colors group-hover:text-orange-500">
                    {step.title}
                  </h3>
                  <p className="leading-relaxed text-gray-400">{step.description}</p>
                </CardContent>
              </Card>

              {/* Connector line for desktop */}
              {index < steps.length - 1 && (
                <div className="absolute -right-4 top-1/2 hidden h-0.5 w-8 -translate-y-1/2 bg-gradient-orange opacity-50 lg:block" />
              )}
            </div>
          ))}
        </div>
      </div>
    </section>
  );
};

export default HowItWorks;
