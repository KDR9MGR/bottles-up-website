import { useEffect, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { ArrowLeft, Plus, Wine, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import AddBottlesDialog from '@/components/AddBottlesDialog';
import {
  recordClubPayment,
  uploadReceiptPhoto,
  type ClubPaymentMethod,
  type SplitLeg,
  type SplitLegMethod,
} from '@/lib/clubPayment';
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

  const [showPaymentForm, setShowPaymentForm] = useState(false);
  const [billedAmount, setBilledAmount] = useState('');
  const [paidAmount, setPaidAmount] = useState('');
  const [paymentMethod, setPaymentMethod] = useState<ClubPaymentMethod>('cash');
  const [splitLegs, setSplitLegs] = useState<SplitLeg[]>([{ method: 'cash', amountCents: 0 }]);
  const [posReference, setPosReference] = useState('');
  const [receiptFile, setReceiptFile] = useState<File | null>(null);
  const [recordingPayment, setRecordingPayment] = useState(false);

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

  const resetPaymentForm = () => {
    setShowPaymentForm(false);
    setBilledAmount('');
    setPaidAmount('');
    setPaymentMethod('cash');
    setSplitLegs([{ method: 'cash', amountCents: 0 }]);
    setPosReference('');
    setReceiptFile(null);
  };

  const openPaymentForm = () => {
    const dollars = (balanceDueCents / 100).toFixed(2);
    setBilledAmount(dollars);
    setPaidAmount(dollars);
    setShowPaymentForm(true);
  };

  const updateSplitLeg = (index: number, patch: Partial<SplitLeg>) =>
    setSplitLegs((prev) => prev.map((leg, i) => (i === index ? { ...leg, ...patch } : leg)));
  const addSplitLeg = () => setSplitLegs((prev) => [...prev, { method: 'cash', amountCents: 0 }]);
  const removeSplitLeg = (index: number) => setSplitLegs((prev) => prev.filter((_, i) => i !== index));

  const handleRecordPayment = async () => {
    if (!booking || recordingPayment) return;
    const billedCents = Math.round(parseFloat(billedAmount) * 100);
    const paidCents = Math.round(parseFloat(paidAmount) * 100);
    if (!Number.isFinite(billedCents) || billedCents < 0 || !Number.isFinite(paidCents) || paidCents <= 0) {
      toast({ title: 'Enter a valid amount', variant: 'destructive' });
      return;
    }

    setRecordingPayment(true);
    try {
      let receiptPhotoPath: string | null = null;
      if (receiptFile) {
        receiptPhotoPath = await uploadReceiptPhoto(booking.id, receiptFile);
      }
      const splitBreakdown = paymentMethod === 'split' ? splitLegs.filter((leg) => leg.amountCents > 0) : null;

      const { confirmationEmailSent } = await recordClubPayment({
        bookingId: booking.id,
        billedAmountCents: billedCents,
        amountPaidCents: paidCents,
        paymentMethod,
        splitBreakdown,
        posReference: posReference.trim() || null,
        receiptPhotoPath,
      });

      toast({
        title: 'Payment recorded',
        description: confirmationEmailSent ? 'Customer notified by email.' : 'Could not email the customer - let them know in person.',
      });
      resetPaymentForm();
      load();
    } catch (err) {
      toast({ title: 'Could not record payment', description: err instanceof Error ? err.message : undefined, variant: 'destructive' });
    } finally {
      setRecordingPayment(false);
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
              {showPaymentForm ? (
                <div className="space-y-3">
                  <p className="text-sm font-medium text-white">Record Club Payment</p>

                  <div className="grid grid-cols-2 gap-2">
                    <div className="space-y-1">
                      <Label className="text-xs">Final billed amount</Label>
                      <Input type="number" min="0" step="0.01" value={billedAmount} onChange={(e) => setBilledAmount(e.target.value)} />
                    </div>
                    <div className="space-y-1">
                      <Label className="text-xs">Amount actually paid</Label>
                      <Input type="number" min="0" step="0.01" value={paidAmount} onChange={(e) => setPaidAmount(e.target.value)} />
                    </div>
                  </div>

                  <div className="space-y-1">
                    <Label className="text-xs">Payment method</Label>
                    <Select value={paymentMethod} onValueChange={(v) => setPaymentMethod(v as ClubPaymentMethod)}>
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="cash">Cash</SelectItem>
                        <SelectItem value="debit">Debit</SelectItem>
                        <SelectItem value="credit">Credit</SelectItem>
                        <SelectItem value="split">Split payment</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>

                  {paymentMethod === 'split' && (
                    <div className="space-y-2">
                      {splitLegs.map((leg, i) => (
                        <div key={i} className="flex items-center gap-2">
                          <Select value={leg.method} onValueChange={(v) => updateSplitLeg(i, { method: v as SplitLegMethod })}>
                            <SelectTrigger className="w-28">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="cash">Cash</SelectItem>
                              <SelectItem value="debit">Debit</SelectItem>
                              <SelectItem value="credit">Credit</SelectItem>
                            </SelectContent>
                          </Select>
                          <Input
                            type="number"
                            min="0"
                            step="0.01"
                            placeholder="Amount"
                            value={leg.amountCents ? (leg.amountCents / 100).toString() : ''}
                            onChange={(e) => updateSplitLeg(i, { amountCents: Math.round((parseFloat(e.target.value) || 0) * 100) })}
                          />
                          {splitLegs.length > 1 && (
                            <Button type="button" variant="ghost" size="icon" onClick={() => removeSplitLeg(i)}>
                              <X className="h-4 w-4" />
                            </Button>
                          )}
                        </div>
                      ))}
                      <Button type="button" variant="outline" size="sm" className="border-gray-700" onClick={addSplitLeg}>
                        <Plus className="mr-1 h-3 w-3" /> Add method
                      </Button>
                    </div>
                  )}

                  <div className="space-y-1">
                    <Label className="text-xs">POS receipt / reference number (optional)</Label>
                    <Input value={posReference} onChange={(e) => setPosReference(e.target.value)} />
                  </div>

                  <div className="space-y-1">
                    <Label className="text-xs">Receipt photo (optional)</Label>
                    <Input type="file" accept="image/*" onChange={(e) => setReceiptFile(e.target.files?.[0] ?? null)} />
                  </div>

                  <div className="flex gap-2">
                    <Button variant="outline" className="flex-1 border-gray-700" onClick={resetPaymentForm}>
                      Cancel
                    </Button>
                    <Button
                      className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90"
                      disabled={recordingPayment}
                      onClick={handleRecordPayment}
                    >
                      {recordingPayment ? 'Saving...' : 'Record Payment'}
                    </Button>
                  </div>
                </div>
              ) : (
                <Button
                  variant="outline"
                  className="w-full border-orange-500/40 text-orange-400 hover:bg-orange-500/10"
                  onClick={openPaymentForm}
                >
                  Record Club Payment
                </Button>
              )}
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
