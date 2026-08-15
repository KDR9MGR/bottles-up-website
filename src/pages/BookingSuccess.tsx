import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams, Link } from 'react-router-dom';
import { CheckCircle2, Loader2, Lock } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { supabase } from '@/lib/supabase';
import { useToast } from '@/hooks/use-toast';
import { useUserAuth, userSignUp } from '@/hooks/useUserAuth';
import TicketCard, { type TicketCardData } from '@/components/TicketCard';

type PaidTicket = TicketCardData & { customerEmail?: string };

type PaidBooking = {
  confirmationCode: string;
  customerName: string;
  customerEmail?: string;
  guestCount: number;
  tableTypeName: string;
  venueName: string;
  bookingDate: string;
  startTime: string;
  depositCents: number;
  bottleSubtotalCents: number;
  taxCents: number;
  bottlesupFeeCents: number;
  totalCents: number;
  currency: string;
  bottles: { name: string; size: string | null; quantity: number; unitPriceCents: number; lineTotalCents: number }[];
};

const money = (cents: number, currency: string) => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

const REDIRECT_SECONDS = 15;

function CreateAccountPrompt({ email, name }: { email: string; name: string }) {
  const { toast } = useToast();
  const [password, setPassword] = useState('');
  const [saving, setSaving] = useState(false);
  const [done, setDone] = useState(false);
  const [dismissed, setDismissed] = useState(false);

  if (dismissed) return null;

  if (done) {
    return (
      <div className="mt-6 w-full max-w-sm rounded-2xl border border-orange-500/20 bg-orange-500/5 p-5 text-center">
        <p className="text-sm text-white font-medium">Account created 🎉</p>
        <p className="mt-1 text-xs text-gray-400">
          Check <span className="text-white">{email}</span> to confirm, then sign in to see this booking on your dashboard.
        </p>
      </div>
    );
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (password.length < 6) {
      toast({ title: 'Password must be at least 6 characters', variant: 'destructive' });
      return;
    }
    setSaving(true);
    try {
      await userSignUp(name, email, password);
      setDone(true);
    } catch (err: unknown) {
      toast({ title: 'Could not create account', description: (err as Error).message, variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="mt-6 w-full max-w-sm rounded-2xl border border-white/10 bg-zinc-950 p-5 text-left">
      <p className="text-sm font-semibold text-white">Save this booking to an account</p>
      <p className="mt-1 text-xs text-gray-400">
        Track all your bookings, get QR tickets in one place, and manage everything from your dashboard.
      </p>
      <form onSubmit={handleSubmit} className="mt-4 space-y-3">
        <div className="space-y-1">
          <Label className="text-xs text-gray-500">Email</Label>
          <Input value={email} disabled className="bg-zinc-900 border-white/10 text-gray-400" />
        </div>
        <div className="space-y-1">
          <Label className="text-xs text-gray-500">Create a Password</Label>
          <div className="relative">
            <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
            <Input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="Min. 6 characters"
              className="pl-9 bg-zinc-900 border-white/10 text-white"
              required
            />
          </div>
        </div>
        <div className="flex gap-2 pt-1">
          <Button type="button" variant="ghost" size="sm" className="flex-1 text-gray-500 hover:text-gray-300" onClick={() => setDismissed(true)}>
            No thanks
          </Button>
          <Button type="submit" size="sm" disabled={saving} className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90">
            {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Create Account'}
          </Button>
        </div>
      </form>
    </div>
  );
}

const BookingSuccess = () => {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { session, loading: authLoading } = useUserAuth();
  const sessionId = searchParams.get('session_id');
  const [status, setStatus] = useState<'checking' | 'paid' | 'pending'>('checking');
  const [ticket, setTicket] = useState<PaidTicket | null>(null);
  const [booking, setBooking] = useState<PaidBooking | null>(null);
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
      if (data?.status === 'paid' && data.booking) {
        setBooking(data.booking as PaidBooking);
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

  // Pause the auto-redirect countdown while the account-creation prompt is
  // showing so an unauthenticated customer isn't yanked to "/" mid-signup.
  const showAccountPrompt = !authLoading && !session && (ticket?.customerEmail || booking?.customerEmail);

  useEffect(() => {
    if (status !== 'paid' || showAccountPrompt) return;
    if (secondsLeft <= 0) {
      navigate('/');
      return;
    }
    const t = setTimeout(() => setSecondsLeft((s) => s - 1), 1000);
    return () => clearTimeout(t);
  }, [status, secondsLeft, navigate, showAccountPrompt]);

  if (status === 'paid' && (ticket || booking)) {
    const cardData: TicketCardData | null = ticket
      ? ticket
      : booking
        ? {
            ticketCode: booking.confirmationCode,
            customerName: booking.customerName,
            quantity: booking.guestCount,
            eventTitle: booking.tableTypeName,
            venueName: booking.venueName,
            startDate: `${booking.bookingDate}T${booking.startTime}`,
            tierName: 'Guests',
          }
        : null;

    const customerEmail = ticket?.customerEmail ?? booking?.customerEmail ?? '';
    const customerName = ticket?.customerName ?? booking?.customerName ?? '';

    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 py-12 text-center">
        <CheckCircle2 className="mb-4 h-12 w-12 text-orange-500" />
        <h1 className="mb-2 text-3xl font-bold text-white">You're in! 🍾</h1>
        <p className="mb-8 text-gray-400">
          {ticket
            ? 'Your e-ticket is below - we also emailed a copy to you.'
            : 'Your table reservation is below - we also emailed a copy to you.'}
        </p>

        {cardData && <TicketCard ticket={cardData} label={booking ? 'VIP Table Reservation' : undefined} />}

        {booking && (
          <div className="mt-4 w-full max-w-sm space-y-2 rounded-2xl border border-gray-800 bg-gray-950 p-5 text-left text-sm">
            <div className="flex justify-between text-gray-300">
              <span>{booking.tableTypeName}</span>
              <span>{money(booking.depositCents, booking.currency)}</span>
            </div>
            {booking.bottles.map((b, i) => (
              <div key={i} className="flex justify-between text-gray-300">
                <span>
                  {b.name}
                  {b.size ? ` (${b.size})` : ''} &times; {b.quantity}
                </span>
                <span>{money(b.lineTotalCents, booking.currency)}</span>
              </div>
            ))}
            {booking.taxCents > 0 && (
              <div className="flex justify-between text-gray-500">
                <span>Tax</span>
                <span>{money(booking.taxCents, booking.currency)}</span>
              </div>
            )}
            {booking.bottlesupFeeCents > 0 && (
              <div className="flex justify-between text-gray-500">
                <span>BottlesUp fee</span>
                <span>{money(booking.bottlesupFeeCents, booking.currency)}</span>
              </div>
            )}
            <div className="flex justify-between border-t border-gray-800 pt-2 font-semibold text-white">
              <span>Total paid</span>
              <span>{money(booking.totalCents, booking.currency)}</span>
            </div>
          </div>
        )}

        {showAccountPrompt && customerEmail && (
          <CreateAccountPrompt email={customerEmail} name={customerName} />
        )}

        {!showAccountPrompt && (
          <p className="mt-6 text-sm text-gray-500">
            Taking you back home in {secondsLeft}s...
          </p>
        )}
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
