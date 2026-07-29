import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';

const EmailCollection = () => {
  const [email, setEmail] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const { toast } = useToast();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!email) {
      toast({
        title: "Please enter your email",
        description: "Email is required to join our exclusive waitlist",
        variant: "destructive",
      });
      return;
    }

    // Email validation
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      toast({
        title: "Invalid email",
        description: "Please enter a valid email address",
        variant: "destructive",
      });
      return;
    }

    setIsLoading(true);

    try {
      const { data, error } = await supabase.functions.invoke('vip-subscribe', {
        body: { email },
      });

      if (error) throw error;
      if (data?.error) throw new Error(data.error);

      toast({
        title: "Welcome to BottlesUp! 🍾",
        description: data?.message || "You're now on the exclusive early access list for Toronto's premier nightlife app",
      });
      setEmail('');
    } catch (error) {
      toast({
        title: "Something went wrong",
        description: error instanceof Error ? error.message : 'Please try again in a moment.',
        variant: 'destructive',
      });
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <section id="waitlist" className="overflow-hidden bg-black py-20 lg:py-24">
      <div className="container mx-auto px-4 lg:px-6">
        <div className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.03] p-8 backdrop-blur-2xl lg:p-14">
          <div className="pointer-events-none absolute -left-24 -top-24 h-64 w-64 rounded-full bg-orange-500/10 blur-3xl" />
          <div className="pointer-events-none absolute -bottom-24 -right-24 h-64 w-64 rounded-full bg-orange-500/10 blur-3xl" />

          <div className="relative grid items-center gap-10 lg:grid-cols-2 lg:gap-16">
            <div>
              <h2 className="mb-4 text-3xl font-bold text-white lg:text-4xl">
                Join the VIP List for
                <span className="mt-1 block text-gradient">Toronto's Hottest App</span>
              </h2>
              <p className="mb-6 max-w-lg leading-relaxed text-gray-400">
                Be among the first to experience exclusive VIP table bookings, digital event tickets, and insider
                access to Toronto's premier nightlife venues.
              </p>

              <div className="mb-6 flex flex-wrap items-center gap-5 text-sm text-gray-400">
                <div className="flex items-center gap-2">
                  <div className="h-2 w-2 animate-pulse-slow rounded-full bg-orange-500" />
                  <span>Early access</span>
                </div>
                <div className="flex items-center gap-2">
                  <div className="h-2 w-2 animate-pulse-slow rounded-full bg-blue-500" />
                  <span>No spam</span>
                </div>
                <div className="flex items-center gap-2">
                  <div className="h-2 w-2 animate-pulse-slow rounded-full bg-purple-500" />
                  <span>VIP perks</span>
                </div>
              </div>

              <div className="grid grid-cols-3 gap-4 text-sm">
                <div>
                  <div className="mb-1 text-lg font-bold text-orange-500">🎫</div>
                  <div className="text-gray-300">Priority Event Access</div>
                </div>
                <div>
                  <div className="mb-1 text-lg font-bold text-orange-500">👑</div>
                  <div className="text-gray-300">VIP Table Discounts</div>
                </div>
                <div>
                  <div className="mb-1 text-lg font-bold text-orange-500">🌟</div>
                  <div className="text-gray-300">Exclusive Events</div>
                </div>
              </div>
            </div>

            <div>
              <form onSubmit={handleSubmit}>
                <div className="flex flex-col gap-3 rounded-2xl border border-white/10 bg-black/40 p-2 backdrop-blur-xl sm:flex-row">
                  <Input
                    type="email"
                    placeholder="Enter your email address"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    className="flex-1 border-none bg-transparent px-4 text-lg text-white placeholder:text-gray-500 focus-visible:ring-0"
                    disabled={isLoading}
                  />
                  <Button
                    type="submit"
                    disabled={isLoading}
                    className="glow-orange transform rounded-xl bg-gradient-orange px-8 py-6 font-bold text-black transition-all duration-300 hover:scale-105 disabled:transform-none disabled:opacity-50 sm:py-3"
                  >
                    {isLoading ? (
                      <div className="flex items-center gap-2">
                        <div className="h-4 w-4 animate-spin rounded-full border-2 border-black/30 border-t-black" />
                        Joining...
                      </div>
                    ) : (
                      'Join VIP List'
                    )}
                  </Button>
                </div>
              </form>
              <p className="mt-4 text-center text-xs text-gray-500 lg:text-left">
                🔒 Your email is secure and will never be shared. Toronto locals only.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};

export default EmailCollection;
