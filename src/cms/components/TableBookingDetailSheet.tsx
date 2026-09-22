import { Fragment, useEffect, useMemo, useState } from 'react';
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Plus, Wine, X, Receipt, Ban, ShieldAlert, RotateCcw } from 'lucide-react';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import AddBottlesDialog from '@/components/AddBottlesDialog';
import RecordClubPaymentForm from '@/components/RecordClubPaymentForm';
import {
  correctClubPayment,
  managerVerifyClubPayment,
  listClubPayments,
  getReceiptSignedUrl,
  derivePaymentStatus,
  PAYMENT_STATUS_LABELS,
  type ClubPaymentMethod,
  type ClubPaymentRecord,
} from '@/lib/clubPayment';
import {
  cancelBottleLine,
  cancelTableBooking,
  flagBottleUnavailable,
  refundBookingPayment,
} from '@/lib/bottleExceptions';
import { updateBottleServiceStatus, BOTTLE_SERVICE_STATUS_LABELS, BOTTLE_SERVICE_STATUSES } from '@/lib/bottleService';
import type { Database, OrderStatus, BottleServiceStatus } from '@/types/database';

type BookingRow = Database['public']['Tables']['site_table_bookings']['Row'] & {
  site_venues: { id: string; name: string; tax_rate_bps: number } | null;
  site_table_types: { name: string } | null;
  site_venue_time_slots: { start_time: string } | null;
};

type BottleLine = Database['public']['Tables']['site_table_booking_bottles']['Row'];

const statusVariant: Record<OrderStatus, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  paid: 'default',
  pending: 'secondary',
  failed: 'destructive',
  refunded: 'destructive',
  cancelled: 'outline',
};

const money = (cents: number, currency = 'CAD') => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

interface TableBookingDetailSheetProps {
  bookingId: string | null;
  onOpenChange: (open: boolean) => void;
  onUpdated: () => void;
}

