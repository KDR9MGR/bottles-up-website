import { useEffect, useState } from 'react';
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { AlertTriangle, CheckCircle2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import {
  getBookingReconciliation,
  closeTableBookingReconciliation,
  type BookingReconciliation,
} from '@/lib/reconciliation';
import { derivePaymentStatus, PAYMENT_STATUS_LABELS } from '@/lib/clubPayment';

const money = (cents: number, currency = 'CAD') => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

interface TableReconciliationSheetProps {
  bookingId: string | null;
  onOpenChange: (open: boolean) => void;
  onClosed?: () => void;
}

// Bottle Payment Options section 10: "The manager compares orders, payments,
// refunds and served quantities against online payment records and venue
// POS receipts." This is a read-mostly summary of everything already
// recorded elsewhere in this feature (sections 3-9) - it never edits a
// bottle line, payment or refund directly; it only reviews them and, once
// satisfied (or with an override reason), closes the table.
const TableReconciliationSheet = ({ bookingId, onOpenChange, onClosed }: TableReconciliationSheetProps) => {
  const { toast } = useToast();
  const [loading, setLoading] = useState(false);
  const [detail, setDetail] = useState<BookingReconciliation | null>(null);
  const [overrideReason, setOverrideReason] = useState('');
  const [closing, setClosing] = useState(false);

  const load = async () => {
    if (!bookingId) return;
    setLoading(true);
    try {
      const result = await getBookingReconciliation(bookingId);
      setDetail(result);
    } catch (err) {
      toast({
        title: 'Could not load reconciliation',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
      setDetail({ found: false });
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    setOverrideReason('');
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bookingId]);

  const handleClose = async () => {
    if (!bookingId) return;
    const flags = detail?.flags ?? [];
    if (flags.length > 0 && !overrideReason.trim()) {
      toast({ title: 'An override reason is required while differences are unresolved', variant: 'destructive' });
      return;
    }
    setClosing(true);
    try {
      await closeTableBookingReconciliation(bookingId, overrideReason.trim() || null);
      toast({ title: 'Table closed', description: 'Reconciliation recorded.' });
      onClosed?.();
      onOpenChange(false);
    } catch (err) {
      toast({
        title: 'Could not close this table',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setClosing(false);
    }
  };

  const flags = detail?.flags ?? [];

  return (
    <Sheet open={!!bookingId} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="w-full overflow-y-auto border-gray-800 bg-gray-950 sm:max-w-xl">
        {loading || !detail ? (
          <div className="flex h-40 items-center justify-center text-gray-400">Loading...</div>
        ) : !detail.found ? (
          <div className="flex h-40 items-center justify-center text-gray-400">Booking not found.</div>
        ) : (
          <>
            <SheetHeader>
              <SheetTitle className="text-white">Close Table - {detail.customerName}</SheetTitle>
            </SheetHeader>

            <div className="space-y-6 pb-6 pt-4">
              <div className="flex flex-wrap items-center gap-2 text-sm text-gray-400">
                <span>{detail.tableTypeName} - {detail.venueName}</span>
                <span>· {detail.bookingDate}</span>
                <span className="font-mono">{detail.confirmationCode}</span>
                {detail.reconciledAt && (
                  <Badge variant="outline" className="border-green-600 text-green-400">Already closed</Badge>
                )}
                {!detail.reconciledAt && detail.closeoutRequestedAt && (
                  <Badge variant="outline" className="border-blue-600 text-blue-400">
                    Closeout requested{detail.closeoutRequestedByEmail ? ` by ${detail.closeoutRequestedByEmail}` : ''}
                  </Badge>
                )}
              </div>

              {flags.length > 0 ? (
                <div className="space-y-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-4">
                  <div className="flex items-center gap-2 text-amber-400">
                    <AlertTriangle className="h-4 w-4" />
                    <span className="font-semibold">Unresolved differences</span>
                  </div>
                  <ul className="list-disc space-y-1 pl-5 text-sm text-amber-200">
                    {flags.map((f, i) => <li key={i}>{f}</li>)}
                  </ul>
                </div>
              ) : (
                <div className="flex items-center gap-2 rounded-lg border border-green-600/40 bg-green-500/5 p-4 text-green-400">
                  <CheckCircle2 className="h-4 w-4" />
                  <span>No unresolved differences</span>
                </div>
              )}

              <div className="space-y-1.5 rounded-lg border border-gray-800 p-4 text-sm">
                <div className="text-xs uppercase tracking-wide text-gray-500">Booth &amp; Bottles</div>
                <div className="flex justify-between text-gray-400">
                  <span>Table deposit{detail.depositIsCredit ? ' (credited toward bottle bill)' : ''}</span>
                  <span>{money(detail.depositCents ?? 0, detail.currency)}</span>
                </div>
                <div className="flex justify-between text-gray-400">
                  <span>Bottle subtotal</span>
                  <span>{money(detail.bottleSubtotalCents ?? 0, detail.currency)}</span>
                </div>
                {(detail.discountCents ?? 0) > 0 && (
                  <div className="flex justify-between text-emerald-400">
                    <span>Discount</span>
                    <span>-{money(detail.discountCents ?? 0, detail.currency)}</span>
                  </div>
                )}
                <div className="flex justify-between text-gray-400">
                  <span>Tax</span>
                  <span>{money(detail.taxCents ?? 0, detail.currency)}</span>
                </div>
                <div className="flex justify-between text-gray-400">
                  <span>BottlesUp fee</span>
                  <span>{money(detail.bottlesupFeeCents ?? 0, detail.currency)}</span>
                </div>
                <div className="flex justify-between border-t border-gray-800 pt-1.5 font-semibold text-white">
                  <span>Total</span>
                  <span>{money(detail.amountTotalCents ?? 0, detail.currency)}</span>
                </div>
              </div>

              <div className="space-y-1.5 rounded-lg border border-gray-800 p-4 text-sm">
                <div className="text-xs uppercase tracking-wide text-gray-500">Payment Channels</div>
                <div className="flex justify-between text-gray-400">
                  <span>Total paid through BottlesUp</span>
                  <span>{money(detail.bottlesupCollectedCents ?? 0, detail.currency)}</span>
                </div>
                <div className="flex justify-between text-gray-400">
                  <span>Total paid directly to the venue</span>
                  <span>{money(detail.clubCollectedCents ?? 0, detail.currency)}</span>
                </div>
                {((detail.onlineRefundsCents ?? 0) > 0 || (detail.clubRefundsCents ?? 0) > 0) && (
                  <div className="flex justify-between text-red-400">
                    <span>Refunds (online + club)</span>
                    <span>-{money((detail.onlineRefundsCents ?? 0) + (detail.clubRefundsCents ?? 0), detail.currency)}</span>
                  </div>
                )}
                <div className="flex justify-between text-gray-400">
                  <span>Paid so far</span>
                  <span>{money(detail.amountPaidCents ?? 0, detail.currency)}</span>
                </div>
                <div className={`flex justify-between font-semibold ${(detail.balanceDueCents ?? 0) > 0 ? 'text-orange-400' : 'text-emerald-400'}`}>
                  <span>Outstanding balance</span>
                  <span>{money(detail.balanceDueCents ?? 0, detail.currency)}</span>
                </div>
                {(() => {
                  const status = derivePaymentStatus(detail.balanceDueCents ?? 0, detail.clubPayments ?? []);
                  return status && (
                    <div className="flex justify-end">
                      <Badge
                        variant="outline"
                        className={
                          status === 'payment_due'
                            ? 'border-orange-500/40 text-[10px] text-orange-400'
                            : status === 'payment_recorded'
                              ? 'border-blue-600 text-[10px] text-blue-400'
                              : 'border-purple-600 text-[10px] text-purple-400'
                        }
                      >
                        {PAYMENT_STATUS_LABELS[status]}
                      </Badge>
                    </div>
                  );
                })()}
              </div>

              <div className="space-y-1.5 rounded-lg border border-gray-800 p-4 text-sm">
                <div className="text-xs uppercase tracking-wide text-gray-500">Bottles &amp; Service</div>
                {(detail.bottles ?? []).map((b) => (
                  <div key={b.id} className="flex items-center justify-between gap-2 text-gray-300">
                    <span className={b.cancelledAt ? 'line-through text-gray-600' : ''}>
                      {b.bottleName}{b.size ? ` (${b.size})` : ''} × {b.quantity}
                    </span>
                    {b.cancelledAt ? (
                      <Badge variant="outline" className="border-red-700 text-[10px] text-red-400">Cancelled</Badge>
                    ) : b.paymentStatus === 'pending_payment' ? (
                      <Badge variant="outline" className="border-gray-700 text-[10px] text-gray-500">Processing</Badge>
                    ) : b.serviceStatus === 'served' ? (
                      <Badge variant="outline" className="border-green-600 text-[10px] text-green-400">Served</Badge>
                    ) : (
                      <Badge variant="outline" className="border-amber-600 text-[10px] text-amber-400">Unserved</Badge>
                    )}
                  </div>
                ))}
                {(detail.bottles ?? []).length === 0 && <p className="text-gray-500">No bottles on this booking.</p>}
              </div>

              {(detail.clubPayments ?? []).length > 0 && (
                <div className="space-y-1.5 rounded-lg border border-gray-800 p-4 text-sm">
                  <div className="text-xs uppercase tracking-wide text-gray-500">Club Payments &amp; Confirmations</div>
                  {(detail.clubPayments ?? []).map((p) => (
                    <div key={p.id} className="flex items-center justify-between text-gray-300">
                      <span>
                        {money(p.amountPaidCents, detail.currency)} · {p.paymentMethod}
                        {p.posReference ? ` · ${p.posReference}` : ''}
                        {p.payerName && <span className="text-gray-500"> · {p.payerName}</span>}
                      </span>
                      {p.customerConfirmationStatus === 'confirmed' ? (
                        <Badge variant="outline" className="border-green-600 text-[10px] text-green-400">Confirmed</Badge>
                      ) : p.customerConfirmationStatus === 'disputed' ? (
                        <Badge variant="outline" className="border-red-600 text-[10px] text-red-400">Disputed</Badge>
                      ) : p.managerVerifiedAt ? (
                        <Badge variant="outline" className="border-purple-600 text-[10px] text-purple-400">Manager verified</Badge>
                      ) : (
                        <Badge variant="outline" className="border-gray-700 text-[10px] text-gray-500">Awaiting customer</Badge>
                      )}
                    </div>
                  ))}
                </div>
              )}

              {(detail.refunds ?? []).length > 0 && (
                <div className="space-y-1.5 rounded-lg border border-gray-800 p-4 text-sm">
                  <div className="text-xs uppercase tracking-wide text-gray-500">Refunds</div>
                  {(detail.refunds ?? []).map((r) => (
                    <div key={r.id} className="flex items-center justify-between text-gray-300">
                      <span>
                        {money(r.amountCents, detail.currency)} · {r.refundType === 'online' ? 'Online (Stripe)' : 'Club'}
                        {r.posReference ? ` · ${r.posReference}` : ''}
                      </span>
                      <span className="text-xs text-gray-500" title={r.reason}>{r.reason.slice(0, 30)}{r.reason.length > 30 ? '...' : ''}</span>
                    </div>
                  ))}
                </div>
              )}

              {detail.reconciledAt ? (
                <div className="rounded-lg border border-gray-800 p-4 text-sm text-gray-400">
                  Closed on {new Date(detail.reconciledAt).toLocaleString()}
                  {detail.reconciliationOverrideReason && (
                    <div className="mt-1 text-amber-400">Override reason: {detail.reconciliationOverrideReason}</div>
                  )}
                </div>
              ) : (
                <div className="space-y-3 rounded-lg border border-gray-800 p-4">
                  {flags.length > 0 && (
                    <div className="space-y-1">
                      <Label className="text-xs">Override reason (required - differences are still unresolved)</Label>
                      <Textarea value={overrideReason} onChange={(e) => setOverrideReason(e.target.value)} />
                    </div>
                  )}
                  <Button
                    className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
                    disabled={closing}
                    onClick={handleClose}
                  >
                    {closing ? 'Closing...' : 'Close Table'}
                  </Button>
                </div>
              )}
            </div>
          </>
        )}
      </SheetContent>
    </Sheet>
  );
};

export default TableReconciliationSheet;
