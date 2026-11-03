import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { AccountError } from '@/lib/account';
import {
  OUTCOME_HELP, OUTCOME_LABELS, decisionProblem, fetchDisputes, fetchPayouts, fetchSettings, markPayoutPaid, money, percentText, refundToCents, resolveDispute, saveSettings, settingsProblem,
  type Dispute, type DisputeOutcome, type MarketSettings, type Payout,
} from '@/lib/marketplace';

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : '');
const errorText = (e: unknown, fallback: string) => (e instanceof AccountError ? e.message : fallback);
const OUTCOMES: DisputeOutcome[] = ['release', 'refund_part', 'refund_full'];

/**
 * Where BottlesUp staff look after hiring professionals: disputes between a customer and a professional (the payout is held until you decide), the payouts BottlesUp makes to
 * professionals (BottlesUp pays them itself, then records the transfer here), and the settings. Every decision is written to the audit log.
 */
const Marketplace = () => {
  const { toast } = useToast();
  const [disputes, setDisputes] = useState<Dispute[] | null>(null);
  const [decided, setDecided] = useState<Dispute[] | null>(null);
  const [payouts, setPayouts] = useState<Payout[] | null>(null);
  const [paid, setPaid] = useState<Payout[] | null>(null);
  const [settings, setSettings] = useState<MarketSettings | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [deciding, setDeciding] = useState<Dispute | null>(null);
  const [outcome, setOutcome] = useState<DisputeOutcome | null>(null);
  const [refund, setRefund] = useState('');
  const [note, setNote] = useState('');

  const [paying, setPaying] = useState<Payout | null>(null);
  const [reference, setReference] = useState('');

  const [commission, setCommission] = useState('5');
  const [freeDays, setFreeDays] = useState('7');
  const [confirmDays, setConfirmDays] = useState('3');

  const load = useCallback(async () => {
    try {
      const [o, all, p, pa, s] = await Promise.all([fetchDisputes('open'), fetchDisputes('resolved'), fetchPayouts('releasable'), fetchPayouts('paid'), fetchSettings()]);
      setDisputes(o);
      setDecided(all);
      setPayouts(p);
      setPaid(pa);
      setSettings(s);
      setCommission(String(s.commissionBps / 100));
      setFreeDays(String(s.freeCancelDays));
      setConfirmDays(String(s.confirmDays));
      setError(null);
    } catch (e) {
      setError(errorText(e, 'Could not load the marketplace.'));
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const decide = async () => {
    if (!deciding) return;
    const problem = decisionProblem(outcome, refund, deciding.booking.paidCents, note);
    if (problem) {
      toast({ title: 'Check this', description: problem, variant: 'destructive' });
      return;
    }
    setBusy(true);
    try {
      await resolveDispute(deciding.id, outcome!, refundToCents(refund), note);
      toast({ title: 'Decided' });
      setDeciding(null);
      await load();
    } catch (e) {
      toast({ title: 'Could not do that', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const pay = async () => {
    if (!paying) return;
    if (reference.trim() === '') {
      toast({ title: 'Check this', description: 'Write the transfer reference.', variant: 'destructive' });
      return;
    }
    setBusy(true);
    try {
      await markPayoutPaid(paying.id, reference);
      toast({ title: 'Marked as paid' });
      setPaying(null);
      await load();
    } catch (e) {
      toast({ title: 'Could not do that', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    const problem = settingsProblem(commission, Number(freeDays), Number(confirmDays));
    if (problem) {
      toast({ title: 'Check this', description: problem, variant: 'destructive' });
      return;
    }
    setBusy(true);
    try {
      setSettings(await saveSettings(commission, Number(freeDays), Number(confirmDays)));
      toast({ title: 'Saved', description: 'New bookings use these. Bookings already accepted keep the commission they were accepted with.' });
    } catch (e) {
      toast({ title: 'Could not save', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const disputeCard = (d: Dispute) => (
    <div key={d.id} className="rounded-lg border border-gray-800 p-4" data-testid="dispute">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{d.booking.title}</Badge>
        <Badge variant="secondary">{money(d.booking.paidCents, d.booking.currency)} paid of {money(d.booking.totalCents, d.booking.currency)}</Badge>
        {d.outcome && <Badge variant="outline">{OUTCOME_LABELS[d.outcome]}{d.refundCents ? `: ${money(d.refundCents, d.booking.currency)}` : ''}</Badge>}
      </div>
      <p className="mt-2 text-xs text-gray-400">
        {d.booking.provider ?? 'A professional whose account is gone'} for {d.booking.client ? `${d.booking.client.name}${d.booking.client.handle ? ` (@${d.booking.client.handle})` : ''}` : 'a customer whose account is gone'}
        {d.booking.eventDate ? ` - job on ${d.booking.eventDate}` : ''} - opened {when(d.createdAt)}
      </p>
      <blockquote className="mt-2 whitespace-pre-wrap border-l-2 border-gray-700 pl-3 text-sm text-white">{d.reason}</blockquote>
      {d.note && <p className="mt-2 text-xs text-gray-500">Your note: {d.note}</p>}
      {d.status === 'open' && (
        <div className="mt-3">
          <Button size="sm" onClick={() => { setDeciding(d); setOutcome(null); setRefund(''); setNote(''); }}>Decide</Button>
        </div>
      )}
    </div>
  );

  const payoutCard = (p: Payout) => (
    <div key={p.id} className="rounded-lg border border-gray-800 p-4" data-testid="payout">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{p.provider ?? 'A professional whose account is gone'}</Badge>
        <Badge variant="secondary">Pay {money(p.netCents, p.currency)}</Badge>
        {p.status === 'paid' && <Badge variant="outline">Paid {when(p.paidAt)}: {p.reference}</Badge>}
      </div>
      <p className="mt-2 text-xs text-gray-400">{p.title}{p.eventDate ? ` - job on ${p.eventDate}` : ''} - {money(p.grossCents, p.currency)} held, {money(p.commissionCents, p.currency)} commission</p>
      {p.status === 'releasable' && (
        <div className="mt-3">
          <Button size="sm" onClick={() => { setPaying(p); setReference(''); }}>I have paid this</Button>
        </div>
      )}
    </div>
  );

  return (
    <div className="max-w-3xl">
      <h1 className="mb-2 text-2xl font-bold text-white">Hiring professionals{disputes ? ` (${disputes.length} dispute${disputes.length === 1 ? '' : 's'} open)` : ''}</h1>
      <p className="mb-6 text-sm text-gray-400">
        Customers pay BottlesUp; the money is held until the job is confirmed. Decide disputes here, pay professionals from your bank and record the transfer, and set the commission.
      </p>
      {error && <div className="mb-4 rounded border border-red-900 p-3 text-sm text-red-300">{error} <Button size="sm" variant="outline" onClick={() => void load()}>Try again</Button></div>}

      <Tabs defaultValue="disputes">
        <TabsList>
          <TabsTrigger value="disputes">Disputes</TabsTrigger>
          <TabsTrigger value="payouts">Payouts{payouts && payouts.length > 0 ? ` (${payouts.length})` : ''}</TabsTrigger>
          <TabsTrigger value="settings">Settings</TabsTrigger>
        </TabsList>

        <TabsContent value="disputes" className="space-y-3">
          {disputes === null ? <div className="text-gray-400">Loading...</div> : disputes.length === 0 ? <div className="text-gray-500">No dispute is waiting.</div> : disputes.map(disputeCard)}
          {decided && decided.length > 0 && <h2 className="pt-4 text-sm font-semibold text-gray-300">Decided</h2>}
          {decided?.map(disputeCard)}
        </TabsContent>

        <TabsContent value="payouts" className="space-y-3">
          <p className="text-sm text-gray-400">Professionals whose job is confirmed (or whose deposit was kept after a late cancellation). Send the money from your bank, then press the button and write the reference.</p>
          {payouts === null ? <div className="text-gray-400">Loading...</div> : payouts.length === 0 ? <div className="text-gray-500">Nobody is waiting to be paid.</div> : payouts.map(payoutCard)}
          {paid && paid.length > 0 && <h2 className="pt-4 text-sm font-semibold text-gray-300">Paid</h2>}
          {paid?.map(payoutCard)}
        </TabsContent>

        <TabsContent value="settings" className="space-y-4">
          {settings === null ? <div className="text-gray-400">Loading...</div> : (
            <>
              <label className="block text-sm text-gray-300">Commission on each job (now {percentText(settings.commissionBps)})
                <Input className="mt-1 max-w-[10rem]" value={commission} onChange={(e) => setCommission(e.target.value)} inputMode="decimal" aria-label="Commission percent" />
              </label>
              <label className="block text-sm text-gray-300">Free cancellation by the customer, days before the job (now {settings.freeCancelDays})
                <Input className="mt-1 max-w-[10rem]" value={freeDays} onChange={(e) => setFreeDays(e.target.value)} inputMode="numeric" aria-label="Free cancellation days" />
              </label>
              <label className="block text-sm text-gray-300">Confirm a job automatically after it was marked done, days (now {settings.confirmDays})
                <Input className="mt-1 max-w-[10rem]" value={confirmDays} onChange={(e) => setConfirmDays(e.target.value)} inputMode="numeric" aria-label="Automatic confirmation days" />
              </label>
              <p className="text-xs text-gray-500">A cancellation later than the free days keeps the deposit (at least 30% of the price) for the professional. Bookings already accepted keep the commission they were accepted with.</p>
              <Button onClick={() => void save()} disabled={busy}>{busy ? 'Saving...' : 'Save'}</Button>
            </>
          )}
        </TabsContent>
      </Tabs>

      <Dialog open={deciding !== null} onOpenChange={(o) => { if (!o) setDeciding(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Decide this dispute</DialogTitle>
            <DialogDescription>{deciding ? `${money(deciding.booking.paidCents, deciding.booking.currency)} is held for ${deciding.booking.title}. Both people can be shown your note.` : ''}</DialogDescription>
          </DialogHeader>
          <div className="space-y-2">
            {OUTCOMES.map((o) => (
              <button key={o} type="button" onClick={() => setOutcome(o)} className={`block w-full rounded border p-3 text-left text-sm ${outcome === o ? 'border-orange-500 text-white' : 'border-gray-800 text-gray-300'}`}>
                <div className="font-medium">{OUTCOME_LABELS[o]}</div>
                <div className="text-xs text-gray-400">{OUTCOME_HELP[o]}</div>
              </button>
            ))}
          </div>
          {outcome === 'refund_part' && <Input value={refund} onChange={(e) => setRefund(e.target.value)} placeholder="Amount to refund, like 400.00" inputMode="decimal" aria-label="Amount to refund" />}
          <Textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} placeholder="A note (required)" />
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeciding(null)} disabled={busy}>Cancel</Button>
            <Button onClick={() => void decide()} disabled={busy}>{busy ? 'Working...' : 'Confirm'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={paying !== null} onOpenChange={(o) => { if (!o) setPaying(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Record the transfer</DialogTitle>
            <DialogDescription>{paying ? `${money(paying.netCents, paying.currency)} to ${paying.provider ?? 'the professional'}. This cannot be undone.` : ''}</DialogDescription>
          </DialogHeader>
          <Input value={reference} onChange={(e) => setReference(e.target.value)} maxLength={120} placeholder="Transfer reference" aria-label="Transfer reference" />
          <DialogFooter>
            <Button variant="outline" onClick={() => setPaying(null)} disabled={busy}>Cancel</Button>
            <Button onClick={() => void pay()} disabled={busy}>{busy ? 'Working...' : 'Mark as paid'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Marketplace;
