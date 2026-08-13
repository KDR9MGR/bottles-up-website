import { useEffect, useMemo, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
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
import { Mail, RefreshCw } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { sessionMode, type PaymentModeFilter } from '../lib/paymentMode';
import type { Database, FulfillmentStatus, OrderStatus } from '@/types/database';

type BookingRow = Database['public']['Tables']['site_table_bookings']['Row'] & {
  site_venues: { name: string } | null;
  site_table_types: { name: string } | null;
  site_table_booking_bottles: { bottle_name: string; size: string | null; quantity: number }[];
};

const statusVariant: Record<OrderStatus, 'default' | 'secondary' | 'destructive'> = {
  paid: 'default',
  pending: 'secondary',
  failed: 'destructive',
  refunded: 'destructive',
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
  const [loading, setLoading] = useState(true);
  const [resendingId, setResendingId] = useState<string | null>(null);
  const [checkingId, setCheckingId] = useState<string | null>(null);

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

  const filtered = useMemo(
    () =>
      bookings
        .filter((b) => statusFilter === 'all' || b.status === statusFilter)
        .filter((b) => modeFilter === 'all' || sessionMode(b.stripe_checkout_session_id) === modeFilter),
    [bookings, statusFilter, modeFilter],
  );

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

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">Table Bookings ({filtered.length})</h1>
        <div className="flex gap-2">
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
    </div>
  );
};

export default CmsTableBookings;
