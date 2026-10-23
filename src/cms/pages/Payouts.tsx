import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';
import {
  ACCOUNT_STATUS_LABELS, CmsMoneyError, PAYOUT_STATUS_LABELS, WEEKDAYS, bpsFromPercent, createPayoutItem, dollars, fetchEligible, fetchPayoutAccounts, fetchPayoutItems,
  fetchPayoutOverrides, fetchPayoutSettings, formatWhen, percentFromBps, savePayoutAccount, savePayoutOverride, savePayoutSettings, setPayoutItemStatus,
  type EligibleRow, type PayoutAccountRow, type PayoutAccountStatus, type PayoutItemRow, type PayoutOverrideRow, type PayoutSettings,
} from '@/lib/cmsMoney';

const isoDay = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const daysAgo = (n: number) => { const d = new Date(); d.setDate(d.getDate() - n); return isoDay(d); };

type ItemAction = { item: PayoutItemRow; to: 'processing' | 'paid' | 'failed' | 'cancelled' };

/**
 * Payouts to venues and organizers. BottlesUp controls here: its percentage, the weekday of the weekly payout, how many days money waits after the night, a different arrangement for one
 * business, and each business's payout account status (the account is checked by BottlesUp; only the last digits are kept). The ledger turns the money that was collected ONLINE into payout
 * items. Cash and the venue's own card machine are never paid out again. A payout is only "Paid" once a transfer reference is entered. Owners and organizers see their own part, read-only,
 * in the BottlesUp Business app.
 */
