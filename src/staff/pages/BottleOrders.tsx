import { useEffect, useState } from 'react';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { listMyBottleOrders, type MyBottleOrder } from '@/lib/staffDashboard';
import { updateBottleServiceStatus, BOTTLE_SERVICE_STATUS_LABELS, BOTTLE_SERVICE_STATUSES } from '@/lib/bottleService';
import type { BottleServiceStatus } from '@/types/database';

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

// BottlesUp Server and Pay-at-Club system, section 2's "Bottle Orders" tab.
// Reuses the exact same update_bottle_service_status RPC already built for
// the CMS/door check-in screens (Bottle Payment Options section 7) - one
// action, three places it can be triggered from.
const BottleOrders = () => {
  const { toast } = useToast();
  const [orders, setOrders] = useState<MyBottleOrder[]>([]);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    setLoading(true);
    try {
      setOrders(await listMyBottleOrders());
    } catch (err) {
      toast({ title: 'Could not load bottle orders', description: err instanceof Error ? err.message : undefined, variant: 'destructive' });
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleStatusChange = async (lineId: string, status: BottleServiceStatus) => {
    setOrders((prev) => prev.map((o) => (o.id === lineId ? { ...o, serviceStatus: status } : o)));
    try {
      await updateBottleServiceStatus(lineId, status);
    } catch (err) {
      toast({ title: 'Could not update status', description: err instanceof Error ? err.message : undefined, variant: 'destructive' });
      load();
    }
  };

  return (
    <div className="mx-auto max-w-sm px-4 py-6">
      <h1 className="mb-4 text-xl font-bold text-white">Bottle Orders</h1>

      {loading ? (
        <div className="text-center text-gray-400">Loading...</div>
      ) : orders.length === 0 ? (
        <div className="rounded-lg border border-gray-800 p-6 text-center text-gray-500">
          No active bottle orders right now.
        </div>
      ) : (
        <div className="space-y-2">
          {orders.map((o) => (
            <div key={o.id} className="rounded-xl border border-gray-800 bg-gray-950 p-3">
              <div className="mb-1 flex items-center justify-between text-sm text-gray-500">
                <span>{o.tableTypeName} - {o.customerName}</span>
                <span className="font-mono text-xs">{o.confirmationCode}</span>
              </div>
              <div className="mb-2 flex items-center justify-between">
                <span className="text-white">{o.bottleName}{o.size ? ` (${o.size})` : ''} × {o.quantity}</span>
                <span className="text-gray-400">{money(o.lineTotalCents)}</span>
              </div>
              <Select value={o.serviceStatus} onValueChange={(v) => handleStatusChange(o.id, v as BottleServiceStatus)}>
                <SelectTrigger className="h-8 text-xs">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {BOTTLE_SERVICE_STATUSES.map((s) => (
                    <SelectItem key={s} value={s}>{BOTTLE_SERVICE_STATUS_LABELS[s]}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default BottleOrders;
