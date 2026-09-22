import { useEffect, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { ArrowLeft, Wine } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import AddBottlesDialog from '@/components/AddBottlesDialog';
import RecordClubPaymentForm from '@/components/RecordClubPaymentForm';
import { getMyProfile, requestTablePayment } from '@/lib/staffDashboard';

const money = (cents: number, currency = 'CAD') => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

interface BottleLine {
  id: string;
  bottle_name: string;
  size: string | null;
  quantity: number;
  line_total_cents: number;
  payment_status: 'paid' | 'due_at_venue' | 'pending_payment';
  service_status: string;
  cancelled_at: string | null;
}

interface BookingDetail {
  found: boolean;
  id: string;
  customer_name: string;
  customer_email: string;
  guest_count: number;
  venue_name: string;
  table_type_name: string;
  booking_date: string;
  status: string;
  checked_in_at: string | null;
  deposit_cents: number;
  amount_total_cents: number;
  amount_paid_cents: number;
  currency: string;
  bottles: BottleLine[];
}

// BottlesUp Server and Pay-at-Club system, section 3: "Open table" - the
// same lookup as section 2, now with the three main buttons: Add Bottles,
// Request Payment, Record Club Payment (only if permitted).
const StaffTableDetail = () => {
  const { code } = useParams<{ code: string }>();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [booking, setBooking] = useState<BookingDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [canRecordPayments, setCanRecordPayments] = useState(false);

  const [addBottlesOpen, setAddBottlesOpen] = useState(false);
  const [requestingPayment, setRequestingPayment] = useState(false);

  const load = async () => {
    if (!code) return;
    setLoading(true);
    const { data, error } = await supabase.rpc('lookup_table_booking_for_checkin', { p_code: code });
    if (error || !data?.found) {
      toast({ title: 'Could not load this table', description: error?.message, variant: 'destructive' });
      setBooking(null);
    } else {
      setBooking(data as BookingDetail);
    }
    setLoading(false);
  };

  useEffect(() => {
    load();
    getMyProfile().then((p) => setCanRecordPayments(!!p?.canRecordPayments));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [code]);

  const balanceDueCents = booking ? Math.max(booking.amount_total_cents - booking.amount_paid_cents, 0) : 0;

  const handleRequestPayment = async () => {
    if (!booking) return;
    setRequestingPayment(true);
    try {
      await requestTablePayment(booking.id);
      toast({ title: 'Payment requested', description: `Ask the customer to pay ${money(balanceDueCents, booking.currency)} at the venue.` });
    } catch (err) {
      toast({ title: 'Could not request payment', description: err instanceof Error ? err.message : undefined, variant: 'destructive' });
    } finally {
      setRequestingPayment(false);
    }
  };

  return (
    <div className="mx-auto max-w-sm px-4 py-6">
      <Button variant="ghost" size="sm" className="mb-3 text-gray-400" onClick={() => navigate('/staff/tables')}>
        <ArrowLeft className="mr-1 h-4 w-4" /> Back to My Tables
      </Button>

      {loading ? (
        <div className="text-center text-gray-400">Loading...</div>
      ) : !booking ? (
        <div className="text-center text-gray-500">Table not found.</div>
      ) : (
        <div className="space-y-4">
          <div className="rounded-2xl border-2 border-gray-800 bg-gray-950 p-4">
            <div className="mb-1 text-lg font-bold text-white">{booking.customer_name}</div>
            <div className="mb-3 text-sm text-gray-400">
              {booking.table_type_name} - {booking.venue_name} · {booking.guest_count} guests
            </div>
            <div className="flex items-center gap-2">
              {booking.checked_in_at ? (
                <Badge variant="outline" className="border-green-600 text-green-400">Checked In</Badge>
              ) : (
                <Badge variant="outline" className="border-gray-700 text-gray-400">Not checked in</Badge>
              )}
              {code && <span className="font-mono text-xs text-gray-500">{code}</span>}
            </div>
          </div>

          <div className="space-y-1.5 rounded-lg border border-gray-800 p-4 text-sm">
            <div className="flex justify-between text-gray-400">
              <span>Table deposit</span>
              <span>{money(booking.deposit_cents, booking.currency)}</span>
            </div>
            <div className="flex justify-between text-gray-400">
              <span>Paid so far</span>
              <span>{money(booking.amount_paid_cents, booking.currency)}</span>
            </div>
            <div className={`flex justify-between font-semibold ${balanceDueCents > 0 ? 'text-orange-400' : 'text-emerald-400'}`}>
              <span>Balance due</span>
              <span>{money(balanceDueCents, booking.currency)}</span>
            </div>
          </div>

          <div className="space-y-2 rounded-lg border border-gray-800 p-4 text-sm">
            <div className="text-xs uppercase tracking-wide text-gray-500">Reserved Bottles</div>
            {booking.bottles.length === 0 && <p className="text-gray-500">No bottles yet.</p>}
            {booking.bottles.map((b) => (
              <div key={b.id} className="flex items-center justify-between gap-2 text-gray-300">
                <span className={b.cancelled_at ? 'text-gray-600 line-through' : ''}>
                  {b.bottle_name}{b.size ? ` (${b.size})` : ''} × {b.quantity}
                </span>
                {b.cancelled_at ? (
                  <Badge variant="outline" className="border-red-700 text-[10px] text-red-400">Cancelled</Badge>
                ) : b.payment_status === 'due_at_venue' ? (
                  <Badge variant="outline" className="border-orange-500/40 text-[10px] text-orange-400">Due at club</Badge>
                ) : (
                  <Badge variant="outline" className="border-gray-700 text-[10px] text-gray-400">{b.service_status}</Badge>
                )}
              </div>
            ))}
          </div>

          {booking.status === 'paid' && (
            <Button type="button" variant="outline" className="w-full border-gray-700" onClick={() => setAddBottlesOpen(true)}>
              <Wine className="mr-2 h-4 w-4" /> Add Bottles
            </Button>
          )}

          {balanceDueCents > 0 && (
            <Button
              type="button"
              variant="outline"
              className="w-full border-gray-700"
              disabled={requestingPayment}
              onClick={handleRequestPayment}
            >
              {requestingPayment ? 'Requesting...' : 'Request Payment'}
            </Button>
          )}

          {canRecordPayments && balanceDueCents > 0 && (
            <div className="rounded-lg border border-orange-500/30 bg-orange-500/5 p-4">
              <RecordClubPaymentForm
                bookingId={booking.id}
                balanceDueCents={balanceDueCents}
                currency={booking.currency}
                customerName={booking.customer_name}
                customerEmail={booking.customer_email}
                onRecorded={() => load()}
              />
            </div>
          )}

          <AddBottlesDialog
            bookingId={booking.id}
            mode="staff"
            open={addBottlesOpen}
            onOpenChange={setAddBottlesOpen}
            onAdded={() => load()}
          />
        </div>
      )}
    </div>
  );
};

export default StaffTableDetail;
