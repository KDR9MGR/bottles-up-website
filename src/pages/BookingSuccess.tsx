import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams, Link } from 'react-router-dom';
import { CheckCircle2, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { supabase } from '@/lib/supabase';
import TicketCard, { type TicketCardData } from '@/components/TicketCard';

type PaidTicket = TicketCardData;

const REDIRECT_SECONDS = 15;

const BookingSuccess = () => {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const sessionId = searchParams.get('session_id');
  const [status, setStatus] = useState<'checking' | 'paid' | 'pending'>('checking');
  const [ticket, setTicket] = useState<PaidTicket | null>(null);
  const [secondsLeft, setSecondsLeft] = useState(REDIRECT_SECONDS);

  useEffect(() => {
    if (!sessionId) return;

    let attempts = 0;
    let cancelled = false;

    const poll = async () => {
      const { data } = await supabase.functions.invoke('site-booking-status', {
        body: { session_id: sessionId },
      });

      if (cancelled) return;

      if (data?.status === 'paid' && data.ticket) {
        setTicket(data.ticket as PaidTicket);
        setStatus('paid');
        return;
      }
      attempts += 1;
      if (attempts < 10) {
        setTimeout(poll, 2000);
      } else {
        setStatus('pending');
      }
    };

    poll();
    return () => {
      cancelled = true;
    };
  }, [sessionId]);

  useEffect(() => {
    if (status !== 'paid') return;
    if (secondsLeft <= 0) {
      navigate('/');
      return;
    }
    const t = setTimeout(() => setSecondsLeft((s) => s - 1), 1000);
    return () => clearTimeout(t);
  }, [status, secondsLeft, navigate]);

  if (status === 'paid' && ticket) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 py-12 text-center">
        <CheckCircle2 className="mb-4 h-12 w-12 text-orange-500" />
        <h1 className="mb-2 text-3xl font-bold text-white">You're in! 🍾</h1>
        <p className="mb-8 text-gray-400">Your e-ticket is below - we also emailed a copy to you.</p>

        <TicketCard ticket={ticket} />

        <p className="mt-6 text-sm text-gray-500">
          Taking you back home in {secondsLeft}s...
        </p>
        <Button
          asChild
          variant="outline"
          className="mt-3 border-gray-700 text-white hover:bg-gray-900"
        >
          <Link to="/">Back to BottlesUp now</Link>
        </Button>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center">
      <Loader2 className="mb-6 h-12 w-12 animate-spin text-orange-500" />
      <h1 className="mb-4 text-3xl font-bold text-white">Payment received</h1>
      <p className="mb-8 max-w-md text-gray-400">
        {status === 'checking'
          ? "We're confirming your payment - this usually takes a few seconds."
          : "Still confirming your payment. Your e-ticket will arrive by email shortly - check back here or your inbox."}
      </p>
      <Button asChild className="bg-gradient-orange text-black font-bold hover:opacity-90">
        <Link to="/">Back to BottlesUp</Link>
      </Button>
    </div>
  );
};

export default BookingSuccess;
