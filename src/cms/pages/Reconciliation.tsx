import { useEffect, useState } from 'react';
import { format, startOfMonth } from 'date-fns';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { AlertTriangle, Eye } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { listReconciliationQueue, getVenueRevenueReport, type ReconciliationQueueItem, type VenueRevenueReport } from '@/lib/reconciliation';
import TableReconciliationSheet from '../components/TableReconciliationSheet';

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

interface VenueOption {
  id: string;
  name: string;
}

// Bottle Payment Options section 10: the manager's landing page for
// reconciliation - a queue of tables still needing a close-out review, and
// a venue-level revenue report separating bottle sales / BottlesUp-collected
// / club-collected money, per the spec.
const CmsReconciliation = () => {
  const { toast } = useToast();
  const [venues, setVenues] = useState<VenueOption[]>([]);
  const [queueVenueId, setQueueVenueId] = useState<string>('all');
  const [queue, setQueue] = useState<ReconciliationQueueItem[]>([]);
  const [loadingQueue, setLoadingQueue] = useState(true);
  const [openBookingId, setOpenBookingId] = useState<string | null>(null);

  const [reportVenueId, setReportVenueId] = useState<string>('');
  const [dateFrom, setDateFrom] = useState(format(startOfMonth(new Date()), 'yyyy-MM-dd'));
  const [dateTo, setDateTo] = useState(format(new Date(), 'yyyy-MM-dd'));
  const [report, setReport] = useState<VenueRevenueReport | null>(null);
  const [loadingReport, setLoadingReport] = useState(false);

  const loadQueue = async () => {
    setLoadingQueue(true);
    try {
      const result = await listReconciliationQueue(queueVenueId === 'all' ? null : queueVenueId);
      setQueue(result);
    } catch (err) {
      toast({ title: 'Could not load reconciliation queue', description: err instanceof Error ? err.message : undefined, variant: 'destructive' });
    } finally {
      setLoadingQueue(false);
    }
  };

  useEffect(() => {
    supabase.from('site_venues').select('id, name').order('name').then(({ data }) => {
      setVenues(data ?? []);
      if (data && data.length > 0) setReportVenueId((prev) => prev || data[0].id);
    });
  }, []);

  useEffect(() => {
    loadQueue();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queueVenueId]);

  const loadReport = async () => {
    if (!reportVenueId) return;
    setLoadingReport(true);
    try {
      const result = await getVenueRevenueReport(reportVenueId, dateFrom, dateTo);
      setReport(result);
    } catch (err) {
      toast({ title: 'Could not load revenue report', description: err instanceof Error ? err.message : undefined, variant: 'destructive' });
      setReport(null);
    } finally {
      setLoadingReport(false);
    }
  };

  useEffect(() => {
    if (reportVenueId) loadReport();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reportVenueId]);

  return (
    <div className="space-y-8">
      <div>
        <h1 className="mb-1 text-2xl font-bold text-white">Reconciliation</h1>
        <p className="text-sm text-gray-500">Review and close tables, and see revenue by channel per venue.</p>
      </div>

      <div>
        <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
          <h2 className="text-lg font-semibold text-white">Needs Reconciliation ({queue.length})</h2>
          <Select value={queueVenueId} onValueChange={setQueueVenueId}>
            <SelectTrigger className="w-56">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All venues</SelectItem>
              {venues.map((v) => (
                <SelectItem key={v.id} value={v.id}>{v.name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        {loadingQueue ? (
          <div className="text-gray-400">Loading...</div>
        ) : (
          <div className="rounded-lg border border-gray-800">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Customer</TableHead>
                  <TableHead>Venue / Table</TableHead>
                  <TableHead>Date</TableHead>
                  <TableHead>Balance</TableHead>
                  <TableHead>Flags</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {queue.map((item) => (
                  <TableRow key={item.id}>
                    <TableCell>
                      <div>{item.customerName}</div>
                      <div className="font-mono text-xs text-gray-500">{item.confirmationCode}</div>
                    </TableCell>
                    <TableCell>{item.tableTypeName} - {item.venueName}</TableCell>
                    <TableCell>{item.bookingDate}</TableCell>
                    <TableCell className={item.balanceDueCents > 0 ? 'text-orange-400' : 'text-emerald-400'}>
                      {money(item.balanceDueCents)}
                    </TableCell>
                    <TableCell>
                      <div className="flex gap-1">
                        {item.closeoutRequestedAt && (
                          <Badge variant="outline" className="border-blue-600 text-[10px] text-blue-400">Closeout requested</Badge>
                        )}
                        {item.hasDispute && (
                          <Badge variant="outline" className="border-red-600 text-[10px] text-red-400">Disputed</Badge>
                        )}
                        {item.hasUnserved && (
                          <Badge variant="outline" className="border-amber-600 text-[10px] text-amber-400">Unserved</Badge>
                        )}
                        {!item.closeoutRequestedAt && !item.hasDispute && !item.hasUnserved && item.balanceDueCents === 0 && (
                          <span className="text-xs text-gray-600">-</span>
                        )}
                      </div>
                    </TableCell>
                    <TableCell className="text-right">
                      <Button size="sm" variant="ghost" onClick={() => setOpenBookingId(item.id)}>
                        <Eye className="mr-1 h-3 w-3" />
                        Review
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                {queue.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={6} className="text-center text-gray-500">
                      Nothing waiting on reconciliation.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </div>
        )}
      </div>

      <div>
        <h2 className="mb-3 text-lg font-semibold text-white">Venue Revenue Report</h2>
        <div className="mb-4 flex flex-wrap items-end gap-3 rounded-lg border border-gray-800 p-4">
          <div className="space-y-1">
            <Label className="text-xs">Venue</Label>
            <Select value={reportVenueId} onValueChange={setReportVenueId}>
              <SelectTrigger className="w-56">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {venues.map((v) => (
                  <SelectItem key={v.id} value={v.id}>{v.name}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <Label className="text-xs">From</Label>
            <Input type="date" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} className="w-40" />
          </div>
          <div className="space-y-1">
            <Label className="text-xs">To</Label>
            <Input type="date" value={dateTo} onChange={(e) => setDateTo(e.target.value)} className="w-40" />
          </div>
          <Button variant="outline" className="border-gray-700" disabled={loadingReport} onClick={loadReport}>
            {loadingReport ? 'Loading...' : 'Run Report'}
          </Button>
        </div>

        {report && (
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="text-xs uppercase tracking-wide text-gray-500">Bottle Sales</div>
              <div className="text-xl font-bold text-white">{money(report.bottleSalesCents)}</div>
            </div>
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="text-xs uppercase tracking-wide text-gray-500">Collected via BottlesUp</div>
              <div className="text-xl font-bold text-white">{money(report.bottlesupCollectedCents)}</div>
            </div>
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="text-xs uppercase tracking-wide text-gray-500">Collected at the Club</div>
              <div className="text-xl font-bold text-white">{money(report.clubCollectedCents)}</div>
            </div>
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="text-xs uppercase tracking-wide text-gray-500">BottlesUp Fee</div>
              <div className="text-xl font-bold text-white">{money(report.bottlesupFeeCents)}</div>
            </div>
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="text-xs uppercase tracking-wide text-gray-500">Club Fee Owed (not auto-collected)</div>
              <div className="text-xl font-bold text-white">{money(report.clubBottlesupFeeCents)}</div>
            </div>
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="text-xs uppercase tracking-wide text-gray-500">Refunds (Online + Club)</div>
              <div className="text-xl font-bold text-red-400">
                {money(report.onlineRefundsCents + report.clubRefundsCents)}
              </div>
            </div>
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="text-xs uppercase tracking-wide text-gray-500">Outstanding Balance</div>
              <div className={`text-xl font-bold ${report.outstandingBalanceCents > 0 ? 'text-orange-400' : 'text-emerald-400'}`}>
                {money(report.outstandingBalanceCents)}
              </div>
            </div>
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="text-xs uppercase tracking-wide text-gray-500">Bookings</div>
              <div className="text-xl font-bold text-white">{report.bookingCount}</div>
            </div>
            <div className="rounded-lg border border-gray-800 p-4">
              <div className="flex items-center gap-1 text-xs uppercase tracking-wide text-gray-500">
                {report.unreconciledCount > 0 && <AlertTriangle className="h-3 w-3 text-amber-400" />}
                Not Yet Closed
              </div>
              <div className={`text-xl font-bold ${report.unreconciledCount > 0 ? 'text-amber-400' : 'text-white'}`}>
                {report.unreconciledCount}
              </div>
            </div>
          </div>
        )}
      </div>

      <TableReconciliationSheet
        bookingId={openBookingId}
        onOpenChange={(open) => !open && setOpenBookingId(null)}
        onClosed={loadQueue}
      />
    </div>
  );
};

export default CmsReconciliation;
