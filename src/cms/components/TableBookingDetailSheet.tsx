import { useEffect, useMemo, useState } from 'react';
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
import { Plus, Wine, X, Receipt } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import AddBottlesDialog from '@/components/AddBottlesDialog';
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
  const [showPaymentForm, setShowPaymentForm] = useState(false);
  const [billedAmount, setBilledAmount] = useState('');
  const [paidAmount, setPaidAmount] = useState('');
  const [paymentMethod, setPaymentMethod] = useState<ClubPaymentMethod>('cash');
  const [splitLegs, setSplitLegs] = useState<SplitLeg[]>([{ method: 'cash', amountCents: 0 }]);
  const [posReference, setPosReference] = useState('');
  const [receiptFile, setReceiptFile] = useState<File | null>(null);
  const [recordingPayment, setRecordingPayment] = useState(false);

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
    }

    setLoading(false);
  };

  useEffect(() => {
    load();
    resetPaymentForm();
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
    const dueAtVenueBottleCents = bottleLines
      .filter((l) => l.payment_status === 'due_at_venue')
      .reduce((sum, l) => sum + l.line_total_cents, 0);
    const taxedBottleCents = bottleLines
      .filter((l) => l.payment_status === 'paid')
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
    if (!totals) return;
    const dollars = (totals.balanceDueCents / 100).toFixed(2);
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

      const { newAmountPaidCents, confirmationEmailSent } = await recordClubPayment({
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
        description: `Paid so far: ${money(newAmountPaidCents, booking.currency)}${confirmationEmailSent ? '' : ' - could not email the customer'}`,
      });
      resetPaymentForm();
      onUpdated();
      load();
    } catch (err) {
      toast({
        title: 'Failed to record payment',
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
              </div>

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
                          <TableRow key={line.id}>
                            <TableCell>
                              {line.bottle_name}
                              {line.size ? ` (${line.size})` : ''}
                              {line.is_addon && (
                                <Badge variant="outline" className="ml-2 text-[10px]">
                                  Added
                                </Badge>
                              )}
                              {line.payment_status === 'due_at_venue' && (
                                <Badge variant="outline" className="ml-2 text-[10px] text-orange-400">
                                  Due at venue
                                </Badge>
                              )}
                              {line.payment_status === 'pending_payment' && (
                                <Badge variant="outline" className="ml-2 text-[10px] text-gray-400">
                                  Customer payment processing
                                </Badge>
                              )}
                            </TableCell>
                            <TableCell>{line.quantity}</TableCell>
                            <TableCell className="text-right">{money(line.line_total_cents, booking.currency)}</TableCell>
                            <TableCell>
                              {line.payment_status !== 'pending_payment' && (
                                <Select
                                  value={line.service_status}
                                  onValueChange={(v) => handleServiceStatusChange(line.id, v as BottleServiceStatus)}
                                >
                                  <SelectTrigger className="h-7 w-[128px] text-xs">
                                    <SelectValue />
                                  </SelectTrigger>
                                  <SelectContent>
                                    {BOTTLE_SERVICE_STATUSES.map((s) => (
                                      <SelectItem key={s} value={s}>{BOTTLE_SERVICE_STATUS_LABELS[s]}</SelectItem>
                                    ))}
                                  </SelectContent>
                                </Select>
                              )}
                            </TableCell>
                          </TableRow>
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
              </div>

              {paymentHistory.length > 0 && (
                <div className="space-y-1.5 rounded-lg border border-gray-800 p-4 text-sm">
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

              {totals.balanceDueCents > 0 && (
                <div className="rounded-lg border border-orange-500/30 bg-orange-500/5 p-4">
                  {showPaymentForm ? (
                    <div className="space-y-3">
                      <Label className="text-sm text-white">Record Club Payment</Label>

                      <div className="grid grid-cols-2 gap-2">
                        <div className="space-y-1">
                          <Label className="text-xs">Final billed amount</Label>
                          <Input
                            type="number"
                            min="0"
                            step="0.01"
                            value={billedAmount}
                            onChange={(e) => setBilledAmount(e.target.value)}
                          />
                        </div>
                        <div className="space-y-1">
                          <Label className="text-xs">Amount actually paid</Label>
                          <Input
                            type="number"
                            min="0"
                            step="0.01"
                            value={paidAmount}
                            onChange={(e) => setPaidAmount(e.target.value)}
                          />
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
