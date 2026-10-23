import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { CmsMoneyError, dollars, fetchConcessions, fetchDiscountLimits, formatWhen, type ConcessionRow, type DiscountLimitsRow } from '@/lib/cmsMoney';

const STATUS_LABEL: Record<ConcessionRow['status'], string> = { applied: 'Applied', pending: 'Waiting for approval', declined: 'Declined', voided: 'Taken back' };
const STATUS_STYLE: Record<ConcessionRow['status'], 'default' | 'secondary' | 'destructive' | 'outline'> = { applied: 'default', pending: 'secondary', declined: 'outline', voided: 'destructive' };

/**
 * Discounts and free bottles given by the clubs' own people. Each club's OWNER sets the limits in the BottlesUp Business app (a server's and a manager's biggest discount, free bottles
 * per night, whether discounts combine); nobody else can give anything until they are set. This page is read-only: BottlesUp watches what was given, who approved it and the limits.
 */
const Concessions = () => {
  const [status, setStatus] = useState<'all' | ConcessionRow['status']>('all');
  const [rows, setRows] = useState<ConcessionRow[] | null>(null);
  const [limits, setLimits] = useState<DiscountLimitsRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [r, l] = await Promise.all([fetchConcessions(status === 'all' ? undefined : status), fetchDiscountLimits()]);
      setRows(r);
      setLimits(l);
      setError(null);
    } catch (err) {
      setError(err instanceof CmsMoneyError ? err.message : 'The discounts could not be loaded.');
    }
  }, [status]);

  useEffect(() => { void load(); }, [load]);

  return (
    <div>
      <h1 className="mb-2 text-2xl font-bold text-white">Discounts and free bottles</h1>
      <p className="mb-6 max-w-2xl text-sm text-gray-400">
        Given by a club's own staff within the limits its owner set. A free bottle is never counted as sales. Read-only here.
      </p>
      {error && <div className="mb-4 rounded-md border border-red-900 bg-red-950/40 p-3 text-sm text-red-300">{error}</div>}
      <Tabs defaultValue="given">
        <TabsList>
          <TabsTrigger value="given">What was given</TabsTrigger>
          <TabsTrigger value="limits">Limits by club</TabsTrigger>
        </TabsList>

        <TabsContent value="given" className="mt-4">
          <div className="mb-4 w-64">
            <Select value={status} onValueChange={(v) => setStatus(v as typeof status)}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Everything</SelectItem>
                {(Object.keys(STATUS_LABEL) as ConcessionRow['status'][]).map((s) => <SelectItem key={s} value={s}>{STATUS_LABEL[s]}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          {rows === null ? <div className="text-gray-400">Loading...</div> : (
            <div className="rounded-lg border border-gray-800">
              <Table>
                <TableHeader>
                  <TableRow><TableHead>Club</TableHead><TableHead>Booking</TableHead><TableHead>What</TableHead><TableHead>Value</TableHead><TableHead>Reason</TableHead><TableHead>Asked by</TableHead><TableHead>Approved by</TableHead><TableHead>Status</TableHead><TableHead>Night</TableHead></TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((r) => (
                    <TableRow key={r.id}>
                      <TableCell>{r.venueName}</TableCell>
                      <TableCell>{r.confirmationCode ?? '-'}</TableCell>
                      <TableCell>{r.kind === 'discount' ? (r.percent ? `${r.percent}% discount` : 'Discount') : `${r.quantity} × ${r.bottleName} free`}</TableCell>
                      <TableCell>{dollars(r.amountCents)}</TableCell>
                      <TableCell className="max-w-xs text-sm">{r.reason}</TableCell>
                      <TableCell>{r.requestedBy}<div className="text-xs text-gray-500">{r.requestedRole}</div></TableCell>
                      <TableCell>{r.decidedBy ? <>{r.decidedBy}<div className="text-xs text-gray-500">{r.decidedRole}</div></> : <span className="text-xs text-gray-500">within their own limit</span>}</TableCell>
                      <TableCell><Badge variant={STATUS_STYLE[r.status]}>{STATUS_LABEL[r.status]}</Badge></TableCell>
                      <TableCell className="text-xs text-gray-400">{r.night}<div>{formatWhen(r.createdAt)}</div></TableCell>
                    </TableRow>
                  ))}
                  {rows.length === 0 && <TableRow><TableCell colSpan={9} className="text-center text-gray-500">Nothing yet.</TableCell></TableRow>}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        <TabsContent value="limits" className="mt-4">
          {limits === null ? <div className="text-gray-400">Loading...</div> : (
            <div className="rounded-lg border border-gray-800">
              <Table>
                <TableHeader>
                  <TableRow><TableHead>Club</TableHead><TableHead>Server may discount</TableHead><TableHead>Manager may discount</TableHead><TableHead>Server free bottles / night</TableHead><TableHead>Managers' pool / night</TableHead><TableHead>Discounts combine</TableHead></TableRow>
                </TableHeader>
                <TableBody>
                  {limits.map((l) => (
                    <TableRow key={l.venueId}>
                      <TableCell>{l.venueName}</TableCell>
                      {l.hasLimits ? (
                        <>
                          <TableCell>{l.serverMaxPercent}%</TableCell><TableCell>{l.managerMaxPercent}%</TableCell>
                          <TableCell>{l.serverFreeBottles}</TableCell><TableCell>{l.managerFreeBottles}</TableCell>
                          <TableCell>{l.allowStacking ? 'Yes' : 'No'}</TableCell>
                        </>
                      ) : <TableCell colSpan={5} className="text-gray-500">Not set: only the owner can give discounts.</TableCell>}
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>
      </Tabs>
    </div>
  );
};

export default Concessions;
