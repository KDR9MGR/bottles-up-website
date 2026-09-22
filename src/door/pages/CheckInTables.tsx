import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { Html5Qrcode } from 'html5-qrcode';
import { CheckCircle2, XCircle, Search, Wine, Plus, X, Receipt, Ban, ShieldAlert } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { doorSignOut } from '../useDoorAuth';
import type { FulfillmentStatus, BottleServiceStatus } from '@/types/database';
import {
  recordClubPayment,
  uploadReceiptPhoto,
  listClubPayments,
  getReceiptSignedUrl,
  type ClubPaymentMethod,
  type ClubPaymentRecord,
  type SplitLeg,
  type SplitLegMethod,
} from '@/lib/clubPayment';
import { updateBottleServiceStatus, BOTTLE_SERVICE_STATUS_LABELS, BOTTLE_SERVICE_STATUSES } from '@/lib/bottleService';
import { cancelBottleLine, flagBottleUnavailable } from '@/lib/bottleExceptions';
import AddBottlesDialog from '@/components/AddBottlesDialog';
import CreateWalkInDialog from '@/components/CreateWalkInDialog';

const READER_ID = 'door-table-qr-reader';
const SAME_CODE_COOLDOWN_MS = 5000;

interface BottleLine {
  id: string;
  bottle_name: string;
  size: string | null;
  quantity: number;
  line_total_cents: number;
  payment_status: 'paid' | 'due_at_venue';
  service_status: BottleServiceStatus;
  cancelled_at: string | null;
  cancellation_reason: string | null;
}

interface BookingLookup {
  found: boolean;
  id: string;
  confirmation_code: string;
  customer_name: string;
  customer_email: string;
  guest_count: number;
  venue_name: string;
  table_type_name: string;
  booking_date: string;
  start_time: string;
  status: string;
  checked_in_at: string | null;
  fulfillment_status: FulfillmentStatus;
  deposit_cents: number;
  deposit_is_credit: boolean;
  amount_total_cents: number;
  amount_paid_cents: number;
  currency: string;
  bottles: BottleLine[];
}

interface SearchHit {
  confirmation_code: string;
  customer_name: string;
  table_type_name: string;
  venue_name: string;
  booking_date: string;
  start_time: string;
  checked_in_at: string | null;
}

const FULFILLMENT_LABELS: Record<FulfillmentStatus, string> = {
  confirmed: 'Confirmed',
  preparing: 'Preparing',
  served: 'Served',
  completed: 'Completed',
};

const money = (cents: number, currency: string) => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

