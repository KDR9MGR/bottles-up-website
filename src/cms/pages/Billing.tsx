import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { AccountError } from '@/lib/account';
import {
  SOURCE_LABELS, fetchBillingSettings, fetchCreators, fetchCredits, fetchSubscriptions, formFrom, markCreatorPaid, markCreditPaid, money, percentText, saveBillingSettings, settingsProblem,
  type BillingSettings, type CreatorPayout, type ReferralCredit, type SettingsForm, type Subscription,
} from '@/lib/billing';

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString() : '');
const errorText = (e: unknown, fallback: string) => (e instanceof AccountError ? e.message : fallback);

type Paying = { kind: 'credit'; credit: ReferralCredit } | { kind: 'creator'; creator: CreatorPayout };

/**
 * Where BottlesUp staff look after the money that is not hiring: who has a subscription, the referral credits waiting to be paid, the creators who can be paid from tips, and the prices
 * and percentages. BottlesUp pays referrers and creators itself, then records the transfer here; every change is written to the audit log.
 */
const Billing = () => {
  const { toast } = useToast();
  const [settings, setSettings] = useState<BillingSettings | null>(null);
  const [form, setForm] = useState<SettingsForm | null>(null);
  const [subs, setSubs] = useState<Subscription[] | null>(null);
  const [pastDue, setPastDue] = useState<Subscription[] | null>(null);
  const [credits, setCredits] = useState<ReferralCredit[] | null>(null);
  const [paidCredits, setPaidCredits] = useState<ReferralCredit[] | null>(null);
  const [creators, setCreators] = useState<CreatorPayout[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [paying, setPaying] = useState<Paying | null>(null);
  const [reference, setReference] = useState('');

  const load = useCallback(async () => {
    try {
      const [s, a, p, c, pc, cr] = await Promise.all([fetchBillingSettings(), fetchSubscriptions('active'), fetchSubscriptions('past_due'), fetchCredits('payable'), fetchCredits('paid'), fetchCreators()]);
      setSettings(s);
      setForm(formFrom(s));
      setSubs(a);
      setPastDue(p);
      setCredits(c);
      setPaidCredits(pc);
      setCreators(cr);
      setError(null);
    } catch (e) {
      setError(errorText(e, 'Could not load the billing page.'));
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const save = async () => {
    if (!form) return;
    const problem = settingsProblem(form);
    if (problem) {
      toast({ title: 'Check this', description: problem, variant: 'destructive' });
      return;
    }
    setBusy(true);
    try {
      const s = await saveBillingSettings(form);
      setSettings(s);
      setForm(formFrom(s));
      toast({ title: 'Saved', description: 'New subscriptions, credits and tips use these. A subscription already live keeps the commission it was given until its period ends.' });
    } catch (e) {
      toast({ title: 'Could not save', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
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
      if (paying.kind === 'credit') await markCreditPaid(paying.credit.id, reference);
      else await markCreatorPaid(paying.creator.creator, reference);
      toast({ title: 'Marked as paid' });
      setPaying(null);
      await load();
    } catch (e) {
      toast({ title: 'Could not do that', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const set = (k: keyof SettingsForm) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => (f ? { ...f, [k]: e.target.value } : f));

  const subCard = (s: Subscription) => (
    <div key={s.id} className="rounded-lg border border-gray-800 p-4" data-testid="subscription">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{s.profile}</Badge>
        <Badge variant="secondary">{s.plan === 'monthly' ? 'Monthly' : 'Yearly'}</Badge>
        {s.status === 'past_due' && <Badge variant="destructive">Payment failed</Badge>}
        {s.cancelAtPeriodEnd && <Badge variant="outline">Ends at the end of the period</Badge>}
      </div>
      <p className="mt-2 text-xs text-gray-400">{s.payer ? `${s.payer.name}${s.payer.handle ? ` (@${s.payer.handle})` : ''}` : 'A payer whose account is gone'}{s.currentPeriodEnd ? ` - paid until ${when(s.currentPeriodEnd)}` : ''}</p>
    </div>
  );

  const creditCard = (c: ReferralCredit) => (
    <div key={c.id} className="rounded-lg border border-gray-800 p-4" data-testid="credit">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{c.referrer ?? (c.referrerHandle ? `@${c.referrerHandle}` : 'A referrer whose account is gone')}</Badge>
        <Badge variant="secondary">Pay {money(c.amountCents)}</Badge>
        {c.status === 'paid' && <Badge variant="outline">Paid {when(c.paidAt)}: {c.reference}</Badge>}
      </div>
      <p className="mt-2 text-xs text-gray-400">For {SOURCE_LABELS[c.source]} - {when(c.createdAt)}{c.person ? ` - send to ${c.person.name}${c.person.handle ? ` (@${c.person.handle})` : ''}` : ''}</p>
      {c.status === 'payable' && <div className="mt-3"><Button size="sm" onClick={() => { setPaying({ kind: 'credit', credit: c }); setReference(''); }}>I have paid this</Button></div>}
    </div>
  );

  const creatorCard = (c: CreatorPayout) => (
    <div key={c.creator} className="rounded-lg border border-gray-800 p-4" data-testid="creator">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{c.name}</Badge>
        <Badge variant="secondary">Pay {money(c.withdrawableCents)}</Badge>
        <Badge variant="outline">{c.tips} tip{c.tips === 1 ? '' : 's'}</Badge>
      </div>
      <p className="mt-2 text-xs text-gray-400">{c.person ? `Send to ${c.person.name}${c.person.handle ? ` (@${c.person.handle})` : ''}` : 'The owner\'s account is gone'}</p>
      <div className="mt-3"><Button size="sm" onClick={() => { setPaying({ kind: 'creator', creator: c }); setReference(''); }}>I have paid this</Button></div>
    </div>
  );

  const amount = paying ? (paying.kind === 'credit' ? paying.credit.amountCents : paying.creator.withdrawableCents) : 0;
  const who = paying ? (paying.kind === 'credit' ? (paying.credit.person?.name ?? paying.credit.referrer ?? 'the referrer') : (paying.creator.person?.name ?? paying.creator.name)) : '';

  return (
    <div className="max-w-3xl">
      <h1 className="mb-2 text-2xl font-bold text-white">Subscriptions, referrals and tips{credits && creators ? ` (${credits.length + creators.length} to pay)` : ''}</h1>
      <p className="mb-6 text-sm text-gray-400">
        Subscriptions are paid to BottlesUp through Stripe. Referral credits and tips are held by BottlesUp: send the money from your bank, then record the transfer here.
      </p>
      {error && <div className="mb-4 rounded border border-red-900 p-3 text-sm text-red-300">{error} <Button size="sm" variant="outline" onClick={() => void load()}>Try again</Button></div>}

      <Tabs defaultValue="subscriptions">
        <TabsList>
          <TabsTrigger value="subscriptions">Subscriptions{subs ? ` (${subs.length})` : ''}</TabsTrigger>
          <TabsTrigger value="credits">Referral credits{credits && credits.length > 0 ? ` (${credits.length})` : ''}</TabsTrigger>
          <TabsTrigger value="creators">Creators{creators && creators.length > 0 ? ` (${creators.length})` : ''}</TabsTrigger>
          <TabsTrigger value="settings">Settings</TabsTrigger>
        </TabsList>

        <TabsContent value="subscriptions" className="space-y-3">
          {subs === null ? <div className="text-gray-400">Loading...</div> : subs.length === 0 ? <div className="text-gray-500">No profile is subscribed.</div> : subs.map(subCard)}
          {pastDue && pastDue.length > 0 && <h2 className="pt-4 text-sm font-semibold text-gray-300">Payment failed (still subscribed until the period ends)</h2>}
          {pastDue?.map(subCard)}
        </TabsContent>

        <TabsContent value="credits" className="space-y-3">
          <p className="text-sm text-gray-400">A person who used someone's code paid for something: that someone is owed a credit. Send it, then record it.</p>
          {credits === null ? <div className="text-gray-400">Loading...</div> : credits.length === 0 ? <div className="text-gray-500">No credit is waiting.</div> : credits.map(creditCard)}
          {paidCredits && paidCredits.length > 0 && <h2 className="pt-4 text-sm font-semibold text-gray-300">Paid</h2>}
          {paidCredits?.map(creditCard)}
        </TabsContent>

        <TabsContent value="creators" className="space-y-3">
          <p className="text-sm text-gray-400">Tips that were paid, less BottlesUp's commission, for each creator. Send the money, then record it: it covers every tip they have.</p>
          {creators === null ? <div className="text-gray-400">Loading...</div> : creators.length === 0 ? <div className="text-gray-500">Nobody is waiting to be paid.</div> : creators.map(creatorCard)}
        </TabsContent>

        <TabsContent value="settings" className="space-y-4">
          {settings === null || form === null ? <div className="text-gray-400">Loading...</div> : (
            <>
              <h2 className="text-sm font-semibold text-gray-300">Subscription</h2>
              <label className="block text-sm text-gray-300">Monthly price, {settings.currency.toUpperCase()}
                <Input className="mt-1 max-w-[10rem]" value={form.monthly} onChange={set('monthly')} inputMode="decimal" aria-label="Monthly price" />
              </label>
              <label className="block text-sm text-gray-300">Yearly price, {settings.currency.toUpperCase()}
                <Input className="mt-1 max-w-[10rem]" value={form.yearly} onChange={set('yearly')} inputMode="decimal" aria-label="Yearly price" />
              </label>
              <label className="block text-sm text-gray-300">Stripe price id for monthly (optional, like price_123: the price above is used when empty)
                <Input className="mt-1 max-w-xs" value={form.priceMonthly} onChange={set('priceMonthly')} aria-label="Stripe price id for monthly" />
              </label>
              <label className="block text-sm text-gray-300">Stripe price id for yearly (optional)
                <Input className="mt-1 max-w-xs" value={form.priceYearly} onChange={set('priceYearly')} aria-label="Stripe price id for yearly" />
              </label>
              <label className="block text-sm text-gray-300">Commission on hiring for a subscribed profile (now {percentText(settings.subscribedCommissionBps)})
                <Input className="mt-1 max-w-[10rem]" value={form.subscribedCommission} onChange={set('subscribedCommission')} inputMode="decimal" aria-label="Subscribed commission percent" />
              </label>
              <h2 className="pt-2 text-sm font-semibold text-gray-300">Referrals</h2>
              <label className="block text-sm text-gray-300">Credit for a referred person's first purchase
                <Input className="mt-1 max-w-[10rem]" value={form.referralCredit} onChange={set('referralCredit')} inputMode="decimal" aria-label="Referral credit" />
              </label>
              <label className="block text-sm text-gray-300">Days a referral counts for after it is used
                <Input className="mt-1 max-w-[10rem]" value={form.referralDays} onChange={set('referralDays')} inputMode="numeric" aria-label="Referral days" />
              </label>
              <label className="block text-sm text-gray-300">Most credits one referrer earns in a month
                <Input className="mt-1 max-w-[10rem]" value={form.referralCap} onChange={set('referralCap')} inputMode="numeric" aria-label="Referral monthly cap" />
              </label>
              <h2 className="pt-2 text-sm font-semibold text-gray-300">Tips</h2>
              <label className="block text-sm text-gray-300">Commission on tips (now {percentText(settings.tipCommissionBps)})
                <Input className="mt-1 max-w-[10rem]" value={form.tipCommission} onChange={set('tipCommission')} inputMode="decimal" aria-label="Tip commission percent" />
              </label>
              <label className="block text-sm text-gray-300">Smallest tip
                <Input className="mt-1 max-w-[10rem]" value={form.tipMin} onChange={set('tipMin')} inputMode="decimal" aria-label="Smallest tip" />
              </label>
              <label className="block text-sm text-gray-300">Biggest tip
                <Input className="mt-1 max-w-[10rem]" value={form.tipMax} onChange={set('tipMax')} inputMode="decimal" aria-label="Biggest tip" />
              </label>
              <Button onClick={() => void save()} disabled={busy}>{busy ? 'Saving...' : 'Save'}</Button>
            </>
          )}
        </TabsContent>
      </Tabs>

      <Dialog open={paying !== null} onOpenChange={(o) => { if (!o) setPaying(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Record the transfer</DialogTitle>
            <DialogDescription>{paying ? `${money(amount)} to ${who}. This cannot be undone.` : ''}</DialogDescription>
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

export default Billing;
