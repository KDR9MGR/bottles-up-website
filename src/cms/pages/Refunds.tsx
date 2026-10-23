import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import {
  CmsMoneyError, REFUND_STATUS_LABELS, dollars, fetchRefundPolicies, fetchRefundRequests, formatWhen, processOnlineRefund,
  type RefundPolicyRow, type RefundRequestRow,
} from '@/lib/cmsMoney';

const STATUS_STYLE: Record<RefundRequestRow['status'], 'default' | 'secondary' | 'destructive' | 'outline'> = {
  requested: 'secondary', approved: 'default', declined: 'outline', processing: 'default', completed: 'outline', failed: 'destructive',
};

/**
 * Refunds, as the venues decide them. A venue sets its own refund policy (deadlines and percentages) in the BottlesUp Business app, a guest or a manager asks, and a manager
 * approves or declines. This page lets BottlesUp watch all of it, and do the one thing only BottlesUp does: return an APPROVED online payment through Stripe. Money paid back at
 * the club (cash, the venue's own terminal) is recorded by the venue in the app and never appears as something to process here.
 */
const Refunds = () => {
  const { toast } = useToast();
  const [status, setStatus] = useState<'all' | RefundRequestRow['status']>('all');
  const [requests, setRequests] = useState<RefundRequestRow[] | null>(null);
  const [policies, setPolicies] = useState<RefundPolicyRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<RefundRequestRow | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [r, p] = await Promise.all([fetchRefundRequests(status === 'all' ? undefined : status), fetchRefundPolicies()]);
      setRequests(r);
      setPolicies(p);
      setError(null);
    } catch (err) {
      setError(err instanceof CmsMoneyError ? err.message : 'The refunds could not be loaded.');
    }
  }, [status]);

  useEffect(() => { void load(); }, [load]);

  const process = async () => {
    if (!confirm) return;
    setBusy(true);
    try {
      await processOnlineRefund(confirm.requestId, confirm.bookingId);
      toast({ title: 'Refund returned', description: `${dollars(confirm.approvedCents)} was returned to ${confirm.guestName} through Stripe.` });
      setConfirm(null);
    } catch (err) {
      toast({ title: 'The refund was not returned', description: err instanceof CmsMoneyError ? err.message : 'Try again, or check Stripe.', variant: 'destructive' });
    } finally {
      setBusy(false);
      void load();
    }
  };

  return (
    <div>
      <h1 className="mb-2 text-2xl font-bold text-white">Refunds</h1>
      <p className="mb-6 max-w-2xl text-sm text-gray-400">
        Venues set their own refund policy and decide each request in the BottlesUp Business app. Here you can see all of them, and return the approved online payments
        through Stripe. A refund paid back at the club is recorded by the venue and is only shown here.
      </p>
      {error && <div className="mb-4 rounded-md border border-red-900 bg-red-950/40 p-3 text-sm text-red-300">{error}</div>}

      <Tabs defaultValue="requests">
        <TabsList>
          <TabsTrigger value="requests">Requests</TabsTrigger>
          <TabsTrigger value="policies">Policies by venue</TabsTrigger>
        </TabsList>

        <TabsContent value="requests" className="mt-4">
          <div className="mb-4 w-64">
            <Select value={status} onValueChange={(v) => setStatus(v as typeof status)}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All requests</SelectItem>
                {(Object.keys(REFUND_STATUS_LABELS) as RefundRequestRow['status'][]).map((s) => <SelectItem key={s} value={s}>{REFUND_STATUS_LABELS[s]}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          {requests === null ? <div className="text-gray-400">Loading...</div> : (
            <div className="rounded-lg border border-gray-800">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Venue</TableHead><TableHead>Booking</TableHead><TableHead>Guest</TableHead><TableHead>Reason</TableHead><TableHead>Policy said</TableHead>
                    <TableHead>Approved</TableHead><TableHead>Status</TableHead><TableHead>When</TableHead><TableHead />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {requests.map((r) => (
                    <TableRow key={r.requestId}>
                      <TableCell>{r.venueName}</TableCell>
                      <TableCell>{r.confirmationCode ?? '-'}<div className="text-xs text-gray-500">paid {dollars(r.paidCents)}</div></TableCell>
                      <TableCell>{r.guestName}<div className="text-xs text-gray-500">{r.guestEmail} · asked by {r.requestedBy === 'guest' ? 'the guest' : 'staff'}</div></TableCell>
                      <TableCell className="max-w-xs text-sm">{r.reason}{r.decisionNote && <div className="text-xs text-gray-500">Venue note: {r.decisionNote}</div>}</TableCell>
                      <TableCell>{r.policyPercent === null ? 'No policy' : `${r.policyPercent}% = ${dollars(r.suggestedCents)}`}</TableCell>
                      <TableCell>{r.approvedCents === null ? '-' : `${dollars(r.approvedCents)} ${r.method === 'online' ? 'online' : 'at the club'}`}</TableCell>
                      <TableCell>
                        <Badge variant={STATUS_STYLE[r.status]}>{REFUND_STATUS_LABELS[r.status]}</Badge>
                        {r.failureNote && <div className="mt-1 text-xs text-red-300">{r.failureNote}</div>}
                        {r.status === 'processing' && <div className="mt-1 text-xs text-amber-300">If this stays here, check Stripe before returning it again.</div>}
                      </TableCell>
                      <TableCell className="text-xs text-gray-400">{formatWhen(r.createdAt)}</TableCell>
                      <TableCell>
                        {r.status === 'approved' && r.method === 'online' && <Button size="sm" onClick={() => setConfirm(r)}>Return through Stripe</Button>}
                      </TableCell>
                    </TableRow>
                  ))}
                  {requests.length === 0 && <TableRow><TableCell colSpan={9} className="text-center text-gray-500">No refund requests.</TableCell></TableRow>}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        <TabsContent value="policies" className="mt-4">
          {policies === null ? <div className="text-gray-400">Loading...</div> : (
            <div className="grid gap-3 md:grid-cols-2">
              {policies.map((p) => (
                <div key={p.venueId} className="rounded-lg border border-gray-800 p-4">
                  <div className="mb-2 flex items-center justify-between">
                    <span className="font-medium text-white">{p.venueName}</span>
                    <Badge variant={p.hasPolicy ? 'default' : 'outline'}>{p.hasPolicy ? 'Policy set' : 'No policy yet'}</Badge>
                  </div>
                  <ul className="list-disc space-y-1 pl-5 text-sm text-gray-300">{p.lines.map((l, i) => <li key={i}>{l}</li>)}</ul>
                  {p.updatedAt && <div className="mt-2 text-xs text-gray-500">Last changed {formatWhen(p.updatedAt)}</div>}
                </div>
              ))}
            </div>
          )}
        </TabsContent>
      </Tabs>

      <Dialog open={confirm !== null} onOpenChange={(open) => { if (!open && !busy) setConfirm(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Return {confirm ? dollars(confirm.approvedCents) : ''} through Stripe?</DialogTitle>
            <DialogDescription>
              {confirm?.venueName} approved this refund for {confirm?.guestName} (booking {confirm?.confirmationCode}). The money goes back to the card the guest paid with, and it cannot be undone.
              If you press the button twice or the connection drops, Stripe still returns it only once.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" disabled={busy} onClick={() => setConfirm(null)}>Not now</Button>
            <Button disabled={busy} onClick={() => void process()}>{busy ? 'Returning...' : 'Return the money'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Refunds;
