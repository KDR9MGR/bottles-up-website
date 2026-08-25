import { useEffect, useMemo, useState } from 'react';
import { format, parseISO } from 'date-fns';
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
import { Mail, RefreshCw, Download } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { sessionMode, type PaymentModeFilter } from '../lib/paymentMode';
import type { Database, OrderStatus } from '@/types/database';

type OrderRow = Database['public']['Tables']['site_orders']['Row'] & {
  events: { title: string; start_date: string } | null;
  ticket_tiers: { name: string } | null;
};
type EventOption = { id: string; title: string; start_date: string };

const statusVariant: Record<OrderStatus, 'default' | 'secondary' | 'destructive'> = {
  paid: 'default',
  pending: 'secondary',
  failed: 'destructive',
  refunded: 'destructive',
};

const csvEscape = (value: string) => `"${value.replace(/"/g, '""')}"`;

const CmsBookings = () => {
  const { toast } = useToast();
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [events, setEvents] = useState<EventOption[]>([]);
  const [statusFilter, setStatusFilter] = useState<OrderStatus | 'all'>('all');
  const [modeFilter, setModeFilter] = useState<PaymentModeFilter>('live');
  const [eventFilter, setEventFilter] = useState<string>('all');
  const [loading, setLoading] = useState(true);
  const [resendingId, setResendingId] = useState<string | null>(null);
  const [checkingId, setCheckingId] = useState<string | null>(null);

  const loadOrders = async () => {
    setLoading(true);
    const [ordersRes, eventsRes] = await Promise.all([
      supabase
        .from('site_orders')
        .select('*, events:site_events(title, start_date), ticket_tiers:site_ticket_tiers(name)')
        .order('created_at', { ascending: false }),
      supabase.from('site_events').select('id, title, start_date').order('start_date', { ascending: false }),
    ]);
    setOrders((ordersRes.data as OrderRow[]) ?? []);
    setEvents((eventsRes.data as EventOption[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadOrders();
  }, []);

  // Stat cards ignore the status filter (so all four always show the full
  // breakdown) but still respect payment mode + event scoping, since those
  // narrow "which orders are we even looking at" rather than "which subset
  // of statuses to display".
  const scoped = useMemo(
    () =>
      orders
        .filter((o) => modeFilter === 'all' || sessionMode(o.stripe_checkout_session_id) === modeFilter)
        .filter((o) => eventFilter === 'all' || o.event_id === eventFilter),
    [orders, modeFilter, eventFilter],
  );
  const filtered = useMemo(
    () => scoped.filter((o) => statusFilter === 'all' || o.status === statusFilter),
    [scoped, statusFilter],
  );

  const stats = useMemo(() => {
    const sum = (rows: OrderRow[]) => rows.reduce((acc, o) => acc + o.amount_total_cents, 0);
    const paid = scoped.filter((o) => o.status === 'paid');
    const pending = scoped.filter((o) => o.status === 'pending');
    const failed = scoped.filter((o) => o.status === 'failed');
    const checkedIn = scoped.filter((o) => o.checked_in_at);
    return {
      paid: { count: paid.length, cents: sum(paid) },
      pending: { count: pending.length, cents: sum(pending) },
      failed: { count: failed.length, cents: sum(failed) },
      checkedIn: { count: checkedIn.length, ofSold: paid.length },
    };
  }, [scoped]);

  const selectedEvent = eventFilter === 'all' ? null : events.find((e) => e.id === eventFilter) ?? null;

  const handleResend = async (orderId: string) => {
    setResendingId(orderId);
    const { data, error } = await supabase.functions.invoke('resend-ticket-email', {
      body: { order_id: orderId },
    });
    setResendingId(null);

    if (error || data?.error) {
      toast({
        title: 'Failed to resend ticket',
        description: data?.error ?? error?.message,
        variant: 'destructive',
      });
    } else {
      toast({ title: 'Ticket email resent' });
      loadOrders();
    }
  };

  // A pending order can mean the webhook that normally marks it paid hasn't run yet
  // (or never will, if it's misconfigured) even though Stripe already has a real
  // charge. This re-uses the same check-with-Stripe fallback the booking-success
  // page calls automatically, so an admin can trigger it manually for any order
  // that's stuck instead of waiting on the customer to reload their success page.
  // Also doubles as "Retry" for a failed order - same recheck, different label.
  const handleCheckStripe = async (order: OrderRow) => {
    if (!order.stripe_checkout_session_id) {
      toast({ title: 'No Stripe session on this order', variant: 'destructive' });
      return;
    }
    setCheckingId(order.id);
    const { data, error } = await supabase.functions.invoke('site-booking-status', {
      body: { session_id: order.stripe_checkout_session_id },
    });
    setCheckingId(null);

    if (error) {
      toast({ title: 'Failed to check with Stripe', description: error.message, variant: 'destructive' });
      return;
    }
    if (data?.status === 'paid') {
      toast({ title: 'Stripe confirms this was paid', description: 'Order marked paid and ticket sent.' });
      loadOrders();
    } else {
      toast({
        title: 'Stripe confirms this was not completed',
        description: 'No successful charge found for this checkout session - the customer likely never finished paying.',
      });
    }
  };

  const handleExportCsv = () => {
    const header = ['Customer', 'Email', 'Event', 'Tier', 'Qty', 'Total', 'Status', 'Ticket Code', 'Created At'];
    const rows = filtered.map((o) => [
      o.customer_name,
      o.customer_email,
      o.events?.title ?? '',
      o.ticket_tiers?.name ?? '',
      String(o.quantity),
      (o.amount_total_cents / 100).toFixed(2),
      o.status,
      o.ticket_code ?? '',
      o.created_at,
    ]);
    const csv = [header, ...rows].map((row) => row.map(csvEscape).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `bookings-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div>
      <div className="mb-1 flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">
          {filtered.length} {filtered.length === 1 ? 'booking' : 'bookings'}
          {selectedEvent && (
            <span className="ml-2 text-lg font-normal text-gray-400">
              · {selectedEvent.title} · {format(parseISO(selectedEvent.start_date), 'EEE d MMM')}
            </span>
          )}
        </h1>
        <div className="flex gap-2">
          <Select value={eventFilter} onValueChange={setEventFilter}>
            <SelectTrigger className="w-44">
              <SelectValue placeholder="All events" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All events</SelectItem>
              {events.map((e) => (
                <SelectItem key={e.id} value={e.id}>
                  {e.title}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
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
          <Button variant="outline" onClick={handleExportCsv} disabled={filtered.length === 0}>
            <Download className="mr-2 h-4 w-4" />
            Export CSV
          </Button>
        </div>
      </div>

      <div className="my-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div className="rounded-lg border border-gray-800 p-4">
          <div className="flex items-center gap-1.5 text-xs text-gray-500">
            <span className="h-1.5 w-1.5 rounded-full bg-orange-500" />
            Paid
          </div>
          <div className="mt-1 text-2xl font-bold text-white">{stats.paid.count}</div>
          <div className="text-xs text-gray-500">${(stats.paid.cents / 100).toFixed(2)}</div>
        </div>
        <div className="rounded-lg border border-gray-800 p-4">
          <div className="flex items-center gap-1.5 text-xs text-gray-500">
            <span className="h-1.5 w-1.5 rounded-full bg-orange-500" />
            Pending
          </div>
          <div className="mt-1 text-2xl font-bold text-white">{stats.pending.count}</div>
          <div className="text-xs text-gray-500">${(stats.pending.cents / 100).toFixed(2)}</div>
        </div>
        <div className="rounded-lg border border-gray-800 p-4">
          <div className="flex items-center gap-1.5 text-xs text-gray-500">
            <span className="h-1.5 w-1.5 rounded-full bg-red-500" />
            Failed
          </div>
          <div className="mt-1 text-2xl font-bold text-white">{stats.failed.count}</div>
          <div className="text-xs text-gray-500">${(stats.failed.cents / 100).toFixed(2)}</div>
        </div>
        <div className="rounded-lg border border-gray-800 p-4">
          <div className="flex items-center gap-1.5 text-xs text-gray-500">
            <span className="h-1.5 w-1.5 rounded-full bg-gray-500" />
            Checked in
          </div>
          <div className="mt-1 text-2xl font-bold text-white">{stats.checkedIn.count}</div>
          <div className="text-xs text-gray-500">of {stats.checkedIn.ofSold} sold</div>
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
                <TableHead>Event</TableHead>
                <TableHead>Tier</TableHead>
                <TableHead>Qty</TableHead>
                <TableHead>Total</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Ticket Code</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((order) => (
                <TableRow key={order.id}>
                  <TableCell>
                    <div>{order.customer_name}</div>
                    <div className="text-xs text-gray-500">{order.customer_email}</div>
                  </TableCell>
                  <TableCell>{order.events?.title ?? '-'}</TableCell>
                  <TableCell>{order.ticket_tiers?.name ?? '-'}</TableCell>
                  <TableCell>{order.quantity}</TableCell>
                  <TableCell>${(order.amount_total_cents / 100).toFixed(2)}</TableCell>
                  <TableCell>
                    <Badge variant={statusVariant[order.status]}>{order.status}</Badge>
                  </TableCell>
                  <TableCell className="font-mono text-xs">{order.ticket_code ?? '-'}</TableCell>
                  <TableCell className="text-right">
                    {(order.status === 'pending' || order.status === 'failed') && (
                      <Button
                        size="sm"
                        variant="ghost"
                        disabled={checkingId === order.id}
                        onClick={() => handleCheckStripe(order)}
                      >
                        <RefreshCw className="mr-1 h-3 w-3" />
                        {checkingId === order.id
                          ? 'Checking...'
                          : order.status === 'failed'
                            ? 'Retry'
                            : 'Check with Stripe'}
                      </Button>
                    )}
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={order.status !== 'paid' || resendingId === order.id}
                      onClick={() => handleResend(order.id)}
                    >
                      <Mail className="mr-1 h-3 w-3" />
                      {resendingId === order.id ? 'Sending...' : 'Resend'}
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
              {filtered.length === 0 && (
                <TableRow>
                  <TableCell colSpan={8} className="text-center text-gray-500">
                    No bookings yet.
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

export default CmsBookings;
