import { useEffect, useState } from 'react';
import { AlertTriangle, PackageCheck } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { listMyAlerts, type StaffAlert } from '@/lib/staffDashboard';

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

// BottlesUp Server and Pay-at-Club system, section 2's "Alerts" tab. Two
// kinds derivable from existing data with no new schema: a disputed club
// payment, and a bottle marked Ready that hasn't been served yet. More
// alert types (payment reminders, corrections, etc.) can be added later as
// those workflows are built - this is a working v1, not a placeholder.
const Alerts = () => {
  const { toast } = useToast();
  const [alerts, setAlerts] = useState<StaffAlert[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    listMyAlerts()
      .then(setAlerts)
      .catch((err) => toast({ title: 'Could not load alerts', description: err instanceof Error ? err.message : undefined, variant: 'destructive' }))
      .finally(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="mx-auto max-w-sm px-4 py-6">
      <h1 className="mb-4 text-xl font-bold text-white">Alerts</h1>

      {loading ? (
        <div className="text-center text-gray-400">Loading...</div>
      ) : alerts.length === 0 ? (
        <div className="rounded-lg border border-gray-800 p-6 text-center text-gray-500">
          Nothing needs your attention.
        </div>
      ) : (
        <div className="space-y-2">
          {alerts.map((a, i) =>
            a.type === 'dispute' ? (
              <div key={i} className="flex items-start gap-3 rounded-xl border border-red-900/50 bg-red-950/20 p-3">
                <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-red-400" />
                <div>
                  <div className="text-sm text-white">{a.customerName} disputed a payment</div>
                  <div className="text-xs text-gray-500">
                    {money(a.amountPaidCents)} · {a.confirmationCode}
                    {a.disputeReason ? ` · "${a.disputeReason}"` : ''}
                  </div>
                </div>
              </div>
            ) : (
              <div key={i} className="flex items-start gap-3 rounded-xl border border-amber-900/50 bg-amber-950/20 p-3">
                <PackageCheck className="mt-0.5 h-4 w-4 shrink-0 text-amber-400" />
                <div>
                  <div className="text-sm text-white">
                    {a.bottleName} × {a.quantity} is ready for {a.customerName}
                  </div>
                  <div className="text-xs text-gray-500">{a.confirmationCode}</div>
                </div>
              </div>
            ),
          )}
        </div>
      )}
    </div>
  );
};

export default Alerts;