const CheckInTables = () => {
  const { toast } = useToast();
  const scannerRef = useRef<Html5Qrcode | null>(null);
  const busyRef = useRef(false);
  const pausedRef = useRef(false);
  const lastCodeRef = useRef<{ code: string; at: number } | null>(null);
  const [cameraError, setCameraError] = useState<string | null>(null);
  const [manualCode, setManualCode] = useState('');
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState<SearchHit[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [looking, setLooking] = useState(false);
  const [lookupError, setLookupError] = useState<string | null>(null);
  const [booking, setBooking] = useState<BookingLookup | null>(null);
  const [checkingIn, setCheckingIn] = useState(false);
  const [paymentHistory, setPaymentHistory] = useState<ClubPaymentRecord[]>([]);
  const [showPaymentForm, setShowPaymentForm] = useState(false);
  const [billedAmount, setBilledAmount] = useState('');
  const [paidAmount, setPaidAmount] = useState('');
  const [paymentMethod, setPaymentMethod] = useState<ClubPaymentMethod>('cash');
  const [splitLegs, setSplitLegs] = useState<SplitLeg[]>([{ method: 'cash', amountCents: 0 }]);
  const [posReference, setPosReference] = useState('');
  const [receiptFile, setReceiptFile] = useState<File | null>(null);
  const [recordingPayment, setRecordingPayment] = useState(false);
  const [addBottlesOpen, setAddBottlesOpen] = useState(false);
  const [walkInOpen, setWalkInOpen] = useState(false);
  const [cancellingLineId, setCancellingLineId] = useState<string | null>(null);
  const [cancelLineReason, setCancelLineReason] = useState('');
  const [cancellingLine, setCancellingLine] = useState(false);
  const [flaggingLineId, setFlaggingLineId] = useState<string | null>(null);
  const [flagReason, setFlagReason] = useState('');
  const [flaggingLine, setFlaggingLine] = useState(false);

  const runLookup = async (code: string) => {
    if (!code.trim() || busyRef.current) return;
    busyRef.current = true;
    pausedRef.current = true;
    setLooking(true);
    setLookupError(null);
    const { data, error } = await supabase.rpc('lookup_table_booking_for_checkin', { p_code: code.trim() });
    setLooking(false);
    busyRef.current = false;

    if (error) {
      setLookupError(/not authorized/i.test(error.message ?? '') ? 'Your session expired - sign in again.' : 'Lookup failed - try again.');
      return;
    }
    const result = data as BookingLookup;
    if (!result?.found) {
      setLookupError('No booking found for that code.');
      return;
    }
    setSearchResults(null);
    setBooking(result);
    listClubPayments(result.id)
      .then(setPaymentHistory)
      .catch(() => setPaymentHistory([]));
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
      const splitBreakdown =
        paymentMethod === 'split' ? splitLegs.filter((leg) => leg.amountCents > 0) : null;

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
      runLookup(booking.confirmation_code);
    } catch (err) {
      toast({
        title: 'Could not record payment',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setRecordingPayment(false);
    }
  };

  const handleViewReceipt = async (path: string) => {
    const url = await getReceiptSignedUrl(path);
    if (url) window.open(url, '_blank', 'noopener,noreferrer');
    else toast({ title: 'Could not open receipt', variant: 'destructive' });
  };

  const handleServiceStatusChange = async (bottleLineId: string, status: BottleServiceStatus) => {
    if (!booking) return;
    // Optimistic - staff move through these quickly during service, and it's
    // easy to correct with another tap if something goes wrong.
    setBooking((prev) =>
      prev
        ? { ...prev, bottles: prev.bottles.map((b) => (b.id === bottleLineId ? { ...b, service_status: status } : b)) }
        : prev,
    );
    try {
      await updateBottleServiceStatus(bottleLineId, status);
    } catch (err) {
      toast({
        title: 'Could not update service status',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
      runLookup(booking.confirmation_code);
    }
  };

  useEffect(() => {
    const scanner = new Html5Qrcode(READER_ID);
    scannerRef.current = scanner;

    scanner
      .start(
        { facingMode: 'environment' },
        { fps: 10, qrbox: { width: 250, height: 250 } },
        (decodedText) => {
          if (busyRef.current || pausedRef.current) return;
          const last = lastCodeRef.current;
          if (last && last.code === decodedText && Date.now() - last.at < SAME_CODE_COOLDOWN_MS) return;
          lastCodeRef.current = { code: decodedText, at: Date.now() };
          runLookup(decodedText);
        },
        () => {
          // per-frame decode miss - expected while the camera searches, not an error
        },
      )
      .catch((err) => {
        setCameraError(err instanceof Error ? err.message : 'Could not access the camera. Use search or manual entry below.');
      });

    return () => {
      scanner.stop().then(() => scanner.clear()).catch(() => {});
    };
  }, []);

  const handleManualSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    runLookup(manualCode);
    setManualCode('');
  };

  const handleSearchSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!searchQuery.trim()) return;
    setSearching(true);
    setLookupError(null);
    const { data, error } = await supabase.rpc('search_table_bookings_for_checkin', { p_query: searchQuery.trim() });
    setSearching(false);
    if (error) {
      setLookupError('Search failed - try again.');
      return;
    }
    setSearchResults((data as SearchHit[]) ?? []);
  };

  const handleCheckIn = async () => {
    if (!booking || checkingIn) return;
    setCheckingIn(true);
    const { data, error } = await supabase.rpc('checkin_ticket', { p_ticket_code: booking.confirmation_code });
    setCheckingIn(false);

    if (error) {
      toast({ title: 'Check-in failed', description: error.message, variant: 'destructive' });
      return;
    }
    const outcome = data?.[0]?.result;
    if (outcome === 'ok') {
      toast({ title: 'Checked in', description: `${booking.customer_name} is in.` });
    } else if (outcome === 'already_checked_in') {
      toast({ title: 'Already checked in' });
    } else if (outcome === 'expired') {
      toast({ title: 'This booking has expired', variant: 'destructive' });
    } else if (outcome === 'not_paid') {
      toast({ title: 'This booking is not paid', variant: 'destructive' });
    }
    // Refresh from the source of truth rather than assuming the RPC's outcome
    // maps 1:1 onto what changed - re-lookup shows exactly what's on the row now.
    runLookup(booking.confirmation_code);
  };

  const scanNext = () => {
    pausedRef.current = false;
    setBooking(null);
    setLookupError(null);
    setSearchResults(null);
    setPaymentHistory([]);
    resetPaymentForm();
  };

  const handleCancelLine = async (lineId: string) => {
    if (!cancelLineReason.trim()) {
      toast({ title: 'A reason is required', variant: 'destructive' });
      return;
    }
    setCancellingLine(true);
    try {
      const result = await cancelBottleLine(lineId, cancelLineReason.trim());
      toast({
        title: 'Item cancelled',
        description: result.refundSuggested ? 'This item was already paid - a manager can record a refund in the CMS.' : undefined,
      });
      setCancellingLineId(null);
      setCancelLineReason('');
      if (booking) runLookup(booking.confirmation_code);
    } catch (err) {
      toast({ title: 'Could not cancel item', description: err instanceof Error ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setCancellingLine(false);
    }
  };

  const handleFlagUnavailable = async (lineId: string) => {
    if (!flagReason.trim()) {
      toast({ title: 'A reason is required', variant: 'destructive' });
      return;
    }
    setFlaggingLine(true);
    try {
      const result = await flagBottleUnavailable({ bottleLineId: lineId, reason: flagReason.trim() });
      toast({
        title: 'Customer notified',
        description: result.emailSent ? 'Waiting for their approval.' : 'Could not email the customer - follow up directly.',
      });
      setFlaggingLineId(null);
      setFlagReason('');
    } catch (err) {
      toast({ title: 'Could not flag this item', description: err instanceof Error ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setFlaggingLine(false);
    }
  };

  const paidOnline = booking?.bottles.filter((b) => b.payment_status === 'paid' && !b.cancelled_at) ?? [];
  const awaitingClub = booking?.bottles.filter((b) => b.payment_status === 'due_at_venue' && !b.cancelled_at) ?? [];
  const cancelledBottles = booking?.bottles.filter((b) => b.cancelled_at) ?? [];
  const balanceDueCents = booking ? Math.max(booking.amount_total_cents - booking.amount_paid_cents, 0) : 0;

  return (
    <div className="flex min-h-screen flex-col items-center bg-black px-4 py-8">
      <div className="mb-4 flex w-full max-w-sm items-center justify-between">
        <div>
          <h1 className="text-xl font-bold text-white">Table Check-In</h1>
          <Link to="/door/scan" className="text-xs text-gray-500 hover:text-gray-300">
            Switch to Scan Tickets
          </Link>
        </div>
        <Button variant="ghost" size="sm" className="text-gray-400" onClick={() => doorSignOut()}>
          Sign out
        </Button>
      </div>

      {booking ? (
        <div className="w-full max-w-sm space-y-4">
          <div className="rounded-2xl border-2 border-gray-800 bg-gray-950 p-5">
            <div className="mb-3 flex items-center justify-between">
              <div>
                <div className="text-lg font-bold text-white">{booking.customer_name}</div>
                <div className="text-xs text-gray-500">{booking.customer_email}</div>
              </div>
              {booking.checked_in_at ? (
                <Badge variant="outline" className="border-green-600 text-green-400">
                  Checked In
                </Badge>
              ) : (
                <Badge variant="outline" className="border-gray-700 text-gray-400">
                  Not checked in
                </Badge>
              )}
            </div>

            <div className="mb-3 space-y-1 text-sm text-gray-300">
              <div>{booking.table_type_name} - {booking.venue_name}</div>
              <div className="text-gray-500">{booking.guest_count} guests · Confirmation {booking.confirmation_code}</div>
              <div className="flex items-center gap-2">
                <span className="text-gray-500">Service status:</span>
                <Badge variant="outline" className="border-gray-700 text-gray-300">
                  {FULFILLMENT_LABELS[booking.fulfillment_status]}
                </Badge>
              </div>
            </div>

            <div className="space-y-2 rounded-lg border border-gray-800 p-3 text-sm">
              <div className="flex justify-between text-gray-300">
                <span>
                  Table deposit
                  {booking.deposit_is_credit && (
                    <span className="ml-1 text-xs text-gray-500">(credited toward bottle bill)</span>
                  )}
                </span>
                <span>{money(booking.deposit_cents, booking.currency)}</span>
              </div>

              {paidOnline.length > 0 && (
                <div>
                  <div className="mt-2 flex items-center gap-1.5 text-xs uppercase tracking-wide text-gray-500">
                    <Wine className="h-3 w-3" /> Paid Online
                  </div>
                  {paidOnline.map((b) => (
                    <div key={b.id} className="flex items-center justify-between gap-2 py-0.5 text-gray-300">
                      <span className="flex-1">{b.bottle_name}{b.size ? ` (${b.size})` : ''} × {b.quantity}</span>
                      <span>{money(b.line_total_cents, booking.currency)}</span>
                      <Select value={b.service_status} onValueChange={(v) => handleServiceStatusChange(b.id, v as BottleServiceStatus)}>
                        <SelectTrigger className="h-7 w-[100px] text-xs">
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {BOTTLE_SERVICE_STATUSES.map((s) => (
                            <SelectItem key={s} value={s}>{BOTTLE_SERVICE_STATUS_LABELS[s]}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                      <Button type="button" variant="ghost" size="icon" className="h-6 w-6 text-amber-400" onClick={() => { setFlaggingLineId((v) => (v === b.id ? null : b.id)); setCancellingLineId(null); }}>
                        <ShieldAlert className="h-3.5 w-3.5" />
                      </Button>
                      <Button type="button" variant="ghost" size="icon" className="h-6 w-6 text-red-400" onClick={() => { setCancellingLineId((v) => (v === b.id ? null : b.id)); setFlaggingLineId(null); }}>
                        <Ban className="h-3.5 w-3.5" />
                      </Button>
                    </div>
                  ))}
                </div>
              )}

              {awaitingClub.length > 0 && (
                <div>
                  <div className="mt-2 flex items-center gap-1.5 text-xs uppercase tracking-wide text-orange-500">
                    <Wine className="h-3 w-3" /> Awaiting Club Payment
                  </div>
                  {awaitingClub.map((b) => (
                    <div key={b.id} className="flex items-center justify-between gap-2 py-0.5 text-orange-300">
                      <span className="flex-1">{b.bottle_name}{b.size ? ` (${b.size})` : ''} × {b.quantity}</span>
                      <span>{money(b.line_total_cents, booking.currency)}</span>
                      <Select value={b.service_status} onValueChange={(v) => handleServiceStatusChange(b.id, v as BottleServiceStatus)}>
                        <SelectTrigger className="h-7 w-[100px] text-xs">
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {BOTTLE_SERVICE_STATUSES.map((s) => (
                            <SelectItem key={s} value={s}>{BOTTLE_SERVICE_STATUS_LABELS[s]}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                      <Button type="button" variant="ghost" size="icon" className="h-6 w-6 text-amber-400" onClick={() => { setFlaggingLineId((v) => (v === b.id ? null : b.id)); setCancellingLineId(null); }}>
                        <ShieldAlert className="h-3.5 w-3.5" />
                      </Button>
                      <Button type="button" variant="ghost" size="icon" className="h-6 w-6 text-red-400" onClick={() => { setCancellingLineId((v) => (v === b.id ? null : b.id)); setFlaggingLineId(null); }}>
                        <Ban className="h-3.5 w-3.5" />
                      </Button>
                    </div>
                  ))}
                </div>
              )}

              {cancelledBottles.length > 0 && (
                <div>
                  <div className="mt-2 flex items-center gap-1.5 text-xs uppercase tracking-wide text-gray-600">
                    <Ban className="h-3 w-3" /> Cancelled
                  </div>
                  {cancelledBottles.map((b) => (
                    <div key={b.id} className="py-0.5 text-xs text-gray-500 line-through">
                      {b.bottle_name}{b.size ? ` (${b.size})` : ''} × {b.quantity}
                      <span className="ml-1 no-underline">- {b.cancellation_reason}</span>
                    </div>
                  ))}
                </div>
              )}

              {(cancellingLineId || flaggingLineId) && (
                <div className={`mt-2 space-y-2 rounded-lg border p-3 ${cancellingLineId ? 'border-red-900/50 bg-red-950/10' : 'border-amber-900/50 bg-amber-950/10'}`}>
                  {cancellingLineId ? (
                    <>
                      <Label className="text-xs text-red-300">Why is this item being cancelled?</Label>
                      <Textarea value={cancelLineReason} onChange={(e) => setCancelLineReason(e.target.value)} />
                      <div className="flex gap-2">
                        <Button variant="outline" size="sm" className="flex-1 border-gray-700" onClick={() => setCancellingLineId(null)}>
                          Back
                        </Button>
                        <Button size="sm" className="flex-1 bg-red-600 text-white hover:bg-red-700" disabled={cancellingLine} onClick={() => handleCancelLine(cancellingLineId)}>
                          {cancellingLine ? 'Cancelling...' : 'Cancel Item'}
                        </Button>
                      </div>
                    </>
                  ) : (
                    <>
                      <Label className="text-xs text-amber-300">Why is this item unavailable? (Customer will be offered removal)</Label>
                      <Textarea value={flagReason} onChange={(e) => setFlagReason(e.target.value)} />
                      <div className="flex gap-2">
                        <Button variant="outline" size="sm" className="flex-1 border-gray-700" onClick={() => setFlaggingLineId(null)}>
                          Back
                        </Button>
                        <Button size="sm" className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90" disabled={flaggingLine} onClick={() => handleFlagUnavailable(flaggingLineId!)}>
                          {flaggingLine ? 'Sending...' : 'Notify Customer'}
                        </Button>
                      </div>
                    </>
                  )}
                </div>
              )}

              <div
                className={`flex justify-between border-t border-gray-800 pt-2 font-semibold ${balanceDueCents > 0 ? 'text-orange-400' : 'text-emerald-400'}`}
              >
                <span>Remaining balance</span>
                <span>{money(balanceDueCents, booking.currency)}</span>
              </div>
            </div>
          </div>

          {paymentHistory.length > 0 && (
            <div className="space-y-1.5 rounded-2xl border border-gray-800 bg-gray-950 p-4 text-sm">
              <div className="text-xs uppercase tracking-wide text-gray-500">Club Payments Recorded</div>
              {paymentHistory.map((p) => (
                <div key={p.id} className="flex items-center justify-between text-gray-300">
                  <span>
                    {money(p.amountPaidCents, booking.currency)} · {p.paymentMethod}
                    {p.posReference ? ` · ${p.posReference}` : ''}
                  </span>
                  <div className="flex items-center gap-2">
                    {p.customerConfirmationStatus === 'confirmed' && (
                      <Badge variant="outline" className="border-green-600 text-[10px] text-green-400">Confirmed</Badge>
                    )}
                    {p.customerConfirmationStatus === 'disputed' && (
                      <Badge variant="outline" className="border-red-600 text-[10px] text-red-400">Disputed</Badge>
                    )}
                    {p.customerConfirmationStatus === 'pending' && (
                      <Badge variant="outline" className="border-gray-700 text-[10px] text-gray-500">Awaiting customer</Badge>
                    )}
                    {p.receiptPhotoPath && (
                      <button
                        type="button"
                        className="flex items-center gap-1 text-xs text-gray-500 hover:text-gray-300"
                        onClick={() => handleViewReceipt(p.receiptPhotoPath!)}
                      >
                        <Receipt className="h-3 w-3" /> Receipt
                      </button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}

          {balanceDueCents > 0 && booking.status === 'paid' && (
            <div className="rounded-2xl border border-orange-500/30 bg-orange-500/5 p-4">
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
                            onChange={(e) =>
                              updateSplitLeg(i, { amountCents: Math.round((parseFloat(e.target.value) || 0) * 100) })
                            }
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
                    <Input
                      type="file"
                      accept="image/*"
                      onChange={(e) => setReceiptFile(e.target.files?.[0] ?? null)}
                    />
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

          {booking.status === 'paid' && (
            <Button
              type="button"
              variant="outline"
              className="w-full border-gray-700"
              onClick={() => setAddBottlesOpen(true)}
            >
              <Wine className="mr-2 h-4 w-4" /> Add Bottles
            </Button>
          )}

          {booking.checked_in_at ? (
            <div className="rounded-2xl border-2 border-green-600 bg-green-950 p-4 text-center text-green-400">
              <CheckCircle2 className="mx-auto mb-2 h-8 w-8" />
              Checked in
            </div>
          ) : booking.status !== 'paid' ? (
            <div className="rounded-2xl border-2 border-red-600 bg-red-950 p-4 text-center text-red-400">
              <XCircle className="mx-auto mb-2 h-8 w-8" />
              This booking is not paid
            </div>
          ) : (
            <Button
              className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
              disabled={checkingIn}
              onClick={handleCheckIn}
            >
              {checkingIn ? 'Checking in...' : 'Check In'}
            </Button>
          )}

          <Button variant="outline" className="w-full border-gray-700 text-gray-300" onClick={scanNext}>
            Scan Next
          </Button>
        </div>
      ) : (
        <div className="w-full max-w-sm">
          <Button
            type="button"
            variant="outline"
            className="mb-4 w-full border-gray-700 text-gray-300"
            onClick={() => setWalkInOpen(true)}
          >
            New Walk-In
          </Button>

          <div id={READER_ID} className="overflow-hidden rounded-2xl border border-gray-800" />
          {cameraError && <p className="mt-3 text-center text-sm text-amber-400">{cameraError}</p>}
          {looking && <p className="mt-3 text-center text-sm text-gray-400">Looking up...</p>}
          {lookupError && <p className="mt-3 text-center text-sm text-red-400">{lookupError}</p>}

          <form onSubmit={handleManualSubmit} className="mt-6 flex gap-2">
            <Input
              placeholder="Or enter confirmation code"
              value={manualCode}
              onChange={(e) => setManualCode(e.target.value)}
              className="font-mono"
            />
            <Button type="submit" disabled={looking || !manualCode.trim()}>
              Check
            </Button>
          </form>

          <form onSubmit={handleSearchSubmit} className="mt-3 flex gap-2">
            <Input
              placeholder="Or search by name/email"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
            />
            <Button type="submit" variant="outline" className="border-gray-700" disabled={searching || !searchQuery.trim()}>
              <Search className="h-4 w-4" />
            </Button>
          </form>

          {searchResults && (
            <div className="mt-3 space-y-2">
              {searchResults.length === 0 ? (
                <p className="text-center text-sm text-gray-500">No matches.</p>
              ) : (
                searchResults.map((hit) => (
                  <button
                    key={hit.confirmation_code}
                    type="button"
                    onClick={() => runLookup(hit.confirmation_code)}
                    className="flex w-full items-center justify-between rounded-lg border border-gray-800 p-3 text-left hover:border-gray-600"
                  >
                    <div>
                      <div className="text-sm font-medium text-white">{hit.customer_name}</div>
                      <div className="text-xs text-gray-500">
                        {hit.table_type_name} - {hit.venue_name}
                      </div>
                    </div>
                    {hit.checked_in_at ? (
                      <Badge variant="outline" className="border-green-600 text-green-400 text-[10px]">
                        In
                      </Badge>
                    ) : null}
                  </button>
                ))
              )}
            </div>
          )}
        </div>
      )}

      {booking && (
        <AddBottlesDialog
          bookingId={booking.id}
          mode="staff"
          open={addBottlesOpen}
          onOpenChange={setAddBottlesOpen}
          onAdded={() => runLookup(booking.confirmation_code)}
        />
      )}

      <CreateWalkInDialog open={walkInOpen} onOpenChange={setWalkInOpen} onCreated={(code) => runLookup(code)} />
    </div>
  );
};

export default CheckInTables;
