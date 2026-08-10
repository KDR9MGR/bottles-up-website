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
import { Mail } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { sessionMode, type PaymentModeFilter } from '../lib/paymentMode';
import type { Database, OrderStatus } from '@/types/database';

type OrderRow = Database['public']['Tables']['site_orders']['Row'] & {
  events: { title: string } | null;
  ticket_tiers: { name: string } | null;
};

const statusVariant: Record<OrderStatus, 'default' | 'secondary' | 'destructive'> = {
  paid: 'default',
  pending: 'secondary',
  failed: 'destructive',
  refunded: 'destructive',
};

const CmsBookings = () => {
  const { toast } = useToast();
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [statusFilter, setStatusFilter] = useState<OrderStatus | 'all'>('all');
  const [modeFilter, setModeFilter] = useState<PaymentModeFilter>('live');
  const [loading, setLoading] = useState(true);
  const [resendingId, setResendingId] = useState<string | null>(null);

  const loadOrders = async () => {
    setLoading(true);
    const { data } = await supabase
      .from('site_orders')
      .select('*, events:site_events(title), ticket_tiers:site_ticket_tiers(name)')
      .order('created_at', { ascending: false });
    setOrders((data as OrderRow[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadOrders();
  }, []);

  const filtered = useMemo(
    () =>
      orders
        .filter((o) => statusFilter === 'all' || o.status === statusFilter)
        .filter((o) => modeFilter === 'all' || sessionMode(o.stripe_checkout_session_id) === modeFilter),
    [orders, statusFilter, modeFilter],
  );

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

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">Bookings ({filtered.length})</h1>
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
