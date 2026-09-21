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
import { logAudit } from '@/lib/auditLog';
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
import type { Database, OrderStatus } from '@/types/database';

type BookingRow = Database['public']['Tables']['site_table_bookings']['Row'] & {
  site_venues: { id: string; name: string; tax_rate_bps: number } | null;
  site_table_types: { name: string } | null;
  site_venue_time_slots: { start_time: string } | null;
};

type BottleLine = Database['public']['Tables']['site_table_booking_bottles']['Row'];
type BottleMenuItem = Database['public']['Tables']['site_bottles']['Row'];

interface PendingAddition {
  bottleId: string;
  name: string;
  size: string | null;
  unitPriceCents: number;
  quantity: number;
}

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
  const [menu, setMenu] = useState<BottleMenuItem[]>([]);
  const [bottlesUpFeeBps, setBottlesUpFeeBps] = useState(0);
  const [loading, setLoading] = useState(false);
  const [pending, setPending] = useState<PendingAddition[]>([]);
  const [pickedBottleId, setPickedBottleId] = useState('');
  const [pickedQty, setPickedQty] = useState('1');
  const [saving, setSaving] = useState(false);
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
    setPending([]);

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

    if (loadedBooking?.site_venues?.id) {
      const { data: menuData } = await supabase
        .from('site_bottles')
        .select('*')
        .eq('venue_id', loadedBooking.site_venues.id)
        .eq('is_available', true)
        .eq('is_sold_out', false)
        .order('sort_order');
      setMenu((menuData as BottleMenuItem[]) ?? []);
    } else {
      setMenu([]);
    }

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
  // Bottles flagged due_at_venue (a pay-at-club checkout) were never taxed or
  // charged through Stripe - only the deposit was - so they're excluded from the
  // taxed subtotal and added back in untaxed. Staff-added bottles (is_addon) keep
  // the original behavior of being taxed together with everything else.
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
    const pendingSubtotal = pending.reduce((sum, p) => sum + p.unitPriceCents * p.quantity, 0);
    const bottleSubtotalCents = taxedBottleCents + dueAtVenueBottleCents + pendingSubtotal;
    const preTax = booking.deposit_cents + taxedBottleCents + pendingSubtotal;
    const discounted = Math.max(preTax - booking.discount_cents, 0);
    const taxRateBps = booking.site_venues?.tax_rate_bps ?? 0;
    const taxCents = Math.round((discounted * taxRateBps) / 10000);
    const feeCents = Math.round((discounted * bottlesUpFeeBps) / 10000);
    const totalCents = discounted + taxCents + feeCents + dueAtVenueBottleCents;
    const balanceDueCents = Math.max(totalCents - booking.amount_paid_cents, 0);
    return { bottleSubtotalCents, taxCents, feeCents, totalCents, balanceDueCents };
  }, [booking, bottleLines, pending, bottlesUpFeeBps]);

  const addPending = () => {
    const bottle = menu.find((m) => m.id === pickedBottleId);
    const qty = parseInt(pickedQty, 10);
    if (!bottle || !Number.isInteger(qty) || qty < 1) return;

    if (bottle.stock_quantity !== null) {
      const alreadyPending = pending
        .filter((p) => p.bottleId === bottle.id)
        .reduce((sum, p) => sum + p.quantity, 0);
      if (alreadyPending + qty > bottle.stock_quantity) {
        toast({
          title: 'Not enough stock',
          description: `Only ${bottle.stock_quantity} of "${bottle.name}" tracked in stock.`,
          variant: 'destructive',
        });
        return;
      }
    }

    setPending((prev) => [
      ...prev,
      { bottleId: bottle.id, name: bottle.name, size: bottle.size, unitPriceCents: bottle.price_cents, quantity: qty },
    ]);
    setPickedBottleId('');
    setPickedQty('1');
  };

  const removePending = (index: number) => setPending((prev) => prev.filter((_, i) => i !== index));

  const saveAdditions = async () => {
    if (!booking || pending.length === 0 || !totals) return;
    setSaving(true);

    const adminId = (await supabase.auth.getUser()).data.user?.id ?? null;

    const { error: insertError } = await supabase.from('site_table_booking_bottles').insert(
      pending.map((p) => ({
        booking_id: booking.id,
        bottle_id: p.bottleId,
        bottle_name: p.name,
        size: p.size,
        unit_price_cents: p.unitPriceCents,
        quantity: p.quantity,
        line_total_cents: p.unitPriceCents * p.quantity,
        is_addon: true,
        added_by: adminId,
      })),
    );

    if (insertError) {
      setSaving(false);
      toast({ title: 'Failed to add bottles', description: insertError.message, variant: 'destructive' });
      return;
    }

    const { error: updateError } = await supabase
      .from('site_table_bookings')
      .update({
        bottle_subtotal_cents: totals.bottleSubtotalCents,
        tax_cents: totals.taxCents,
        bottlesup_fee_cents: totals.feeCents,
        amount_total_cents: totals.totalCents,
      })
      .eq('id', booking.id);

    setSaving(false);

    if (updateError) {
      toast({ title: 'Bottles added, but totals failed to update', description: updateError.message, variant: 'destructive' });
      load();
      return;
    }

    await logAudit({
      action: 'table_booking.bottles_added',
      entityType: 'site_table_bookings',
      entityId: booking.id,
      details: { bottles: pending, new_total_cents: totals.totalCents },
    });

    toast({ title: 'Bottles added', description: `New total: ${money(totals.totalCents, booking.currency)}` });
    onUpdated();
    load();
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

      const { newAmountPaidCents } = await recordClubPayment({
        bookingId: booking.id,
        billedAmountCents: billedCents,
        amountPaidCents: paidCents,
        paymentMethod,
        splitBreakdown,
        posReference: posReference.trim() || null,
        receiptPhotoPath,
      });

      toast({ title: 'Payment recorded', description: `Paid so far: ${money(newAmountPaidCents, booking.currency)}` });
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
                {bottleLines.length === 0 && pending.length === 0 ? (
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
                            <TableCell />
                          </TableRow>
                        ))}
                        {pending.map((p, i) => (
                          <TableRow key={`pending-${i}`} className="bg-primary/5">
                            <TableCell>
                              {p.name}
                              {p.size ? ` (${p.size})` : ''}
                              <Badge variant="outline" className="ml-2 text-[10px] text-primary">
                                Not saved yet
                              </Badge>
                            </TableCell>
                            <TableCell>{p.quantity}</TableCell>
                            <TableCell className="text-right">
                              {money(p.unitPriceCents * p.quantity, booking.currency)}
                            </TableCell>
                            <TableCell className="text-right">
                              <button
                                type="button"
                                className="text-xs text-gray-500 hover:text-red-400"
                                onClick={() => removePending(i)}
                              >
                                Remove
                              </button>
                            </TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </div>
                )}

                {menu.length === 0 ? (
                  <p className="mt-3 text-xs text-muted-foreground">
                    This venue has no bottle menu set up yet - add bottles under Venues first.
                  </p>
                ) : (
                  <div className="mt-3 flex items-end gap-2">
                    <div className="flex-1 space-y-1">
                      <Label className="text-xs">Add a bottle</Label>
                      <Select value={pickedBottleId} onValueChange={setPickedBottleId}>
                        <SelectTrigger>
                          <SelectValue placeholder="Select a bottle" />
                        </SelectTrigger>
                        <SelectContent>
                          {menu.map((m) => (
                            <SelectItem key={m.id} value={m.id}>
                              {m.name}
                              {m.size ? ` (${m.size})` : ''} - {money(m.price_cents, m.currency)}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </div>
                    <div className="w-20 space-y-1">
                      <Label className="text-xs">Qty</Label>
                      <Input
                        type="number"
                        min="1"
                        value={pickedQty}
                        onChange={(e) => setPickedQty(e.target.value)}
                      />
                    </div>
                    <Button type="button" variant="outline" disabled={!pickedBottleId} onClick={addPending}>
                      <Plus className="h-4 w-4" />
                    </Button>
                  </div>
                )}

                {pending.length > 0 && (
                  <Button
                    onClick={saveAdditions}
                    disabled={saving}
                    className="mt-3 w-full bg-gradient-orange text-black font-bold hover:opacity-90"
                  >
                    {saving ? 'Saving...' : `Save ${pending.length} bottle${pending.length === 1 ? '' : 's'} to booking`}
                  </Button>
                )}
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
                  ))}
                </div>
              )}

              {totals.balanceDueCents > 0 && pending.length === 0 && (
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
          </>
        )}
      </SheetContent>
    </Sheet>
  );
};

export default TableBookingDetailSheet;