const TableBookingDetailSheet = ({ bookingId, onOpenChange, onUpdated }: TableBookingDetailSheetProps) => {
  const { toast } = useToast();
  const [booking, setBooking] = useState<BookingRow | null>(null);
  const [bottleLines, setBottleLines] = useState<BottleLine[]>([]);
  const [bottlesUpFeeBps, setBottlesUpFeeBps] = useState(0);
  const [loading, setLoading] = useState(false);
  const [addBottlesOpen, setAddBottlesOpen] = useState(false);
  const [paymentHistory, setPaymentHistory] = useState<ClubPaymentRecord[]>([]);

  const [venueBottles, setVenueBottles] = useState<{ id: string; name: string; size: string | null; price_cents: number }[]>([]);

  const [cancellingLineId, setCancellingLineId] = useState<string | null>(null);
  const [cancelLineReason, setCancelLineReason] = useState('');
  const [cancellingLine, setCancellingLine] = useState(false);

  const [flaggingLineId, setFlaggingLineId] = useState<string | null>(null);
  const [flagReason, setFlagReason] = useState('');
  const [flagReplacementId, setFlagReplacementId] = useState('');
  const [flaggingLine, setFlaggingLine] = useState(false);

  const [correctingPaymentId, setCorrectingPaymentId] = useState<string | null>(null);
  const [correctBilled, setCorrectBilled] = useState('');
  const [correctPaid, setCorrectPaid] = useState('');
  const [correctMethod, setCorrectMethod] = useState<ClubPaymentMethod>('cash');
  const [correctReason, setCorrectReason] = useState('');
  const [correcting, setCorrecting] = useState(false);
  const [verifyingPaymentId, setVerifyingPaymentId] = useState<string | null>(null);

  const [refundOpen, setRefundOpen] = useState(false);
  const [refundType, setRefundType] = useState<'online' | 'club'>('online');
  const [refundAmount, setRefundAmount] = useState('');
  const [refundReason, setRefundReason] = useState('');
  const [refundPosReference, setRefundPosReference] = useState('');
  const [refunding, setRefunding] = useState(false);

  const [cancelBookingOpen, setCancelBookingOpen] = useState(false);
  const [cancelBookingReason, setCancelBookingReason] = useState('');
  const [cancellingBooking, setCancellingBooking] = useState(false);

  const load = async () => {
    if (!bookingId) return;
    setLoading(true);

    const [{ data: bookingData }, { data: linesData }, { data: contentData }] = await Promise.all([
      supabase
        .from('site_table_bookings')
        .select('*, site_venues(id, name, tax_rate_bps), site_table_types(name), site_venue_time_slots(start_time)')
        .eq('id', bookingId)
        .single(),
      supabase
        .from('site_table_booking_bottles')
        .select('*')
        .eq('booking_id', bookingId)
        .order('created_at', { ascending: true }),
      supabase.from('site_content').select('bottlesup_fee_bps').eq('id', 1).maybeSingle(),
    ]);

    const loadedBooking = bookingData as BookingRow | null;
    setBooking(loadedBooking);
    setBottleLines((linesData as BottleLine[]) ?? []);
    setBottlesUpFeeBps(contentData?.bottlesup_fee_bps ?? 0);

    if (loadedBooking) {
      listClubPayments(loadedBooking.id)
        .then(setPaymentHistory)
        .catch(() => setPaymentHistory([]));
      supabase
        .from('site_bottles')
        .select('id, name, size, price_cents')
        .eq('venue_id', loadedBooking.venue_id)
        .eq('is_available', true)
        .eq('is_sold_out', false)
        .then(({ data }) => setVenueBottles(data ?? []));
    }

    setLoading(false);
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bookingId]);

  // Same formula as create-table-booking-checkout: tax and the platform fee are
  // percentages of (deposit + bottles - discount), recomputed here so the total
  // always reflects every bottle ever added - discount_cents itself never changes
  // after the original checkout, it was resolved to a fixed amount then.
  //
  // Bottles flagged due_at_venue (a pay-at-club checkout, or anything staff
  // added via "Add Bottles" - section 8 always settles those the same way)
  // were never taxed or charged through Stripe - only the deposit was - so
  // they're excluded from the taxed subtotal and added back in untaxed.
  // pending_payment lines (a customer's own in-progress addon checkout) aren't
  // billed to anyone yet, so they're excluded from every total until the webhook
  // confirms them - never counted as already collected or already due.
  const totals = useMemo(() => {
    if (!booking) return null;
    // Section 9: a cancelled line is preserved for history but excluded from
    // every total, same as the server-side recomputeTableBookingTotals().
    const dueAtVenueBottleCents = bottleLines
      .filter((l) => l.payment_status === 'due_at_venue' && !l.cancelled_at)
      .reduce((sum, l) => sum + l.line_total_cents, 0);
    const taxedBottleCents = bottleLines
      .filter((l) => l.payment_status === 'paid' && !l.cancelled_at)
      .reduce((sum, l) => sum + l.line_total_cents, 0);
    const bottleSubtotalCents = taxedBottleCents + dueAtVenueBottleCents;
    const preTax = booking.deposit_cents + taxedBottleCents;
    const discounted = Math.max(preTax - booking.discount_cents, 0);
    const taxRateBps = booking.site_venues?.tax_rate_bps ?? 0;
    const taxCents = Math.round((discounted * taxRateBps) / 10000);
    const feeCents = Math.round((discounted * bottlesUpFeeBps) / 10000);
    const totalCents = discounted + taxCents + feeCents + dueAtVenueBottleCents;
    const balanceDueCents = Math.max(totalCents - booking.amount_paid_cents, 0);
    return { bottleSubtotalCents, taxCents, feeCents, totalCents, balanceDueCents };
  }, [booking, bottleLines, bottlesUpFeeBps]);

  const paymentStatus = totals ? derivePaymentStatus(totals.balanceDueCents, paymentHistory) : null;

  const handleViewReceipt = async (path: string) => {
    const url = await getReceiptSignedUrl(path);
    if (url) window.open(url, '_blank', 'noopener,noreferrer');
    else toast({ title: 'Could not open receipt', variant: 'destructive' });
  };

  const handleServiceStatusChange = async (lineId: string, status: BottleServiceStatus) => {
    setBottleLines((prev) => prev.map((l) => (l.id === lineId ? { ...l, service_status: status } : l)));
    try {
      await updateBottleServiceStatus(lineId, status);
    } catch (err) {
      toast({
        title: 'Could not update service status',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
      load();
    }
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
        description: result.refundSuggested ? 'This item was already paid - consider recording a refund below.' : undefined,
      });
      setCancellingLineId(null);
      setCancelLineReason('');
      onUpdated();
      load();
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
      const result = await flagBottleUnavailable({ bottleLineId: lineId, reason: flagReason.trim(), replacementBottleId: flagReplacementId || null });
      toast({
        title: 'Customer notified',
        description: result.emailSent ? 'Waiting for their approval.' : 'Could not email the customer - follow up directly.',
      });
      setFlaggingLineId(null);
      setFlagReason('');
      setFlagReplacementId('');
    } catch (err) {
      toast({ title: 'Could not flag this item', description: err instanceof Error ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setFlaggingLine(false);
    }
  };

  const handleCorrectPayment = async (originalId: string) => {
    const billedCents = Math.round(parseFloat(correctBilled) * 100);
    const paidCents = Math.round(parseFloat(correctPaid) * 100);
    if (!Number.isFinite(billedCents) || billedCents < 0 || !Number.isFinite(paidCents) || paidCents < 0) {
      toast({ title: 'Enter valid amounts', variant: 'destructive' });
      return;
    }
    if (!correctReason.trim()) {
      toast({ title: 'A reason is required', variant: 'destructive' });
      return;
    }
    setCorrecting(true);
    try {
      const { confirmationEmailSent } = await correctClubPayment({
        originalPaymentId: originalId,
        billedAmountCents: billedCents,
        amountPaidCents: paidCents,
        paymentMethod: correctMethod,
        reason: correctReason.trim(),
      });
      toast({
        title: 'Correction recorded',
        description: confirmationEmailSent ? 'The customer has been asked to reconfirm the corrected details.' : 'Could not email the customer.',
      });
      setCorrectingPaymentId(null);
      setCorrectBilled('');
      setCorrectPaid('');
      setCorrectReason('');
      onUpdated();
      load();
    } catch (err) {
      toast({ title: 'Could not record correction', description: err instanceof Error ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setCorrecting(false);
    }
  };

  const handleManagerVerify = async (paymentId: string) => {
    setVerifyingPaymentId(paymentId);
    try {
      await managerVerifyClubPayment(paymentId);
      toast({ title: 'Marked as manager-verified', description: 'The record still shows the customer never responded.' });
      load();
    } catch (err) {
      toast({ title: 'Could not verify', description: err instanceof Error ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setVerifyingPaymentId(null);
    }
  };

  const handleRefund = async () => {
    if (!booking) return;
    const amountCents = Math.round(parseFloat(refundAmount) * 100);
    if (!Number.isFinite(amountCents) || amountCents <= 0) {
      toast({ title: 'Enter a valid amount', variant: 'destructive' });
      return;
    }
    if (!refundReason.trim()) {
      toast({ title: 'A reason is required', variant: 'destructive' });
      return;
    }
    setRefunding(true);
    try {
      await refundBookingPayment({
        bookingId: booking.id,
        refundType,
        amountCents,
        reason: refundReason.trim(),
        posReference: refundPosReference.trim() || null,
      });
      toast({ title: 'Refund recorded' });
      setRefundOpen(false);
      setRefundAmount('');
      setRefundReason('');
      setRefundPosReference('');
      onUpdated();
      load();
    } catch (err) {
      toast({ title: 'Could not record refund', description: err instanceof Error ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setRefunding(false);
    }
  };

  const handleCancelBooking = async () => {
    if (!booking) return;
    if (!cancelBookingReason.trim()) {
      toast({ title: 'A reason is required', variant: 'destructive' });
      return;
    }
    setCancellingBooking(true);
    try {
      const result = await cancelTableBooking(booking.id, cancelBookingReason.trim());
      toast({
        title: 'Booking cancelled',
        description: result.refundSuggested ? 'Consider recording a refund for any amount already paid.' : undefined,
      });
      setCancelBookingOpen(false);
      setCancelBookingReason('');
      onUpdated();
      load();
    } catch (err) {
      toast({ title: 'Could not cancel booking', description: err instanceof Error ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setCancellingBooking(false);
    }
  };

  return (
    <Sheet open={!!bookingId} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="w-full overflow-y-auto border-gray-800 bg-gray-950 sm:max-w-xl">
        {loading || !booking || !totals ? (
          <div className="flex h-40 items-center justify-center text-gray-400">Loading...</div>
        ) : (
          <>
            <SheetHeader>
              <SheetTitle className="text-white">{booking.customer_name}</SheetTitle>
            </SheetHeader>

            <div className="space-y-6 pb-6 pt-4">
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant={statusVariant[booking.status]}>{booking.status}</Badge>
                <span className="text-sm text-gray-400">{booking.customer_email}</span>
                {booking.customer_phone && <span className="text-sm text-gray-500">- {booking.customer_phone}</span>}
                {booking.status !== 'cancelled' && (
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    className="ml-auto h-7 text-xs text-red-400 hover:bg-red-950/40 hover:text-red-300"
                    onClick={() => setCancelBookingOpen((v) => !v)}
                  >
                    <Ban className="mr-1 h-3 w-3" /> Cancel Booking
                  </Button>
                )}
              </div>

              {cancelBookingOpen && (
                <div className="space-y-2 rounded-lg border border-red-900/50 bg-red-950/20 p-3">
                  <Label className="text-xs text-red-300">Reason for cancelling this booking</Label>
                  <Textarea value={cancelBookingReason} onChange={(e) => setCancelBookingReason(e.target.value)} />
                  <div className="flex gap-2">
                    <Button variant="outline" size="sm" className="flex-1 border-gray-700" onClick={() => setCancelBookingOpen(false)}>
                      Back
                    </Button>
                    <Button
                      size="sm"
                      className="flex-1 bg-red-600 text-white hover:bg-red-700"
                      disabled={cancellingBooking}
                      onClick={handleCancelBooking}
                    >
                      {cancellingBooking ? 'Cancelling...' : 'Confirm Cancellation'}
                    </Button>
                  </div>
                </div>
              )}

              <div className="grid grid-cols-2 gap-3 rounded-lg border border-gray-800 p-4 text-sm">
                <div>
                  <div className="text-xs text-gray-500">Venue</div>
                  <div className="text-white">{booking.site_venues?.name ?? '-'}</div>
                </div>
                <div>
                  <div className="text-xs text-gray-500">Table</div>
                  <div className="text-white">{booking.site_table_types?.name ?? '-'}</div>
                </div>
                <div>
                  <div className="text-xs text-gray-500">Date</div>
                  <div className="text-white">{booking.booking_date}</div>
                </div>
                <div>
                  <div className="text-xs text-gray-500">Guests</div>
                  <div className="text-white">{booking.guest_count}</div>
                </div>
                <div>
                  <div className="text-xs text-gray-500">Confirmation code</div>
                  <div className="font-mono text-white">{booking.confirmation_code ?? '-'}</div>
                </div>
                <div>
                  <div className="text-xs text-gray-500">Fulfillment</div>
                  <div className="capitalize text-white">{booking.fulfillment_status}</div>
                </div>
              </div>

              <div>
                <div className="mb-2 flex items-center gap-2 text-white">
                  <Wine className="h-4 w-4 text-primary" />
                  <span className="font-semibold">Bottles</span>
                </div>
                {bottleLines.length === 0 ? (
                  <p className="text-sm text-muted-foreground">No bottles on this booking yet.</p>
                ) : (
                  <div className="rounded-lg border border-gray-800">
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Bottle</TableHead>
                          <TableHead>Qty</TableHead>
                          <TableHead className="text-right">Total</TableHead>
                          <TableHead />
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {bottleLines.map((line) => (
                          <Fragment key={line.id}>
                            <TableRow className={line.cancelled_at ? 'opacity-50' : undefined}>
                              <TableCell>
                                <span className={line.cancelled_at ? 'line-through' : undefined}>
                                  {line.bottle_name}
                                  {line.size ? ` (${line.size})` : ''}
                                </span>
                                {line.is_addon && (
                                  <Badge variant="outline" className="ml-2 text-[10px]">
                                    Added
                                  </Badge>
                                )}
                                {line.payment_status === 'due_at_venue' && !line.cancelled_at && (
                                  <Badge variant="outline" className="ml-2 text-[10px] text-orange-400">
                                    Due at venue
                                  </Badge>
                                )}
                                {line.payment_status === 'pending_payment' && (
                                  <Badge variant="outline" className="ml-2 text-[10px] text-gray-400">
                                    Customer payment processing
                                  </Badge>
                                )}
                                {line.cancelled_at && (
                                  <Badge variant="outline" className="ml-2 text-[10px] text-red-400">
                                    Cancelled{line.cancellation_reason ? `: ${line.cancellation_reason}` : ''}
                                  </Badge>
                                )}
                              </TableCell>
                              <TableCell>{line.quantity}</TableCell>
                              <TableCell className="text-right">{money(line.line_total_cents, booking.currency)}</TableCell>
                              <TableCell>
                                <div className="flex items-center gap-1">
                                  {line.payment_status !== 'pending_payment' && !line.cancelled_at && (
                                    <Select
                                      value={line.service_status}
                                      onValueChange={(v) => handleServiceStatusChange(line.id, v as BottleServiceStatus)}
                                    >
                                      <SelectTrigger className="h-7 w-[112px] text-xs">
                                        <SelectValue />
                                      </SelectTrigger>
                                      <SelectContent>
                                        {BOTTLE_SERVICE_STATUSES.map((s) => (
                                          <SelectItem key={s} value={s}>{BOTTLE_SERVICE_STATUS_LABELS[s]}</SelectItem>
                                        ))}
                                      </SelectContent>
                                    </Select>
                                  )}
                                  {!line.cancelled_at && line.payment_status !== 'pending_payment' && (
                                    <>
                                      <Button
                                        type="button"
                                        variant="ghost"
                                        size="icon"
                                        className="h-7 w-7 text-amber-400 hover:bg-amber-950/40"
                                        title="Mark unavailable"
                                        onClick={() => {
                                          setFlaggingLineId((v) => (v === line.id ? null : line.id));
                                          setCancellingLineId(null);
                                        }}
                                      >
                                        <ShieldAlert className="h-3.5 w-3.5" />
                                      </Button>
                                      <Button
                                        type="button"
                                        variant="ghost"
                                        size="icon"
                                        className="h-7 w-7 text-red-400 hover:bg-red-950/40"
                                        title="Cancel this item"
                                        onClick={() => {
                                          setCancellingLineId((v) => (v === line.id ? null : line.id));
                                          setFlaggingLineId(null);
                                        }}
                                      >
                                        <Ban className="h-3.5 w-3.5" />
                                      </Button>
                                    </>
                                  )}
                                </div>
                              </TableCell>
                            </TableRow>
                            {cancellingLineId === line.id && (
                              <TableRow>
                                <TableCell colSpan={4} className="bg-red-950/10">
                                  <div className="space-y-2 py-1">
                                    <Label className="text-xs text-red-300">Why is this item being cancelled?</Label>
                                    <Textarea value={cancelLineReason} onChange={(e) => setCancelLineReason(e.target.value)} />
                                    <div className="flex gap-2">
                                      <Button variant="outline" size="sm" className="flex-1 border-gray-700" onClick={() => setCancellingLineId(null)}>
                                        Back
                                      </Button>
                                      <Button
                                        size="sm"
                                        className="flex-1 bg-red-600 text-white hover:bg-red-700"
                                        disabled={cancellingLine}
                                        onClick={() => handleCancelLine(line.id)}
                                      >
                                        {cancellingLine ? 'Cancelling...' : 'Cancel Item'}
                                      </Button>
                                    </div>
                                  </div>
                                </TableCell>
                              </TableRow>
                            )}
                            {flaggingLineId === line.id && (
                              <TableRow>
                                <TableCell colSpan={4} className="bg-amber-950/10">
                                  <div className="space-y-2 py-1">
                                    <Label className="text-xs text-amber-300">Why is this item unavailable?</Label>
                                    <Textarea value={flagReason} onChange={(e) => setFlagReason(e.target.value)} />
                                    <Label className="text-xs text-amber-300">Propose a replacement (optional - leave blank to offer removal)</Label>
                                    <Select value={flagReplacementId} onValueChange={setFlagReplacementId}>
                                      <SelectTrigger>
                                        <SelectValue placeholder="No replacement - offer removal" />
                                      </SelectTrigger>
                                      <SelectContent>
                                        {venueBottles.filter((b) => b.id !== line.bottle_id).map((b) => (
                                          <SelectItem key={b.id} value={b.id}>
                                            {b.name}{b.size ? ` (${b.size})` : ''} - {money(b.price_cents, booking.currency)}
                                          </SelectItem>
                                        ))}
                                      </SelectContent>
                                    </Select>
                                    <div className="flex gap-2">
                                      <Button variant="outline" size="sm" className="flex-1 border-gray-700" onClick={() => setFlaggingLineId(null)}>
                                        Back
                                      </Button>
                                      <Button
                                        size="sm"
                                        className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90"
                                        disabled={flaggingLine}
                                        onClick={() => handleFlagUnavailable(line.id)}
                                      >
                                        {flaggingLine ? 'Sending...' : 'Notify Customer'}
                                      </Button>
                                    </div>
                                  </div>
                                </TableCell>
                              </TableRow>
                            )}
                          </Fragment>
                        ))}
                      </TableBody>
                    </Table>
                  </div>
                )}

                <Button
                  type="button"
                  variant="outline"
                  className="mt-3 w-full border-gray-700"
                  onClick={() => setAddBottlesOpen(true)}
                >
                  <Plus className="mr-2 h-4 w-4" /> Add Bottles
                </Button>
              </div>

              <div className="space-y-1.5 rounded-lg border border-gray-800 p-4 text-sm">
                <div className="flex justify-between text-gray-400">
                  <span>Table deposit</span>
                  <span>{money(booking.deposit_cents, booking.currency)}</span>
                </div>
                <div className="flex justify-between text-gray-400">
                  <span>Bottles</span>
                  <span>{money(totals.bottleSubtotalCents, booking.currency)}</span>
                </div>
                {booking.discount_cents > 0 && (
                  <div className="flex justify-between text-emerald-400">
                    <span>Discount</span>
                    <span>-{money(booking.discount_cents, booking.currency)}</span>
                  </div>
                )}
                <div className="flex justify-between text-gray-400">
                  <span>Tax</span>
                  <span>{money(totals.taxCents, booking.currency)}</span>
                </div>
                <div className="flex justify-between text-gray-400">
                  <span>BottlesUp fee</span>
                  <span>{money(totals.feeCents, booking.currency)}</span>
                </div>
                <div className="flex justify-between border-t border-gray-800 pt-1.5 font-semibold text-white">
                  <span>Total</span>
                  <span>{money(totals.totalCents, booking.currency)}</span>
                </div>
                <div className="flex justify-between text-gray-400">
                  <span>Paid so far</span>
                  <span>{money(booking.amount_paid_cents, booking.currency)}</span>
                </div>
                <div
                  className={`flex justify-between font-semibold ${totals.balanceDueCents > 0 ? 'text-orange-400' : 'text-emerald-400'}`}
                >
                  <span>Balance due</span>
                  <span>{money(totals.balanceDueCents, booking.currency)}</span>
                </div>
                {paymentStatus && (
                  <div className="flex justify-end">
                    <Badge
                      variant="outline"
                      className={
                        paymentStatus === 'payment_due'
                          ? 'border-orange-500/40 text-[10px] text-orange-400'
                          : paymentStatus === 'payment_recorded'
                            ? 'border-blue-600 text-[10px] text-blue-400'
                            : 'border-purple-600 text-[10px] text-purple-400'
                      }
                    >
                      {PAYMENT_STATUS_LABELS[paymentStatus]}
                    </Badge>
                  </div>
                )}
              </div>

              {paymentHistory.length > 0 && (
                <div className="space-y-2 rounded-lg border border-gray-800 p-4 text-sm">
                  <div className="text-xs uppercase tracking-wide text-gray-500">Club Payments Recorded</div>
                  {paymentHistory.map((p) => (
                    <div key={p.id} className="space-y-1.5 border-b border-gray-900 pb-1.5 last:border-0 last:pb-0">
                      <div className="flex items-center justify-between text-gray-300">
                        <span>
                          {money(p.amountPaidCents, booking.currency)} · {p.paymentMethod}
                          {p.posReference ? ` · ${p.posReference}` : ''}
                          {p.payerName && <span className="text-gray-500"> · paid by {p.payerName}</span>}
                          {p.correctsPaymentId && (
                            <Badge variant="outline" className="ml-2 border-blue-700 text-[10px] text-blue-400">Correction</Badge>
                          )}
                        </span>
                        <div className="flex items-center gap-2">
                          {p.customerConfirmationStatus === 'confirmed' && (
                            <Badge variant="outline" className="border-green-600 text-[10px] text-green-400">Confirmed</Badge>
                          )}
                          {p.customerConfirmationStatus === 'disputed' && (
                            <Badge variant="outline" className="border-red-600 text-[10px] text-red-400">Disputed</Badge>
                          )}
                          {p.customerConfirmationStatus === 'pending' && !p.managerVerifiedAt && (
                            <Badge variant="outline" className="border-gray-700 text-[10px] text-gray-500">Awaiting customer</Badge>
                          )}
                          {p.managerVerifiedAt && (
                            <Badge variant="outline" className="border-purple-600 text-[10px] text-purple-400">Manager verified</Badge>
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

                      {p.customerConfirmationStatus === 'pending' && (
                        <div className="flex flex-wrap gap-3 text-xs">
                          <button
                            type="button"
                            className="text-gray-500 hover:text-gray-300"
                            onClick={() => {
                              setCorrectingPaymentId((v) => (v === p.id ? null : p.id));
                              setCorrectBilled((p.billedAmountCents / 100).toString());
                              setCorrectPaid((p.amountPaidCents / 100).toString());
                              setCorrectMethod(p.paymentMethod === 'split' ? 'cash' : p.paymentMethod);
                              setCorrectReason('');
                            }}
                          >
                            Correct
                          </button>
                          {!p.managerVerifiedAt && (
                            <button
                              type="button"
                              className="text-gray-500 hover:text-gray-300 disabled:opacity-50"
                              disabled={verifyingPaymentId === p.id}
                              onClick={() => handleManagerVerify(p.id)}
                            >
                              {verifyingPaymentId === p.id ? 'Verifying...' : "Manager verify (customer didn't respond)"}
                            </button>
                          )}
                        </div>
                      )}

                      {correctingPaymentId === p.id && (
                        <div className="space-y-2 rounded-lg border border-blue-900/50 bg-blue-950/10 p-3">
                          <div className="grid grid-cols-2 gap-2">
                            <div className="space-y-1">
                              <Label className="text-xs">Corrected billed amount</Label>
                              <Input type="number" min="0" step="0.01" value={correctBilled} onChange={(e) => setCorrectBilled(e.target.value)} />
                            </div>
                            <div className="space-y-1">
                              <Label className="text-xs">Corrected amount paid</Label>
                              <Input type="number" min="0" step="0.01" value={correctPaid} onChange={(e) => setCorrectPaid(e.target.value)} />
                            </div>
                          </div>
                          <div className="space-y-1">
                            <Label className="text-xs">Payment method</Label>
                            <Select value={correctMethod} onValueChange={(v) => setCorrectMethod(v as ClubPaymentMethod)}>
                              <SelectTrigger>
                                <SelectValue />
                              </SelectTrigger>
                              <SelectContent>
                                <SelectItem value="cash">Cash</SelectItem>
                                <SelectItem value="debit">Debit</SelectItem>
                                <SelectItem value="credit">Credit</SelectItem>
                              </SelectContent>
                            </Select>
                          </div>
                          <div className="space-y-1">
                            <Label className="text-xs">Reason for this correction</Label>
                            <Textarea value={correctReason} onChange={(e) => setCorrectReason(e.target.value)} />
                          </div>
                          <div className="flex gap-2">
                            <Button variant="outline" size="sm" className="flex-1 border-gray-700" onClick={() => setCorrectingPaymentId(null)}>
                              Back
                            </Button>
                            <Button
                              size="sm"
                              className="flex-1 bg-blue-600 text-white hover:bg-blue-700"
                              disabled={correcting}
                              onClick={() => handleCorrectPayment(p.id)}
                            >
                              {correcting ? 'Saving...' : 'Save Correction'}
                            </Button>
                          </div>
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              )}

              {totals.balanceDueCents > 0 && (
                <div className="rounded-lg border border-orange-500/30 bg-orange-500/5 p-4">
                  <RecordClubPaymentForm
                    bookingId={booking.id}
                    balanceDueCents={totals.balanceDueCents}
                    currency={booking.currency}
                    customerName={booking.customer_name}
                    customerEmail={booking.customer_email}
                    isManager
                    onRecorded={() => {
                      onUpdated();
                      load();
                    }}
                  />
                </div>
              )}

              {booking.amount_paid_cents > 0 && (
                <div className="rounded-lg border border-gray-800 p-4">
                  {refundOpen ? (
                    <div className="space-y-3">
                      <Label className="text-sm text-white">Record a Refund</Label>
                      <div className="space-y-1">
                        <Label className="text-xs">Refund type</Label>
                        <Select value={refundType} onValueChange={(v) => setRefundType(v as 'online' | 'club')}>
                          <SelectTrigger>
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            <SelectItem value="online">Online (refund through Stripe)</SelectItem>
                            <SelectItem value="club">Club (venue already refunded directly)</SelectItem>
                          </SelectContent>
                        </Select>
                      </div>
                      <div className="space-y-1">
                        <Label className="text-xs">Amount to refund</Label>
                        <Input type="number" min="0" step="0.01" value={refundAmount} onChange={(e) => setRefundAmount(e.target.value)} />
                      </div>
                      <div className="space-y-1">
                        <Label className="text-xs">Reason</Label>
                        <Textarea value={refundReason} onChange={(e) => setRefundReason(e.target.value)} />
                      </div>
                      {refundType === 'club' && (
                        <div className="space-y-1">
                          <Label className="text-xs">POS reference (optional)</Label>
                          <Input value={refundPosReference} onChange={(e) => setRefundPosReference(e.target.value)} />
                        </div>
                      )}
                      <div className="flex gap-2">
                        <Button variant="outline" className="flex-1 border-gray-700" onClick={() => setRefundOpen(false)}>
                          Back
                        </Button>
                        <Button
                          className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90"
                          disabled={refunding}
                          onClick={handleRefund}
                        >
                          {refunding ? 'Saving...' : 'Record Refund'}
                        </Button>
                      </div>
                    </div>
                  ) : (
                    <Button
                      variant="outline"
                      className="w-full border-gray-700 text-gray-300"
                      onClick={() => setRefundOpen(true)}
                    >
                      <RotateCcw className="mr-2 h-4 w-4" /> Record a Refund
                    </Button>
                  )}
                </div>
              )}
            </div>

            <AddBottlesDialog
              bookingId={booking.id}
              mode="staff"
              open={addBottlesOpen}
              onOpenChange={setAddBottlesOpen}
              onAdded={() => {
                onUpdated();
                load();
              }}
            />
          </>
        )}
      </SheetContent>
    </Sheet>
  );
};

export default TableBookingDetailSheet;
