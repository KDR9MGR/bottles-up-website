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
    <section id="waitlist" className="py-20 px-4 overflow-hidden bg-gradient-to-br from-black via-gray-900 to-black">
      <div className="max-w-4xl mx-auto text-center">
        <div className="relative">
          {/* Background decoration */}
          <div className="absolute -top-20 -left-20 w-40 h-40 bg-orange-500/10 rounded-full blur-3xl"></div>
          <div className="absolute -bottom-20 -right-20 w-40 h-40 bg-orange-500/10 rounded-full blur-3xl"></div>
          
          <div className="relative bg-black/50 backdrop-blur-sm border border-gray-800 rounded-3xl p-12 shadow-2xl hover-lift">
            <h2 className="text-4xl md:text-5xl font-bold text-white mb-6">
              Join the VIP List for
              <span className="text-gradient block mt-2">Toronto's Hottest App</span>
            </h2>
            
            <p className="text-xl text-gray-300 mb-8 max-w-2xl mx-auto leading-relaxed">
              Be among the first to experience exclusive VIP table bookings, 
              digital event tickets, and insider access to Toronto's premier nightlife venues.
            </p>

            <form onSubmit={handleSubmit} className="max-w-md mx-auto">
              <div className="flex gap-3 p-2 bg-gray-900/50 rounded-2xl border border-gray-700 backdrop-blur-sm">
                <Input
                  type="email"
                  placeholder="Enter your email address"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="flex-1 bg-transparent border-none text-white placeholder:text-gray-400 focus:ring-0 text-lg px-4"
                  disabled={isLoading}
                />
                <Button
                  type="submit"
                  disabled={isLoading}
                  className="bg-gradient-orange hover:opacity-90 text-black font-bold px-8 py-3 rounded-xl transition-all duration-300 transform hover:scale-105 disabled:opacity-50 disabled:transform-none glow-orange"
                >
                  {isLoading ? (
                    <div className="flex items-center gap-2">
                      <div className="w-4 h-4 border-2 border-black/30 border-t-black rounded-full animate-spin"></div>
                      Joining...
                    </div>
                  ) : (
                    'Join VIP List'
                  )}
                </Button>
              </div>
            </form>

            <div className="mt-8 flex items-center justify-center gap-6 text-sm text-gray-400">
              <div className="flex items-center gap-2">
                <div className="w-2 h-2 bg-orange-500 rounded-full animate-pulse-slow"></div>
                <span>Early access</span>
              </div>
              <div className="flex items-center gap-2">
                <div className="w-2 h-2 bg-blue-500 rounded-full animate-pulse-slow"></div>
                <span>No spam</span>
              </div>
              <div className="flex items-center gap-2">
                <div className="w-2 h-2 bg-purple-500 rounded-full animate-pulse-slow"></div>
                <span>VIP perks</span>
              </div>
            </div>

            {/* Additional benefits */}
            <div className="mt-8 grid md:grid-cols-3 gap-4 text-sm">
              <div className="text-center">
                <div className="text-orange-500 font-bold text-lg">🎫</div>
                <div className="text-gray-300">Priority Event Access</div>
              </div>
              <div className="text-center">
                <div className="text-orange-500 font-bold text-lg">👑</div>
                <div className="text-gray-300">VIP Table Discounts</div>
              </div>
              <div className="text-center">
                <div className="text-orange-500 font-bold text-lg">🌟</div>
                <div className="text-gray-300">Exclusive Toronto Events</div>
              </div>
            </div>

            {/* Trust indicator */}
            <div className="mt-6 text-xs text-gray-500">
              🔒 Your email is secure and will never be shared. Toronto locals only.
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};

export default EmailCollection; 