import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { Loader2, Plus, X, Send, CheckCircle2, Mail } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { formatWeekday } from '@/lib/bookingNight';
import BackLink from '@/components/BackLink';

interface BookingSummary {
  customerName: string;
  venueName: string;
  tableTypeName: string;
  bookingDate: string;
  startTime: string;
  crossesMidnight: boolean;
  nightDate: string;
  timeSlotLabel: string;
  maxGuests: number;
  remainingCapacity: number;
}

interface Guest {
  id: string;
  guest_name: string;
  guest_email: string;
  ticket_sent_at: string | null;
  checked_in_at: string | null;
}

interface DraftGuest {
  name: string;
  email: string;
}

const formattedDate = (bookingDate: string) =>
  new Date(`${bookingDate}T00:00:00Z`).toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC',
  });

// Public, no login required - the same trust model as /order/:code (whoever
// holds the booking's confirmation code can act on it). Reached from the
// post-checkout confirmation screen, the confirmation email's "manage your
// booking" link, or scanning the booking's own QR - so a customer who didn't
// send every guest ticket right away can always come back and finish later.
const BookingByCode = () => {
  const { code } = useParams<{ code: string }>();
  const { toast } = useToast();
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [booking, setBooking] = useState<BookingSummary | null>(null);
  const [guests, setGuests] = useState<Guest[]>([]);
  const [drafts, setDrafts] = useState<DraftGuest[]>([{ name: '', email: '' }]);
  const [submitting, setSubmitting] = useState(false);
  const [resendingId, setResendingId] = useState<string | null>(null);

  const load = async () => {
    if (!code) return;
    const { data, error } = await supabase.functions.invoke('manage-guest-tickets', {
      body: { confirmation_code: code, action: 'list' },
    });
    if (error || !data || data.error) {
      setNotFound(true);
      setLoading(false);
      return;
    }
    setBooking(data.booking);
    setGuests(data.guests ?? []);
    setLoading(false);
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [code]);

  const updateDraft = (index: number, field: keyof DraftGuest, value: string) =>
    setDrafts((prev) => prev.map((d, i) => (i === index ? { ...d, [field]: value } : d)));

  const addDraftRow = () => setDrafts((prev) => [...prev, { name: '', email: '' }]);
  const removeDraftRow = (index: number) => setDrafts((prev) => prev.filter((_, i) => i !== index));

  const handleSend = async () => {
    if (!code) return;
    const validDrafts = drafts.filter((d) => d.name.trim() && d.email.trim());
    if (validDrafts.length === 0) {
      toast({ title: 'Add at least one guest name and email', variant: 'destructive' });
      return;
    }
    setSubmitting(true);
    try {
      const { data, error } = await supabase.functions.invoke('manage-guest-tickets', {
        body: {
          confirmation_code: code,
          action: 'add',
          guests: validDrafts.map((d) => ({ name: d.name.trim(), email: d.email.trim() })),
        },
      });
      if (error || data?.error) {
        throw new Error(data?.error ?? error?.message ?? 'Could not send guest tickets');
      }
      const sentCount = (data.results as { sent: boolean }[]).filter((r) => r.sent).length;
      toast({
        title: sentCount === validDrafts.length ? 'Guest tickets sent' : 'Some tickets could not be sent',
        description: sentCount === validDrafts.length ? undefined : 'Try resending from the list below.',
      });
      setDrafts([{ name: '', email: '' }]);
      await load();
    } catch (err) {
      toast({
        title: 'Could not send guest tickets',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setSubmitting(false);
    }
  };

  const handleResend = async (guestId: string) => {
    if (!code) return;
    setResendingId(guestId);
    try {
      const { data, error } = await supabase.functions.invoke('manage-guest-tickets', {
        body: { confirmation_code: code, action: 'resend', guest_id: guestId },
      });
      if (error || data?.error) {
        throw new Error(data?.error ?? error?.message ?? 'Could not resend that ticket');
      }
      toast({ title: 'Ticket resent' });
      await load();
    } catch (err) {
      toast({
        title: 'Could not resend',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setResendingId(null);
    }
  };

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black">
        <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
      </div>
    );
  }

  if (notFound || !booking) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center">
        <p className="text-gray-400">We couldn't find a confirmed booking for that code.</p>
        <Button asChild className="mt-4 bg-gradient-orange text-black font-bold hover:opacity-90">
          <Link to="/">Back to BottlesUp</Link>
        </Button>
      </div>
    );
  }

  const draftCount = drafts.filter((d) => d.name.trim() && d.email.trim()).length;
  const overCapacity = draftCount > booking.remainingCapacity;

  return (
    <div className="min-h-screen bg-black px-4 py-10">
      <div className="mx-auto max-w-sm">
        <BackLink to="/" label="Back to BottlesUp" />
        <h1 className="mb-1 mt-4 text-center text-xl font-bold text-white">
          {booking.tableTypeName} - {booking.venueName}
        </h1>
        <p className="mb-1 text-center text-sm text-gray-500">
          {booking.crossesMidnight
            ? `${formatWeekday(booking.nightDate)} night's event · Arrival: ${formatWeekday(booking.bookingDate)}, ${booking.timeSlotLabel}`
            : `${formattedDate(booking.bookingDate)} · Arrival ${booking.timeSlotLabel}`}
        </p>
        <p className="mb-6 text-center text-xs text-gray-600">Booked by {booking.customerName}</p>

        <div className="mb-6 flex items-center justify-between rounded-lg border border-gray-800 p-3">
          <span className="text-sm text-gray-400">Guest tickets</span>
          <span className="text-sm font-semibold text-white">
            {booking.maxGuests - 1 - booking.remainingCapacity} sent &middot; {booking.remainingCapacity} left
          </span>
        </div>

        {guests.length > 0 && (
          <div className="mb-6 space-y-2">
            {guests.map((g) => (
              <div key={g.id} className="flex items-center gap-3 rounded-lg border border-gray-800 p-3">
                <div className="flex-1">
                  <div className="text-sm font-medium text-white">{g.guest_name}</div>
                  <div className="text-xs text-gray-500">{g.guest_email}</div>
                </div>
                {g.checked_in_at ? (
                  <span className="flex items-center gap-1 text-xs text-emerald-400">
                    <CheckCircle2 className="h-3.5 w-3.5" /> Checked in
                  </span>
                ) : g.ticket_sent_at ? (
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    className="h-7 border-gray-700 text-xs text-gray-300"
                    disabled={resendingId === g.id}
                    onClick={() => handleResend(g.id)}
                  >
                    {resendingId === g.id ? <Loader2 className="h-3 w-3 animate-spin" /> : 'Resend'}
                  </Button>
                ) : (
                  <span className="text-xs text-amber-400">Not sent</span>
                )}
              </div>
            ))}
          </div>
        )}

        {booking.remainingCapacity > 0 ? (
          <div className="space-y-3 rounded-lg border border-gray-800 p-3">
            <p className="text-sm text-white">Send guest tickets</p>
            <p className="text-xs text-gray-500">
              Each guest gets their own QR ticket to check in separately from you.
            </p>
            {drafts.map((draft, i) => (
              <div key={i} className="flex items-center gap-2">
                <div className="flex-1 space-y-1.5">
                  <Input
                    placeholder="Guest name"
                    value={draft.name}
                    onChange={(e) => updateDraft(i, 'name', e.target.value)}
                  />
                  <div className="relative">
                    <Mail className="absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-gray-500" />
                    <Input
                      type="email"
                      placeholder="Guest email"
                      value={draft.email}
                      onChange={(e) => updateDraft(i, 'email', e.target.value)}
                      className="pl-8"
                    />
                  </div>
                </div>
                {drafts.length > 1 && (
                  <Button
                    type="button"
                    size="icon"
                    variant="ghost"
                    className="h-8 w-8 shrink-0 text-gray-500"
                    onClick={() => removeDraftRow(i)}
                  >
                    <X className="h-4 w-4" />
                  </Button>
                )}
              </div>
            ))}

            {drafts.length < booking.remainingCapacity && (
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="w-full border-gray-700 text-gray-300"
                onClick={addDraftRow}
              >
                <Plus className="mr-1 h-3.5 w-3.5" /> Add another guest
              </Button>
            )}

            {overCapacity && (
              <p className="text-xs text-red-400">
                Only {booking.remainingCapacity} guest ticket{booking.remainingCapacity === 1 ? '' : 's'} left for this table.
              </p>
            )}

            <Button
              type="button"
              disabled={submitting || draftCount === 0 || overCapacity}
              className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
              onClick={handleSend}
            >
              {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : (
                <>
                  <Send className="mr-2 h-4 w-4" /> Send Guest Tickets
                </>
              )}
            </Button>
          </div>
        ) : (
          <p className="text-center text-sm text-gray-500">This table's guest list is full.</p>
        )}

        <p className="mt-6 text-center text-xs text-gray-600">
          Want to order bottles for your table?{' '}
          <Link to={`/order/${code}`} className="text-orange-500 hover:underline">
            Order here
          </Link>
        </p>
      </div>
    </div>
  );
};

export default BookingByCode;
