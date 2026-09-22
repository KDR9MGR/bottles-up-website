import { useEffect, useMemo, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Input } from '@/components/ui/input';
import { Mail, RefreshCw, Ban, Trash2, Search, Eye } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { logAudit } from '@/lib/auditLog';
import { cancelTableBooking } from '@/lib/bottleExceptions';
import { sessionMode, type PaymentModeFilter } from '../lib/paymentMode';
import TableBookingDetailSheet from '../components/TableBookingDetailSheet';
import type { Database, FulfillmentStatus, OrderStatus } from '@/types/database';

type BookingRow = Database['public']['Tables']['site_table_bookings']['Row'] & {
  site_venues: { name: string } | null;
  site_table_types: { name: string } | null;
  site_table_booking_bottles: { bottle_name: string; size: string | null; quantity: number }[];
};

const statusVariant: Record<OrderStatus, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  paid: 'default',
  pending: 'secondary',
  failed: 'destructive',
  refunded: 'destructive',
  cancelled: 'outline',
};

const FULFILLMENT_LABELS: Record<FulfillmentStatus, string> = {
  confirmed: 'Confirmed',
  preparing: 'Preparing',
  served: 'Served',
  completed: 'Completed',
};

const CmsTableBookings = () => {
  const { toast } = useToast();
  const [bookings, setBookings] = useState<BookingRow[]>([]);
  const [statusFilter, setStatusFilter] = useState<OrderStatus | 'all'>('all');
  const [modeFilter, setModeFilter] = useState<PaymentModeFilter>('live');
  const [search, setSearch] = useState('');
  const [openBookingId, setOpenBookingId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [resendingId, setResendingId] = useState<string | null>(null);
  const [checkingId, setCheckingId] = useState<string | null>(null);
  const [cancelTarget, setCancelTarget] = useState<BookingRow | null>(null);
  const [cancelReason, setCancelReason] = useState('');
  const [cancelling, setCancelling] = useState(false);
  const [removeTarget, setRemoveTarget] = useState<BookingRow | null>(null);
  const [removeReason, setRemoveReason] = useState('');
  const [removing, setRemoving] = useState(false);

  const loadBookings = async () => {
    setLoading(true);
    const { data } = await supabase
      .from('site_table_bookings')
      .select('*, site_venues(name), site_table_types(name), site_table_booking_bottles(bottle_name, size, quantity)')
      .order('created_at', { ascending: false });
    setBookings((data as BookingRow[]) ?? []);
    setLoading(false);
  };

  const handleFulfillmentChange = async (bookingId: string, status: FulfillmentStatus) => {
    const { error } = await supabase.from('site_table_bookings').update({ fulfillment_status: status }).eq('id', bookingId);
    if (error) {
      toast({ title: 'Failed to update status', description: error.message, variant: 'destructive' });
      return;
    }
    setBookings((prev) => prev.map((b) => (b.id === bookingId ? { ...b, fulfillment_status: status } : b)));
  };

  useEffect(() => {
    loadBookings();
  }, []);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return bookings
      .filter((b) => statusFilter === 'all' || b.status === statusFilter)
      .filter((b) => modeFilter === 'all' || sessionMode(b.stripe_checkout_session_id) === modeFilter)
      .filter(
        (b) =>
          !q ||
          b.customer_name.toLowerCase().includes(q) ||
          b.customer_email.toLowerCase().includes(q) ||
          (b.confirmation_code ?? '').toLowerCase().includes(q) ||
          (b.site_venues?.name ?? '').toLowerCase().includes(q) ||
          (b.site_table_types?.name ?? '').toLowerCase().includes(q),
      );
  }, [bookings, statusFilter, modeFilter, search]);

  const handleResend = async (bookingId: string) => {
    setResendingId(bookingId);
    const { data, error } = await supabase.functions.invoke('resend-table-booking-email', {
      body: { booking_id: bookingId },
    });
    setResendingId(null);

    if (error || data?.error) {
      toast({
        title: 'Failed to resend confirmation',
        description: data?.error ?? error?.message,
        variant: 'destructive',
      });
    } else {
      toast({ title: 'Confirmation email resent' });
      loadBookings();
    }
  };

  // Same self-heal fallback the booking-success page uses automatically - lets an
  // admin manually re-check a stuck pending booking against Stripe on demand.
  const handleCheckStripe = async (booking: BookingRow) => {
    if (!booking.stripe_checkout_session_id) {
      toast({ title: 'No Stripe session on this booking', variant: 'destructive' });
      return;
    }
    setCheckingId(booking.id);
    const { data, error } = await supabase.functions.invoke('site-booking-status', {
      body: { session_id: booking.stripe_checkout_session_id },
    });
    setCheckingId(null);

    if (error) {
      toast({ title: 'Failed to check with Stripe', description: error.message, variant: 'destructive' });
      return;
    }
    if (data?.status === 'paid') {
      toast({ title: 'Stripe confirms this was paid', description: 'Booking marked paid and confirmation sent.' });
      loadBookings();
    } else {
      toast({
        title: 'Stripe confirms this was not completed',
        description: 'No successful charge found for this checkout session - the customer likely never finished paying.',
      });
    }
  };

  // Only offered for paid bookings. Keeps the row (with a required reason) instead of
  // deleting outright - a real completed payment should never disappear with no
  // trace. Routed through the same cancel-table-booking edge function the CMS
  // booking detail sheet uses (Bottle Payment Options section 9) - that one also
  // cascades the cancellation to every active bottle line and recomputes totals,
  // which a bare status update here never did.
  const submitCancel = async () => {
    if (!cancelTarget || !cancelReason.trim()) return;
    setCancelling(true);
    try {
      const result = await cancelTableBooking(cancelTarget.id, cancelReason.trim());
      toast({
        title: 'Booking cancelled',
        description: result.refundSuggested ? 'This booking had money collected - consider recording a refund.' : undefined,
      });
      setCancelTarget(null);
      setCancelReason('');
      loadBookings();
    } catch (err) {
      toast({ title: 'Failed to cancel booking', description: err instanceof Error ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setCancelling(false);
    }
  };

  // One click, for anything that was never a completed payment (pending/failed) or
  // was already explicitly cancelled - never offered for paid/refunded, and the
  // database itself enforces that too (see the "admins delete non-financial table
  // bookings" RLS policy), so this can't be used to erase real revenue even by
  // mistake. The full row is snapshotted to audit_log first, so nothing is truly
  // lost, and deleting it is what actually clears the way for the table type's own
  // delete to succeed.
  const submitRemove = async () => {
    if (!removeTarget || !removeReason.trim()) return;
    setRemoving(true);

    await logAudit({
      action: 'table_booking.removed',
      entityType: 'site_table_bookings',
      entityId: removeTarget.id,
      details: { reason: removeReason.trim(), booking: removeTarget },
    });

    const { error: bottlesError } = await supabase
      .from('site_table_booking_bottles')
      .delete()
      .eq('booking_id', removeTarget.id);
    if (bottlesError) {
      setRemoving(false);
      toast({ title: 'Failed to remove booking', description: bottlesError.message, variant: 'destructive' });
      return;
    }

    // Ask for the affected row count explicitly - a delete RLS blocks silently (no
    // error, zero rows), which is exactly the bug this replaces, so it's worth
    // double-checking rather than trusting an error-free response alone.
    const { error, count } = await supabase
      .from('site_table_bookings')
      .delete({ count: 'exact' })
      .eq('id', removeTarget.id);
    setRemoving(false);

    if (error) {
      toast({ title: 'Failed to remove booking', description: error.message, variant: 'destructive' });
      return;
    }
    if (!count) {
      toast({
        title: 'Nothing was removed',
        description: "This booking is no longer in a removable status - refresh the list and check its current status.",
        variant: 'destructive',
      });
      loadBookings();
      return;
    }

    toast({ title: 'Booking removed' });
    setRemoveTarget(null);
    setRemoveReason('');
    loadBookings();
  };

  return (
    <div>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-bold text-white">Table Bookings ({filtered.length})</h1>
        <div className="flex flex-wrap gap-2">
          <div className="relative">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-500" />
            <Input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search name, email, code, venue..."
              className="w-64 pl-8"
            />
          </div>
          <Select value={modeFilter} onValueChange={(v) => setModeFilter(v as PaymentModeFilter)}>
            <SelectTrigger className="w-36">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="live">Live payments</SelectItem>
              <SelectItem value="test">Test payments</SelectItem>
              <SelectItem value="all">All</SelectItem>
            </SelectContent>
          </Select>
          <Select value={statusFilter} onValueChange={(v) => setStatusFilter(v as OrderStatus | 'all')}>
            <SelectTrigger className="w-40">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All statuses</SelectItem>
              <SelectItem value="pending">Pending</SelectItem>
              <SelectItem value="paid">Paid</SelectItem>
              <SelectItem value="failed">Failed</SelectItem>
              <SelectItem value="refunded">Refunded</SelectItem>
              <SelectItem value="cancelled">Cancelled</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Customer</TableHead>
                <TableHead>Venue</TableHead>
                <TableHead>Table</TableHead>
                <TableHead>Date</TableHead>
                <TableHead>Guests</TableHead>
                <TableHead>Bottles</TableHead>
                <TableHead>Total</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Fulfillment</TableHead>
                <TableHead>Code</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((booking) => (
                <TableRow key={booking.id}>
                  <TableCell>
                    <div>{booking.customer_name}</div>
                    <div className="text-xs text-gray-500">{booking.customer_email}</div>
                  </TableCell>
                  <TableCell>{booking.site_venues?.name ?? '-'}</TableCell>
                  <TableCell>{booking.site_table_types?.name ?? '-'}</TableCell>
                  <TableCell>{booking.booking_date}</TableCell>
                  <TableCell>{booking.guest_count}</TableCell>
                  <TableCell className="max-w-[180px] text-xs text-gray-400">
                    {booking.site_table_booking_bottles.length === 0
                      ? '-'
                      : booking.site_table_booking_bottles.map((b) => `${b.bottle_name} x${b.quantity}`).join(', ')}
                  </TableCell>
                  <TableCell>${(booking.amount_total_cents / 100).toFixed(2)}</TableCell>
                  <TableCell>
                    <Badge variant={statusVariant[booking.status]}>{booking.status}</Badge>
                    {booking.status === 'cancelled' && booking.cancellation_reason && (
                      <div className="mt-1 max-w-[160px] text-xs text-gray-500" title={booking.cancellation_reason}>
                        {booking.cancellation_reason}
                      </div>
                    )}
                  </TableCell>
                  <TableCell>
                    <Select
                      value={booking.fulfillment_status}
                      onValueChange={(v) => handleFulfillmentChange(booking.id, v as FulfillmentStatus)}
                      disabled={booking.status !== 'paid'}
                    >
                      <SelectTrigger className="h-8 w-32 text-xs">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {(Object.keys(FULFILLMENT_LABELS) as FulfillmentStatus[]).map((s) => (
                          <SelectItem key={s} value={s}>
                            {FULFILLMENT_LABELS[s]}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </TableCell>
                  <TableCell className="font-mono text-xs">{booking.confirmation_code ?? '-'}</TableCell>
                  <TableCell className="text-right">
                    <Button size="sm" variant="ghost" onClick={() => setOpenBookingId(booking.id)}>
                      <Eye className="mr-1 h-3 w-3" />
                      Open
                    </Button>
                    {booking.status === 'pending' && (
                      <Button
                        size="sm"
                        variant="ghost"
                        disabled={checkingId === booking.id}
                        onClick={() => handleCheckStripe(booking)}
                      >
                        <RefreshCw className="mr-1 h-3 w-3" />
                        {checkingId === booking.id ? 'Checking...' : 'Check with Stripe'}
                      </Button>
                    )}
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={booking.status !== 'paid' || resendingId === booking.id}
                      onClick={() => handleResend(booking.id)}
                    >
                      <Mail className="mr-1 h-3 w-3" />
                      {resendingId === booking.id ? 'Sending...' : 'Resend'}
                    </Button>
                    {booking.status === 'paid' && (
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => {
                          setCancelTarget(booking);
                          setCancelReason('');
                        }}
                      >
                        <Ban className="mr-1 h-3 w-3" />
                        Cancel
                      </Button>
                    )}
                    {(booking.status === 'pending' || booking.status === 'failed' || booking.status === 'cancelled') && (
                      <Button
                        size="sm"
                        variant="ghost"
                        className="text-red-400 hover:text-red-300"
                        onClick={() => {
                          setRemoveTarget(booking);
                          setRemoveReason('');
                        }}
                      >
                        <Trash2 className="mr-1 h-3 w-3" />
                        Remove
                      </Button>
                    )}
                  </TableCell>
                </TableRow>
              ))}
              {filtered.length === 0 && (
                <TableRow>
                  <TableCell colSpan={11} className="text-center text-gray-500">
                    No table bookings yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      )}

      <Dialog open={!!cancelTarget} onOpenChange={(open) => !open && setCancelTarget(null)}>
        <DialogContent className="border-gray-800 bg-gray-950">
          <DialogHeader>
            <DialogTitle className="text-white">Cancel booking</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <p className="text-sm text-gray-400">
              {cancelTarget?.customer_name} - {cancelTarget?.site_table_types?.name ?? 'table'} on{' '}
              {cancelTarget?.booking_date}. The booking stays on record as "cancelled" with this reason - nothing
              is deleted yet.
            </p>
            <div className="space-y-2">
              <Label>Reason (required)</Label>
              <Textarea
                value={cancelReason}
                onChange={(e) => setCancelReason(e.target.value)}
                placeholder="e.g. test booking while setting up this venue"
                rows={3}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCancelTarget(null)}>
              Back
            </Button>
            <Button
              onClick={submitCancel}
              disabled={!cancelReason.trim() || cancelling}
              className="bg-gradient-orange text-black font-bold hover:opacity-90"
            >
              {cancelling ? 'Cancelling...' : 'Cancel Booking'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={!!removeTarget} onOpenChange={(open) => !open && setRemoveTarget(null)}>
        <DialogContent className="border-gray-800 bg-gray-950">
          <DialogHeader>
            <DialogTitle className="text-white">Remove booking</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <p className="text-sm text-gray-400">
              {removeTarget?.customer_name} - {removeTarget?.site_table_types?.name ?? 'table'} on{' '}
              {removeTarget?.booking_date}. This takes it off the bookings list for good - a full copy (plus this
              reason) is kept in the audit log. Do this to finish clearing a test table so it can be deleted.
            </p>
            <div className="space-y-2">
              <Label>Reason (required)</Label>
              <Textarea
                value={removeReason}
                onChange={(e) => setRemoveReason(e.target.value)}
                placeholder="e.g. test booking while setting up this venue"
                rows={3}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setRemoveTarget(null)}>
              Back
            </Button>
            <Button
              onClick={submitRemove}
              disabled={!removeReason.trim() || removing}
              className="bg-red-600 text-white hover:bg-red-700"
            >
              {removing ? 'Removing...' : 'Remove Booking'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <TableBookingDetailSheet
        bookingId={openBookingId}
        onOpenChange={(open) => !open && setOpenBookingId(null)}
        onUpdated={loadBookings}
      />
    </div>
  );
};

export default CmsTableBookings;
