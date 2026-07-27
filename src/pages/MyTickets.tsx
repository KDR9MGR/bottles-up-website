import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { Loader2, Mail } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { getAuthRedirectBase } from '@/lib/authRedirect';
import TicketCard, { type TicketCardData } from '@/components/TicketCard';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

type OrderRow = {
  ticket_code: string | null;
  customer_name: string;
  quantity: number;
  status: string;
  site_ticket_tiers: { name: string } | null;
  site_events: { title: string; venue_name: string; start_date: string } | null;
};

const MyTickets = () => {
  const { toast } = useToast();
  const [session, setSession] = useState<Session | null>(null);
  const [checkingSession, setCheckingSession] = useState(true);
  const [email, setEmail] = useState('');
  const [sending, setSending] = useState(false);
  const [linkSent, setLinkSent] = useState(false);
  const [tickets, setTickets] = useState<TicketCardData[]>([]);
  const [loadingTickets, setLoadingTickets] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setCheckingSession(false);
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession);
    });

    return () => subscription.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!session) {
      setTickets([]);
      return;
    }

    setLoadingTickets(true);
    supabase
      .from('site_orders')
      .select(
        'ticket_code, customer_name, quantity, status, site_ticket_tiers(name), site_events(title, venue_name, start_date)',
      )
      .eq('status', 'paid')
      .order('created_at', { ascending: false })
      .then(({ data }) => {
        const rows = (data ?? []) as unknown as OrderRow[];
        setTickets(
          rows
            .filter((row) => row.ticket_code)
            .map((row) => ({
              ticketCode: row.ticket_code as string,
              customerName: row.customer_name,
              quantity: row.quantity,
              tierName: row.site_ticket_tiers?.name ?? '',
              eventTitle: row.site_events?.title ?? 'Your event',
              venueName: row.site_events?.venue_name ?? '',
              startDate: row.site_events?.start_date ?? '',
            })),
        );
        setLoadingTickets(false);
      });
  }, [session]);

  const handleSendLink = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!EMAIL_RE.test(email)) {
      toast({ title: 'Please enter a valid email', variant: 'destructive' });
      return;
    }

    setSending(true);
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: `${getAuthRedirectBase()}/my-tickets` },
    });
    setSending(false);

    if (error) {
      toast({ title: 'Could not send link', description: error.message, variant: 'destructive' });
      return;
    }
    setLinkSent(true);
  };

  const handleSignOut = async () => {
    await supabase.auth.signOut();
    setLinkSent(false);
    setEmail('');
  };

  if (checkingSession) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black">
        <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
      </div>
    );
  }

  if (!session) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center">
        <Mail className="mb-4 h-10 w-10 text-orange-500" />
        <h1 className="mb-2 text-2xl font-bold text-white">Find your tickets</h1>
        <p className="mb-8 max-w-sm text-gray-400">
          Enter the email you used at checkout and we'll send you a link to view your tickets - no password needed.
        </p>

        {linkSent ? (
          <p className="max-w-sm text-gray-300">
            Check <span className="font-semibold text-white">{email}</span> for a sign-in link. Click it to see your
            tickets here.
          </p>
        ) : (
          <form onSubmit={handleSendLink} className="w-full max-w-sm space-y-4 text-left">
            <div className="space-y-2">
              <Label>Email</Label>
              <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
            </div>
            <Button
              type="submit"
              disabled={sending}
              className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
            >
              {sending ? 'Sending...' : 'Send me a link'}
            </Button>
          </form>
        )}
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-black px-4 py-12">
      <div className="mx-auto flex max-w-sm flex-col items-center">
        <h1 className="mb-8 text-2xl font-bold text-white">Your Tickets</h1>

        {loadingTickets ? (
          <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
        ) : tickets.length === 0 ? (
          <p className="text-center text-gray-400">No paid tickets found for this email yet.</p>
        ) : (
          <div className="w-full space-y-6">
            {tickets.map((ticket) => (
              <TicketCard key={ticket.ticketCode} ticket={ticket} />
            ))}
          </div>
        )}

        <Button variant="outline" className="mt-8 border-gray-700 text-white hover:bg-gray-900" onClick={handleSignOut}>
          Sign out
        </Button>
      </div>
    </div>
  );
};

export default MyTickets;
