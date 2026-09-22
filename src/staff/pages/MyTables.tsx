import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { useToast } from '@/hooks/use-toast';
import { listMyTables, listMyBottleOrders, type MyTable, type MyBottleOrder } from '@/lib/staffDashboard';
import { PAYMENT_STATUS_LABELS } from '@/lib/clubPayment';
import { doorSignOut } from '../../door/useDoorAuth';

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

const bottleSummary = (t: MyTable) => {
  const total = t.bottleCount;
  if (total === 0) return 'No bottles yet';
  const word = total === 1 ? 'bottle' : 'bottles';
  return t.dueAtVenueCount > 0 ? `${total} ${word} reserved` : `${total} ${word}`;
};

// BottlesUp Server and Pay-at-Club system, section 2: the server dashboard
// landing screen - "Assigned tables, Customers checked in, Payments due,
// Bottles preparing, Bottles ready."
const MyTables = () => {
  const { toast } = useToast();
  const navigate = useNavigate();
  const [tables, setTables] = useState<MyTable[]>([]);
  const [orders, setOrders] = useState<MyBottleOrder[]>([]);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    setLoading(true);
    try {
      const [t, o] = await Promise.all([listMyTables(), listMyBottleOrders()]);
      setTables(t);
      setOrders(o);
    } catch (err) {
      toast({ title: 'Could not load your tables', description: err instanceof Error ? err.message : undefined, variant: 'destructive' });
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const paymentsDue = tables.filter((t) => t.balanceDueCents > 0).length;
  const preparing = orders.filter((o) => o.serviceStatus === 'preparing').length;
  const ready = orders.filter((o) => o.serviceStatus === 'ready').length;

  return (
    <div className="mx-auto max-w-sm px-4 py-6">
      <div className="mb-4 flex items-center justify-between">
        <h1 className="text-xl font-bold text-white">My Tables</h1>
        <Button variant="ghost" size="sm" className="text-gray-400" onClick={() => doorSignOut()}>
          Sign out
        </Button>
      </div>

      <div className="mb-5 grid grid-cols-3 gap-2 text-center">
        <div className="rounded-lg border border-gray-800 p-3">
          <div className="text-xs text-gray-500">Checked In</div>
          <div className="text-lg font-bold text-white">{tables.length}</div>
        </div>
        <div className="rounded-lg border border-gray-800 p-3">
          <div className="text-xs text-gray-500">Payments Due</div>
          <div className={`text-lg font-bold ${paymentsDue > 0 ? 'text-orange-400' : 'text-white'}`}>{paymentsDue}</div>
        </div>
        <div className="rounded-lg border border-gray-800 p-3">
          <div className="text-xs text-gray-500">Preparing / Ready</div>
          <div className="text-lg font-bold text-white">{preparing} / {ready}</div>
        </div>
      </div>

      {loading ? (
        <div className="text-center text-gray-400">Loading...</div>
      ) : tables.length === 0 ? (
        <div className="rounded-lg border border-gray-800 p-6 text-center text-gray-500">
          No checked-in tables right now.
        </div>
      ) : (
        <div className="space-y-3">
          {tables.map((t) => (
            <div key={t.id} className="rounded-2xl border-2 border-gray-800 bg-gray-950 p-4">
              <div className="mb-1 flex items-center justify-between">
                <div className="font-bold text-white">{t.tableTypeName}</div>
                {t.paymentStatus ? (
                  <Badge
                    variant="outline"
                    className={
                      t.paymentStatus === 'payment_due'
                        ? 'border-orange-500/40 text-orange-400'
                        : t.paymentStatus === 'payment_recorded'
                          ? 'border-blue-600 text-blue-400'
                          : 'border-purple-600 text-purple-400'
                    }
                  >
                    {PAYMENT_STATUS_LABELS[t.paymentStatus]}
                  </Badge>
                ) : (
                  <Badge variant="outline" className="border-green-600 text-green-400">Paid</Badge>
                )}
              </div>
              <div className="mb-1 text-sm text-gray-300">Customer: {t.customerName}</div>
              <div className="mb-1 text-sm text-gray-400">{bottleSummary(t)}</div>
              {t.balanceDueCents > 0 && (
                <div className="mb-3 text-sm text-orange-400">Balance due: {money(t.balanceDueCents)}</div>
              )}
              <Button
                className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
                disabled={!t.confirmationCode}
                onClick={() => navigate(`/staff/tables/${t.confirmationCode}`)}
              >
                Open Table
              </Button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default MyTables;
