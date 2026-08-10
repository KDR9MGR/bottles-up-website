import { useEffect, useMemo, useState } from 'react';
import { format, subDays, startOfDay, isAfter } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid } from 'recharts';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { supabase } from '@/lib/supabase';
import { sessionMode, type PaymentModeFilter } from '../lib/paymentMode';

type EventWithTiers = {
  id: string;
  title: string;
  status: string;
  site_ticket_tiers: { capacity: number; sold_count: number }[];
};

type PaidOrder = {
  id: string;
  event_id: string;
  customer_name: string;
  customer_email: string;
  amount_total_cents: number;
  quantity: number;
  checked_in_at: string | null;
  created_at: string;
  stripe_checkout_session_id: string | null;
};

const formatCurrency = (cents: number) =>
  `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

const CmsDashboard = () => {
  const [events, setEvents] = useState<EventWithTiers[]>([]);
  const [orders, setOrders] = useState<PaidOrder[]>([]);
  const [doorStaffCount, setDoorStaffCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [modeFilter, setModeFilter] = useState<PaymentModeFilter>('live');

  useEffect(() => {
    const load = async () => {
      const [{ data: eventsData }, { data: ordersData }, doorStaff] = await Promise.all([
        supabase.from('site_events').select('id, title, status, site_ticket_tiers(capacity, sold_count)'),
        supabase
          .from('site_orders')
          .select(
            'id, event_id, customer_name, customer_email, amount_total_cents, quantity, checked_in_at, created_at, stripe_checkout_session_id',
          )
          .eq('status', 'paid'),
        supabase.from('door_staff').select('id', { count: 'exact', head: true }),
      ]);

      setEvents((eventsData as unknown as EventWithTiers[]) ?? []);
      setOrders((ordersData as PaidOrder[]) ?? []);
      setDoorStaffCount(doorStaff.count ?? 0);
      setLoading(false);
    };

    load();
  }, []);

  const paidOrders = useMemo(
    () =>
      modeFilter === 'all'
        ? orders
        : orders.filter((o) => sessionMode(o.stripe_checkout_session_id) === modeFilter),
    [orders, modeFilter],
  );

  const kpis = useMemo(() => {
    const now = new Date();
    const todayStart = startOfDay(now);
    const weekStart = subDays(now, 7);

    const totalRevenue = paidOrders.reduce((sum, o) => sum + o.amount_total_cents, 0);
    const revenueToday = paidOrders
      .filter((o) => isAfter(new Date(o.created_at), todayStart))
      .reduce((sum, o) => sum + o.amount_total_cents, 0);
    const revenueWeek = paidOrders
      .filter((o) => isAfter(new Date(o.created_at), weekStart))
      .reduce((sum, o) => sum + o.amount_total_cents, 0);
    const ticketsSold = paidOrders.reduce((sum, o) => sum + o.quantity, 0);
    const ticketsCheckedIn = paidOrders.filter((o) => o.checked_in_at).length;

    // Capacity is mode-independent (it's a fixed tier setting), but "sold" is derived
    // from the mode-filtered orders themselves rather than the tier's blended sold_count
    // column - otherwise switching Live/Test wouldn't change the occupancy number.
    const totalCapacity = events.reduce(
      (sum, e) => sum + e.site_ticket_tiers.reduce((s, t) => s + t.capacity, 0),
      0,
    );
    const occupancy = totalCapacity > 0 ? Math.round((ticketsSold / totalCapacity) * 100) : 0;

    return { totalRevenue, revenueToday, revenueWeek, ticketsSold, ticketsCheckedIn, occupancy };
  }, [paidOrders, events]);

  const trend = useMemo(() => {
    const days = 14;
    const buckets: Record<string, number> = {};
    for (let i = days - 1; i >= 0; i--) {
      buckets[format(startOfDay(subDays(new Date(), i)), 'MMM d')] = 0;
    }
    paidOrders.forEach((o) => {
      const key = format(startOfDay(new Date(o.created_at)), 'MMM d');
      if (key in buckets) buckets[key] += o.amount_total_cents / 100;
    });
    return Object.entries(buckets).map(([date, revenue]) => ({ date, revenue }));
  }, [paidOrders]);

  const eventPerformance = useMemo(
    () =>
      events
        .map((e) => {
          const capacity = e.site_ticket_tiers.reduce((s, t) => s + t.capacity, 0);
          const eventOrders = paidOrders.filter((o) => o.event_id === e.id);
          const sold = eventOrders.reduce((s, o) => s + o.quantity, 0);
          const revenue = eventOrders.reduce((s, o) => s + o.amount_total_cents, 0);
          const checkedIn = eventOrders.filter((o) => o.checked_in_at).length;
          return {
            id: e.id,
            title: e.title,
            status: e.status,
            capacity,
            sold,
            occupancy: capacity > 0 ? Math.round((sold / capacity) * 100) : 0,
            revenue,
            checkedIn,
          };
        })
        .sort((a, b) => b.revenue - a.revenue),
    [events, paidOrders],
  );

  const topCustomers = useMemo(() => {
    const map = new Map<string, { name: string; email: string; orders: number; spend: number }>();
    paidOrders.forEach((o) => {
      const existing = map.get(o.customer_email) ?? {
        name: o.customer_name,
        email: o.customer_email,
        orders: 0,
        spend: 0,
      };
      existing.orders += 1;
      existing.spend += o.amount_total_cents;
      map.set(o.customer_email, existing);
    });
    return Array.from(map.values())
      .sort((a, b) => b.spend - a.spend)
      .slice(0, 10);
  }, [paidOrders]);

  const cards = [
    { label: 'Total Revenue', value: formatCurrency(kpis.totalRevenue) },
    { label: 'Revenue Today', value: formatCurrency(kpis.revenueToday) },
    { label: 'Revenue This Week', value: formatCurrency(kpis.revenueWeek) },
    { label: 'Tickets Sold', value: kpis.ticketsSold },
    { label: 'Tickets Checked In', value: kpis.ticketsCheckedIn },
    { label: 'Occupancy', value: `${kpis.occupancy}%` },
    { label: 'Door Staff', value: doorStaffCount },
  ];

  if (loading) {
    return <div className="text-gray-400">Loading...</div>;
  }

  return (
    <div className="space-y-8">
      <div>
        <div className="mb-6 flex items-center justify-between">
          <h1 className="text-2xl font-bold text-white">Dashboard</h1>
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
        </div>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {cards.map((card) => (
            <Card key={card.label} className="border-gray-800 bg-gray-900/50">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-gray-400">{card.label}</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-3xl font-bold text-white">{card.value}</div>
              </CardContent>
            </Card>
          ))}
        </div>
      </div>

      <Card className="border-gray-800 bg-gray-900/50">
        <CardHeader>
          <CardTitle className="text-white">Revenue - Last 14 Days</CardTitle>
        </CardHeader>
        <CardContent className="h-64">
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={trend}>
              <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
              <XAxis dataKey="date" stroke="#9ca3af" fontSize={12} />
              <YAxis stroke="#9ca3af" fontSize={12} tickFormatter={(v) => `$${v}`} />
              <Tooltip
                contentStyle={{ background: '#111827', border: '1px solid #374151', color: '#fff' }}
                formatter={(value: number) => [`$${value.toFixed(2)}`, 'Revenue']}
              />
              <Line type="monotone" dataKey="revenue" stroke="#f97316" strokeWidth={2} dot={false} />
            </LineChart>
          </ResponsiveContainer>
        </CardContent>
      </Card>

      <div>
        <h2 className="mb-3 text-lg font-semibold text-white">Event Performance</h2>
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Event</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Capacity</TableHead>
                <TableHead>Sold</TableHead>
                <TableHead>Occupancy</TableHead>
                <TableHead>Revenue</TableHead>
                <TableHead>Checked In</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {eventPerformance.map((e) => (
                <TableRow key={e.id}>
                  <TableCell>{e.title}</TableCell>
                  <TableCell className="capitalize">{e.status}</TableCell>
                  <TableCell>{e.capacity}</TableCell>
                  <TableCell>{e.sold}</TableCell>
                  <TableCell>{e.occupancy}%</TableCell>
                  <TableCell>{formatCurrency(e.revenue)}</TableCell>
                  <TableCell>{e.checkedIn}</TableCell>
                </TableRow>
              ))}
              {eventPerformance.length === 0 && (
                <TableRow>
                  <TableCell colSpan={7} className="text-center text-gray-500">
                    No events yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      </div>

      <div>
        <h2 className="mb-3 text-lg font-semibold text-white">Top Customers</h2>
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Customer</TableHead>
                <TableHead>Orders</TableHead>
                <TableHead>Total Spend</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {topCustomers.map((c) => (
                <TableRow key={c.email}>
                  <TableCell>
                    <div>{c.name}</div>
                    <div className="text-xs text-gray-500">{c.email}</div>
                  </TableCell>
                  <TableCell>{c.orders}</TableCell>
                  <TableCell>{formatCurrency(c.spend)}</TableCell>
                </TableRow>
              ))}
              {topCustomers.length === 0 && (
                <TableRow>
                  <TableCell colSpan={3} className="text-center text-gray-500">
                    No paid orders yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      </div>
    </div>
  );
};

export default CmsDashboard;