const Payouts = () => {
  const { toast } = useToast();
  const [settings, setSettings] = useState<PayoutSettings | null>(null);
  const [overrides, setOverrides] = useState<PayoutOverrideRow[]>([]);
  const [accounts, setAccounts] = useState<PayoutAccountRow[]>([]);
  const [items, setItems] = useState<PayoutItemRow[]>([]);
  const [eligible, setEligible] = useState<EligibleRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [percentText, setPercentText] = useState('');
  const [weekday, setWeekday] = useState('3');
  const [holdText, setHoldText] = useState('2');
  const [from, setFrom] = useState(daysAgo(30));
  const [to, setTo] = useState(daysAgo(0));
  const [adjustment, setAdjustment] = useState<{ org: EligibleRow; cents: string; note: string } | null>(null);
  const [action, setAction] = useState<ItemAction | null>(null);
  const [reference, setReference] = useState('');
  const [note, setNote] = useState('');
  const [editAccount, setEditAccount] = useState<PayoutAccountRow | null>(null);
  const [accountForm, setAccountForm] = useState({ status: 'incomplete' as PayoutAccountStatus, holder: '', masked: '', note: '' });
  const [editOverride, setEditOverride] = useState<{ org: PayoutOverrideRow | PayoutAccountRow; percent: string; weekday: string; hold: string; note: string } | null>(null);

  const fail = (err: unknown, fallback: string) => toast({ title: fallback, description: err instanceof CmsMoneyError ? err.message : 'Try again.', variant: 'destructive' });

  const load = useCallback(async () => {
    try {
      const [s, o, a, i] = await Promise.all([fetchPayoutSettings(), fetchPayoutOverrides(), fetchPayoutAccounts(), fetchPayoutItems()]);
      setSettings(s); setOverrides(o); setAccounts(a); setItems(i);
      setPercentText(s.commissionSet ? percentFromBps(s.commissionBps) : '');
      setWeekday(String(s.weekday)); setHoldText(String(s.holdDays));
      setError(null);
    } catch (err) {
      setError(err instanceof CmsMoneyError ? err.message : 'The payouts could not be loaded.');
    }
  }, []);

  const loadEligible = useCallback(async () => {
    try { setEligible(await fetchEligible(from, to)); } catch (err) { setEligible([]); fail(err, 'The eligible money could not be worked out'); }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [from, to]);

  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void loadEligible(); }, [loadEligible]);

  const saveSettings = async () => {
    const details: { commission_bps?: number; payout_weekday?: number; hold_days?: number } = { payout_weekday: Number(weekday), hold_days: Number(holdText) };
    if (percentText.trim() !== '') {
      const bps = bpsFromPercent(percentText);
      if (bps === null) { toast({ title: 'BottlesUp\'s percentage must be a number from 0 to 100, with at most two decimals.', variant: 'destructive' }); return; }
      details.commission_bps = bps;
    }
    setBusy(true);
    try { await savePayoutSettings(details); toast({ title: 'Payout settings saved' }); await load(); await loadEligible(); }
    catch (err) { fail(err, 'The settings were not saved'); }
    finally { setBusy(false); }
  };

  const createItem = async () => {
    if (!adjustment) return;
    const cents = adjustment.cents.trim() === '' ? 0 : Math.round(Number(adjustment.cents) * 100);
    if (!Number.isFinite(cents)) { toast({ title: 'The adjustment must be an amount in dollars, for example -3.00.', variant: 'destructive' }); return; }
    setBusy(true);
    try {
      await createPayoutItem(adjustment.org.orgId, from, to, cents, adjustment.note);
      toast({ title: 'Payout created', description: `${adjustment.org.orgName}: it is pending until a transfer is made.` });
      setAdjustment(null); await load(); await loadEligible();
    } catch (err) { fail(err, 'The payout was not created'); }
    finally { setBusy(false); }
  };

  const changeItem = async () => {
    if (!action) return;
    setBusy(true);
    try {
      await setPayoutItemStatus(action.item.id, action.to, reference, note);
      toast({ title: `Marked ${PAYOUT_STATUS_LABELS[action.to].toLowerCase()}` });
      setAction(null); setReference(''); setNote(''); await load(); await loadEligible();
    } catch (err) { fail(err, 'The payout was not changed'); }
    finally { setBusy(false); }
  };

  const saveAccount = async () => {
    if (!editAccount) return;
    setBusy(true);
    try {
      await savePayoutAccount(editAccount.orgId, { status: accountForm.status, account_holder: accountForm.holder.trim() || null, masked_account: accountForm.masked.trim() || null, note: accountForm.note.trim() || null });
      toast({ title: 'Account saved' }); setEditAccount(null); await load();
    } catch (err) { fail(err, 'The account was not saved'); }
    finally { setBusy(false); }
  };

  const saveOverride = async () => {
    if (!editOverride) return;
    const details: Record<string, number | string | null> = {};
    if (editOverride.percent.trim() === '') details.commission_bps = null;
    else { const bps = bpsFromPercent(editOverride.percent); if (bps === null) { toast({ title: 'The percentage must be a number from 0 to 100.', variant: 'destructive' }); return; } details.commission_bps = bps; }
    details.payout_weekday = editOverride.weekday === '' ? null : Number(editOverride.weekday);
    details.hold_days = editOverride.hold.trim() === '' ? null : Number(editOverride.hold);
    details.note = editOverride.note.trim() || null;
    setBusy(true);
    try { await savePayoutOverride(editOverride.org.orgId, details); toast({ title: 'Arrangement saved' }); setEditOverride(null); await load(); await loadEligible(); }
    catch (err) { fail(err, 'The arrangement was not saved'); }
    finally { setBusy(false); }
  };

  const openAccount = (a: PayoutAccountRow) => { setEditAccount(a); setAccountForm({ status: a.status, holder: a.holder ?? '', masked: a.masked ?? '', note: a.note ?? '' }); };
  const openOverride = (org: PayoutOverrideRow | PayoutAccountRow) => {
    const o = overrides.find((x) => x.orgId === org.orgId);
    setEditOverride({ org, percent: o?.commissionBps != null ? percentFromBps(o.commissionBps) : '', weekday: o?.weekday != null ? String(o.weekday) : '', hold: o?.holdDays != null ? String(o.holdDays) : '', note: o?.note ?? '' });
  };

  return (
    <div>
      <h1 className="mb-2 text-2xl font-bold text-white">Payouts</h1>
      <p className="mb-6 max-w-2xl text-sm text-gray-400">
        Money collected online through BottlesUp is paid out weekly, after the waiting days. Cash and the venue's own card machine are only recorded and never paid out again.
        Nothing is called paid until a transfer reference is entered.
      </p>
      {error && <div className="mb-4 rounded-md border border-red-900 bg-red-950/40 p-3 text-sm text-red-300">{error}</div>}

      <Tabs defaultValue="settings">
        <TabsList>
          <TabsTrigger value="settings">Settings</TabsTrigger>
          <TabsTrigger value="accounts">Businesses and accounts</TabsTrigger>
          <TabsTrigger value="eligible">Make a payout</TabsTrigger>
          <TabsTrigger value="items">Payouts ({items.filter((i) => ['pending', 'processing', 'failed'].includes(i.status)).length} open)</TabsTrigger>
        </TabsList>

        <TabsContent value="settings" className="mt-4 max-w-xl space-y-4">
          {settings && !settings.commissionSet && (
            <div className="rounded-md border border-amber-800 bg-amber-950/40 p-3 text-sm text-amber-200">
              BottlesUp's percentage has not been chosen yet. Owners are not shown one, and no payout can be worked out until you set it.
            </div>
          )}
          <div className="space-y-2">
            <Label htmlFor="pct">BottlesUp's percentage of what it pays out (%)</Label>
            <Input id="pct" inputMode="decimal" value={percentText} onChange={(e) => setPercentText(e.target.value)} placeholder="for example 10 or 7.5" />
          </div>
          <div className="space-y-2">
            <Label>Weekly payout day</Label>
            <Select value={weekday} onValueChange={setWeekday}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>{WEEKDAYS.map((d, i) => <SelectItem key={d} value={String(i)}>{d}</SelectItem>)}</SelectContent>
            </Select>
          </div>
          <div className="space-y-2">
            <Label htmlFor="hold">Days the money waits after the night (0 to 30)</Label>
            <Input id="hold" inputMode="numeric" value={holdText} onChange={(e) => setHoldText(e.target.value)} />
          </div>
          <div className="text-sm text-gray-400">How it is paid: by manual transfer from BottlesUp. Automatic payouts to a bank account are not connected yet.</div>
          <Button disabled={busy} onClick={() => void saveSettings()}>Save settings</Button>
        </TabsContent>

        <TabsContent value="accounts" className="mt-4">
          <div className="rounded-lg border border-gray-800">
            <Table>
              <TableHeader>
                <TableRow><TableHead>Business</TableHead><TableHead>Account</TableHead><TableHead>Own arrangement</TableHead><TableHead /></TableRow>
              </TableHeader>
              <TableBody>
                {accounts.map((a) => {
                  const o = overrides.find((x) => x.orgId === a.orgId);
                  return (
                    <TableRow key={a.orgId}>
                      <TableCell>{a.orgName}<div className="text-xs text-gray-500">{a.orgKind === 'organizer' ? 'Organizer' : 'Venue owner'}</div></TableCell>
                      <TableCell>
                        <Badge variant={a.status === 'ready' ? 'default' : a.status === 'action_required' ? 'destructive' : 'secondary'}>{ACCOUNT_STATUS_LABELS[a.status]}</Badge>
                        {(a.holder || a.masked) && <div className="mt-1 text-xs text-gray-400">{a.holder} {a.masked}</div>}
                        {a.note && <div className="text-xs text-amber-300">{a.note}</div>}
                      </TableCell>
                      <TableCell className="text-sm">
                        {o ? [o.commissionBps != null ? `${percentFromBps(o.commissionBps)}%` : null, o.weekday != null ? WEEKDAYS[o.weekday] : null, o.holdDays != null ? `${o.holdDays} days` : null].filter(Boolean).join(' · ') : <span className="text-gray-500">the platform's settings</span>}
                      </TableCell>
                      <TableCell className="space-x-2 text-right">
                        <Button size="sm" variant="outline" onClick={() => openAccount(a)}>Account</Button>
                        <Button size="sm" variant="outline" onClick={() => openOverride(a)}>Arrangement</Button>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        </TabsContent>

        <TabsContent value="eligible" className="mt-4">
          <div className="mb-4 flex flex-wrap items-end gap-3">
            <div className="space-y-1"><Label htmlFor="from">First night</Label><Input id="from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></div>
            <div className="space-y-1"><Label htmlFor="to">Last night</Label><Input id="to" type="date" value={to} onChange={(e) => setTo(e.target.value)} /></div>
          </div>
          <p className="mb-3 text-xs text-gray-500">An estimate: what each paid booking took in online, less BottlesUp's own customer fee, for nights past the waiting days that are not in a payout yet.</p>
          {eligible === null ? <div className="text-gray-400">Working it out...</div> : (
            <div className="rounded-lg border border-gray-800">
              <Table>
                <TableHeader><TableRow><TableHead>Business</TableHead><TableHead>Bookings</TableHead><TableHead>Collected online</TableHead><TableHead>BottlesUp keeps</TableHead><TableHead>To pay</TableHead><TableHead /></TableRow></TableHeader>
                <TableBody>
                  {eligible.map((e) => (
                    <TableRow key={e.orgId}>
                      <TableCell>{e.orgName}</TableCell><TableCell>{e.bookings}</TableCell><TableCell>{dollars(e.grossCents)}</TableCell>
                      <TableCell>{dollars(e.commissionCents)} <span className="text-xs text-gray-500">({percentFromBps(e.commissionBps)}%)</span></TableCell>
                      <TableCell className="font-medium">{dollars(e.netCents)}</TableCell>
                      <TableCell className="text-right"><Button size="sm" disabled={!e.commissionSet} title={e.commissionSet ? undefined : 'Choose BottlesUp\'s percentage first'} onClick={() => setAdjustment({ org: e, cents: '', note: '' })}>Make this payout</Button></TableCell>
                    </TableRow>
                  ))}
                  {eligible.length === 0 && <TableRow><TableCell colSpan={6} className="text-center text-gray-500">Nothing is eligible for these nights.</TableCell></TableRow>}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        <TabsContent value="items" className="mt-4">
          <div className="rounded-lg border border-gray-800">
            <Table>
              <TableHeader><TableRow><TableHead>Business</TableHead><TableHead>Nights</TableHead><TableHead>Gross</TableHead><TableHead>Kept</TableHead><TableHead>Adjustment</TableHead><TableHead>Net</TableHead><TableHead>Status</TableHead><TableHead /></TableRow></TableHeader>
              <TableBody>
                {items.map((i) => (
                  <TableRow key={i.id}>
                    <TableCell>{i.orgName}<div className="text-xs text-gray-500">{i.bookings} bookings · made {formatWhen(i.createdAt)}</div></TableCell>
                    <TableCell className="text-sm">{i.periodStart} to {i.periodEnd}{i.expectedOn && <div className="text-xs text-gray-500">expected {i.expectedOn}</div>}</TableCell>
                    <TableCell>{dollars(i.grossCents)}</TableCell>
                    <TableCell>{dollars(i.commissionCents)} <span className="text-xs text-gray-500">({percentFromBps(i.commissionBps)}%)</span></TableCell>
                    <TableCell>{i.adjustmentsCents === 0 ? '-' : <>{dollars(i.adjustmentsCents)}<div className="text-xs text-gray-500">{i.adjustmentNote}</div></>}</TableCell>
                    <TableCell className="font-medium">{dollars(i.netCents)}</TableCell>
                    <TableCell>
                      <Badge variant={i.status === 'paid' ? 'default' : i.status === 'failed' ? 'destructive' : 'secondary'}>{PAYOUT_STATUS_LABELS[i.status]}</Badge>
                      {i.reference && <div className="mt-1 text-xs text-gray-400">{i.reference}</div>}
                      {i.failureNote && <div className="mt-1 text-xs text-red-300">{i.failureNote}</div>}
                    </TableCell>
                    <TableCell className="space-x-1 text-right">
                      {i.status === 'pending' && <Button size="sm" variant="outline" onClick={() => setAction({ item: i, to: 'processing' })}>Processing</Button>}
                      {(i.status === 'pending' || i.status === 'processing' || i.status === 'failed') && <Button size="sm" onClick={() => setAction({ item: i, to: 'paid' })}>Paid</Button>}
                      {(i.status === 'pending' || i.status === 'processing') && <Button size="sm" variant="outline" onClick={() => setAction({ item: i, to: 'failed' })}>Failed</Button>}
                      {(i.status === 'pending' || i.status === 'failed') && <Button size="sm" variant="ghost" onClick={() => setAction({ item: i, to: 'cancelled' })}>Cancel</Button>}
                    </TableCell>
                  </TableRow>
                ))}
                {items.length === 0 && <TableRow><TableCell colSpan={8} className="text-center text-gray-500">No payouts yet.</TableCell></TableRow>}
              </TableBody>
            </Table>
          </div>
        </TabsContent>
      </Tabs>

      <Dialog open={adjustment !== null} onOpenChange={(open) => { if (!open && !busy) setAdjustment(null); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>Make a payout for {adjustment?.org.orgName}</DialogTitle>
            <DialogDescription>{adjustment && `${adjustment.org.bookings} bookings, ${dollars(adjustment.org.netCents)} after BottlesUp's ${percentFromBps(adjustment.org.commissionBps)}%. Each booking can be in one payout only.`}</DialogDescription></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1"><Label htmlFor="adj">Adjustment in dollars (optional, for example -3.00)</Label><Input id="adj" inputMode="decimal" value={adjustment?.cents ?? ''} onChange={(e) => setAdjustment((a) => (a ? { ...a, cents: e.target.value } : a))} /></div>
            <div className="space-y-1"><Label htmlFor="adjn">What the adjustment is for</Label><Input id="adjn" value={adjustment?.note ?? ''} onChange={(e) => setAdjustment((a) => (a ? { ...a, note: e.target.value } : a))} /></div>
          </div>
          <DialogFooter><Button variant="outline" disabled={busy} onClick={() => setAdjustment(null)}>Not now</Button><Button disabled={busy} onClick={() => void createItem()}>Create the payout</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={action !== null} onOpenChange={(open) => { if (!open && !busy) { setAction(null); setReference(''); setNote(''); } }}>
        <DialogContent>
          <DialogHeader><DialogTitle>Mark {action?.item.orgName}'s payout as {action ? PAYOUT_STATUS_LABELS[action.to].toLowerCase() : ''}</DialogTitle>
            <DialogDescription>{action?.to === 'paid' ? 'Only after the transfer was made. The reference is kept with the payout and cannot be changed.' : action?.to === 'cancelled' ? 'Its bookings go back to being eligible for another payout.' : action?.to === 'failed' ? 'Say why, so it can be put right and tried again.' : ''}</DialogDescription></DialogHeader>
          {action?.to === 'paid' && <div className="space-y-1"><Label htmlFor="ref">Transfer reference</Label><Input id="ref" value={reference} onChange={(e) => setReference(e.target.value)} /></div>}
          {action?.to === 'failed' && <div className="space-y-1"><Label htmlFor="why">Why it failed</Label><Textarea id="why" value={note} onChange={(e) => setNote(e.target.value)} /></div>}
          <DialogFooter><Button variant="outline" disabled={busy} onClick={() => { setAction(null); setReference(''); setNote(''); }}>Not now</Button><Button disabled={busy} onClick={() => void changeItem()}>Confirm</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={editAccount !== null} onOpenChange={(open) => { if (!open && !busy) setEditAccount(null); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>{editAccount?.orgName}'s payout account</DialogTitle>
            <DialogDescription>Set after BottlesUp has checked the details. Never enter a full account number: only the last digits, for example •••• 1234.</DialogDescription></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1"><Label>Status</Label>
              <Select value={accountForm.status} onValueChange={(v) => setAccountForm((f) => ({ ...f, status: v as PayoutAccountStatus }))}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>{(Object.keys(ACCOUNT_STATUS_LABELS) as PayoutAccountStatus[]).map((s) => <SelectItem key={s} value={s}>{ACCOUNT_STATUS_LABELS[s]}</SelectItem>)}</SelectContent>
              </Select></div>
            <div className="space-y-1"><Label htmlFor="holder">Account holder</Label><Input id="holder" value={accountForm.holder} onChange={(e) => setAccountForm((f) => ({ ...f, holder: e.target.value }))} /></div>
            <div className="space-y-1"><Label htmlFor="mask">Last digits of the account</Label><Input id="mask" value={accountForm.masked} onChange={(e) => setAccountForm((f) => ({ ...f, masked: e.target.value }))} placeholder="•••• 1234" /></div>
            <div className="space-y-1"><Label htmlFor="anote">Note the business will see (say what action is needed)</Label><Textarea id="anote" value={accountForm.note} onChange={(e) => setAccountForm((f) => ({ ...f, note: e.target.value }))} /></div>
          </div>
          <DialogFooter><Button variant="outline" disabled={busy} onClick={() => setEditAccount(null)}>Not now</Button><Button disabled={busy} onClick={() => void saveAccount()}>Save</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={editOverride !== null} onOpenChange={(open) => { if (!open && !busy) setEditOverride(null); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>{editOverride?.org.orgName}: its own arrangement</DialogTitle>
            <DialogDescription>Leave a box empty to use the platform's setting. Clearing all three removes the arrangement.</DialogDescription></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1"><Label htmlFor="opct">BottlesUp's percentage (%)</Label><Input id="opct" inputMode="decimal" value={editOverride?.percent ?? ''} onChange={(e) => setEditOverride((o) => (o ? { ...o, percent: e.target.value } : o))} /></div>
            <div className="space-y-1"><Label>Payout day</Label>
              <Select value={editOverride?.weekday || 'platform'} onValueChange={(v) => setEditOverride((o) => (o ? { ...o, weekday: v === 'platform' ? '' : v } : o))}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent><SelectItem value="platform">The platform's day</SelectItem>{WEEKDAYS.map((d, i) => <SelectItem key={d} value={String(i)}>{d}</SelectItem>)}</SelectContent>
              </Select></div>
            <div className="space-y-1"><Label htmlFor="ohold">Waiting days</Label><Input id="ohold" inputMode="numeric" value={editOverride?.hold ?? ''} onChange={(e) => setEditOverride((o) => (o ? { ...o, hold: e.target.value } : o))} /></div>
            <div className="space-y-1"><Label htmlFor="onote">Note</Label><Input id="onote" value={editOverride?.note ?? ''} onChange={(e) => setEditOverride((o) => (o ? { ...o, note: e.target.value } : o))} /></div>
          </div>
          <DialogFooter><Button variant="outline" disabled={busy} onClick={() => setEditOverride(null)}>Not now</Button><Button disabled={busy} onClick={() => void saveOverride()}>Save</Button></DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Payouts;
