import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';

const PartnersCTA = () => {
  const { toast } = useToast();
  const [venueName, setVenueName] = useState('');
  const [email, setEmail] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!email.trim()) return;
    setSubmitting(true);
    try {
      const { data, error } = await supabase.functions.invoke('submit-partner-lead', {
        body: { email, venue_name: venueName || undefined },
      });
      if (error || data?.error) throw new Error(data?.error ?? error?.message);
      setSubmitted(true);
      setVenueName('');
      setEmail('');
    } catch (err) {
      toast({
        title: 'Could not submit request',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <section id="partners" className="container mx-auto px-4 py-14 lg:px-6">
      <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-primary">Partners</div>
      <h2 className="mb-2 text-2xl font-bold text-white lg:text-3xl">Run a venue? Throw events?</h2>
      <p className="mb-8 max-w-xl text-gray-400">Get listed before launch - free while we're in early access.</p>

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="rounded-xl border border-gray-800 p-6">
          <h3 className="mb-3 font-semibold text-white">For venues</h3>
          <ul className="mb-5 space-y-2 text-sm text-gray-400">
            <li>&bull; Push live capacity and table inventory in real time.</li>
            <li>&bull; Take deposits up front - no more no-shows.</li>
            <li>&bull; Free while we're in early access.</li>
          </ul>
          <Button asChild variant="outline" className="border-gray-700">
            <Link to="/partners/apply">List my venue</Link>
          </Button>
        </div>

        <div className="rounded-xl border border-gray-800 p-6">
          <h3 className="mb-3 font-semibold text-white">For event organizers</h3>
          <ul className="mb-5 space-y-2 text-sm text-gray-400">
            <li>&bull; Sell tickets to people already out tonight.</li>
            <li>&bull; Bundle tables and guest list in one link.</li>
            <li>&bull; Door scanning built into the app.</li>
          </ul>
          <Button asChild variant="outline" className="border-gray-700">
            <Link to="/partners/apply">Sell with us</Link>
          </Button>
        </div>

        <div className="rounded-xl border border-primary/30 bg-primary/5 p-6">
          <h3 className="mb-1 font-semibold text-white">Early partner list</h3>
          <p className="mb-4 text-sm text-gray-400">
            Priority onboarding and a partner login the day we go live on the App Store.
          </p>
          {submitted ? (
            <p className="text-sm text-green-400">Thanks - we'll be in touch.</p>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-2">
              <Input
                placeholder="Venue or brand name"
                value={venueName}
                onChange={(e) => setVenueName(e.target.value)}
              />
              <Input
                type="email"
                placeholder="Work email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
              />
              <Button
                type="submit"
                disabled={submitting || !email.trim()}
                className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
              >
                {submitting ? 'Submitting...' : 'Request early access'}
              </Button>
            </form>
          )}
        </div>
      </div>
    </section>
  );
};

export default PartnersCTA;
