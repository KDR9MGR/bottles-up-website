import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { format, subDays, startOfDay, isAfter } from 'date-fns';
import { formatDistanceToNow } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { ResponsiveContainer, BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid, Legend } from 'recharts';
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

type TableBooking = {
  id: string;
  booking_date: string;
  deposit_cents: number;
  status: string;
  stripe_checkout_session_id: string | null;
  created_at: string;
};

type AuditEntry = {
  id: string;
  actor_email: string;
  action: string;
  entity_type: string;
  details: Record<string, unknown> | null;
  created_at: string;
};

const formatCurrency = (cents: number) =>
  `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

// Turns "ticket.resent" -> "Ticket resent", "table_booking.checked_in" -> "Table booking checked in" -
// audit_log actions are free-form dotted/underscored strings, not a fixed enum, so this is a display
// heuristic rather than a lookup table.
const describeAction = (action: string) => {
  const cleaned = action.replace(/[._]/g, ' ');
  return cleaned.charAt(0).toUpperCase() + cleaned.slice(1);
};

const CmsDashboard = () => {
  const [events, setEvents] = useState<EventWithTiers[]>([]);
  const [orders, setOrders] = useState<PaidOrder[]>([]);
  const [tableBookings, setTableBookings] = useState<TableBooking[]>([]);
  const [doorStaffCount, setDoorStaffCount] = useState(0);
  const [vipGuestCount, setVipGuestCount] = useState(0);
  const [refundCount, setRefundCount] = useState(0);
  const [activity, setActivity] = useState<AuditEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [modeFilter, setModeFilter] = useState<PaymentModeFilter>('live');

  useEffect(() => {
    const load = async () => {
      const [
        { data: eventsData },
        { data: ordersData },
        { data: tableBookingsData },
        doorStaff,
        vipGuests,
        refundedOrders,
        refundedBookings,
        { data: activityData },
      ] = await Promise.all([
        supabase.from('site_events').select('id, title, status, site_ticket_tiers(capacity, sold_count)'),
        supabase
          .from('site_orders')
          .select(
            'id, event_id, customer_name, customer_email, amount_total_cents, quantity, checked_in_at, created_at, stripe_checkout_session_id',
          )
          .eq('status', 'paid'),
        supabase
          .from('site_table_bookings')
          .select('id, booking_date, deposit_cents, status, stripe_checkout_session_id, created_at'),
        supabase.from('door_staff').select('id', { count: 'exact', head: true }),
        supabase.from('site_vip_guests').select('id', { count: 'exact', head: true }),
        supabase.from('site_orders').select('id', { count: 'exact', head: true }).eq('status', 'refunded'),
        supabase.from('site_table_bookings').select('id', { count: 'exact', head: true }).eq('status', 'refunded'),
        supabase.from('audit_log').select('id, actor_email, action, entity_type, details, created_at').order('created_at', { ascending: false }).limit(8),
      ]);

      setEvents((eventsData as unknown as EventWithTiers[]) ?? []);
      setOrders((ordersData as PaidOrder[]) ?? []);
      setTableBookings((tableBookingsData as TableBooking[]) ?? []);
      setDoorStaffCount(doorStaff.count ?? 0);
      setVipGuestCount(vipGuests.count ?? 0);
      setRefundCount((refundedOrders.count ?? 0) + (refundedBookings.count ?? 0));
      setActivity((activityData as AuditEntry[]) ?? []);
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

  const paidTableBookings = useMemo(
    () =>
      tableBookings
        .filter((b) => b.status === 'paid')
        .filter((b) => modeFilter === 'all' || sessionMode(b.stripe_checkout_session_id) === modeFilter),
    [tableBookings, modeFilter],
  );

  const kpis = useMemo(() => {
    const now = new Date();
    const todayStart = startOfDay(now);
    const weekStart = subDays(now, 7);

    const ticketRevenue = paidOrders.reduce((sum, o) => sum + o.amount_total_cents, 0);
    const tableRevenue = paidTableBookings.reduce((sum, b) => sum + b.deposit_cents, 0);
    const totalRevenue = ticketRevenue + tableRevenue;
    const revenueToday =
      paidOrders.filter((o) => isAfter(new Date(o.created_at), todayStart)).reduce((sum, o) => sum + o.amount_total_cents, 0) +
      paidTableBookings.filter((b) => isAfter(new Date(b.created_at), todayStart)).reduce((sum, b) => sum + b.deposit_cents, 0);
    const revenueWeek =
      paidOrders.filter((o) => isAfter(new Date(o.created_at), weekStart)).reduce((sum, o) => sum + o.amount_total_cents, 0) +
      paidTableBookings.filter((b) => isAfter(new Date(b.created_at), weekStart)).reduce((sum, b) => sum + b.deposit_cents, 0);
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

    return {
      totalRevenue,
      revenueToday,
      revenueWeek,
      ticketsSold,
      ticketsCheckedIn,
      occupancy,
      tableBookingsCount: paidTableBookings.length,
      tableDepositsHeld: tableRevenue,
    };
  }, [paidOrders, paidTableBookings, events]);

  const tonight = useMemo(() => {
    const todayStart = startOfDay(new Date());
    const scannedIn = paidOrders.filter((o) => o.checked_in_at && isAfter(new Date(o.checked_in_at), todayStart)).length;
    const todayStr = format(new Date(), 'yyyy-MM-dd');
    const tablesHeld = tableBookings.filter((b) => b.booking_date === todayStr && b.status === 'paid').length;
    return { scannedIn, tablesHeld };
  }, [paidOrders, tableBookings]);

  const trend = useMemo(() => {
    const days = 14;
    const buckets: Record<string, { tickets: number; tables: number }> = {};
    for (let i = days - 1; i >= 0; i--) {
      buckets[format(startOfDay(subDays(new Date(), i)), 'MMM d')] = { tickets: 0, tables: 0 };
    }
    paidOrders.forEach((o) => {
      const key = format(startOfDay(new Date(o.created_at)), 'MMM d');
      if (key in buckets) buckets[key].tickets += o.amount_total_cents / 100;
    });
    paidTableBookings.forEach((b) => {
      const key = format(startOfDay(new Date(b.created_at)), 'MMM d');
      if (key in buckets) buckets[key].tables += b.deposit_cents / 100;
    });
    return Object.entries(buckets).map(([date, v]) => ({ date, ...v }));
  }, [paidOrders, paidTableBookings]);

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
    { label: 'Table Bookings', value: kpis.tableBookingsCount, sub: `${formatCurrency(kpis.tableDepositsHeld)} deposits held` },
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
                {card.sub && <div className="mt-1 text-xs text-green-500">{card.sub}</div>}
              </CardContent>
            </Card>
          ))}
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="border-gray-800 bg-gray-900/50 lg:col-span-2">
          <CardHeader>
            <CardTitle className="text-white">Revenue - Last 14 Days</CardTitle>
          </CardHeader>
          <CardContent className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={trend}>
                <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                <XAxis dataKey="date" stroke="#9ca3af" fontSize={12} />
                <YAxis stroke="#9ca3af" fontSize={12} tickFormatter={(v) => `$${v}`} />
                <Tooltip
                  contentStyle={{ background: '#111827', border: '1px solid #374151', color: '#fff' }}
                  formatter={(value: number) => `$${value.toFixed(2)}`}
                />
                <Legend />
                <Bar dataKey="tickets" name="Tickets" stackId="revenue" fill="#f97316" />
                <Bar dataKey="tables" name="Tables" stackId="revenue" fill="#facc15" />
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        <Card className="border-gray-800 bg-gray-900/50">
          <CardHeader>
            <CardTitle className="text-white">Tonight at the Door</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="flex items-center justify-between text-sm">
              <span className="text-gray-400">Scanned in</span>
              <span className="font-semibold text-white">{tonight.scannedIn}</span>
            </div>
            <div className="flex items-center justify-between text-sm">
              <span className="text-gray-400">On guest list</span>
              <span className="font-semibold text-white">{vipGuestCount}</span>
            </div>
            <div className="flex items-center justify-between text-sm">
              <span className="text-gray-400">Tables held</span>
              <span className="font-semibold text-white">{tonight.tablesHeld}</span>
            </div>
            <div className="flex items-center justify-between text-sm">
              <span className="text-gray-400">Refund requests</span>
              <span className={`font-semibold ${refundCount > 0 ? 'text-amber-400' : 'text-white'}`}>{refundCount}</span>
            </div>
            <Button asChild variant="outline" className="w-full border-gray-700">
              <Link to="/door/login">Open check-in scanner</Link>
            </Button>
          </CardContent>
        </Card>
      </div>

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

      <div className="grid gap-4 lg:grid-cols-2">
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

        <div>
          <div className="mb-3 flex items-center justify-between">
            <h2 className="text-lg font-semibold text-white">Recent Activity</h2>
            <Link to="/cms/audit-log" className="text-sm text-orange-500 hover:underline">
              View audit log
            </Link>
          </div>
          <div className="rounded-lg border border-gray-800 p-4">
            {activity.length === 0 ? (
              <p className="text-center text-sm text-gray-500">No activity yet.</p>
            ) : (
              <ul className="space-y-3">
                {activity.map((entry) => (
                  <li key={entry.id} className="flex items-start gap-2 text-sm">
                    <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-orange-500" />
                    <div>
                      <div className="text-gray-300">
                        {describeAction(entry.action)}
                        {entry.actor_email && <span className="text-gray-500"> &middot; {entry.actor_email}</span>}
                      </div>
                      <div className="text-xs text-gray-600">{formatDistanceToNow(new Date(entry.created_at), { addSuffix: true })}</div>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

export default CmsDashboard;
