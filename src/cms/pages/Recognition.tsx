import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { AccountError } from '@/lib/account';
import {
  decideReview, decideVerification, fetchAwards, fetchLevels, fetchPlaques, fetchReviews, fetchVerifications, followersText, levelForm, levelProblem, markDelivered, markShipped, revokeAward, saveLevel,
  type Award, type LevelForm, type Person, type Plaque, type RankLevel, type RankReview, type Verification,
} from '@/lib/recognition';

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString() : '');
const errorText = (e: unknown, fallback: string) => (e instanceof AccountError ? e.message : e instanceof Error ? e.message : fallback);
const who = (p: Person) => `${p.name}${p.handle ? ` (@${p.handle})` : ''}`;

type Deciding =
  | { kind: 'verification'; item: Verification; decision: 'approve' | 'reject' | 'revoke' }
  | { kind: 'review'; item: RankReview; approve: boolean }
  | { kind: 'award'; item: Award };

/**
 * Where BottlesUp staff look after recognition in the customer app: who asked to be verified, who asked for a rank, the ranks already awarded (and taking one back), the plaques to post with
 * their addresses, and the ranks themselves. Nothing here is automatic: a rank is awarded only when a person here says the followers are genuine, and every decision is written to the audit log.
 */
const Recognition = () => {
  const { toast } = useToast();
  const [verifications, setVerifications] = useState<Verification[] | null>(null);
  const [approved, setApproved] = useState<Verification[] | null>(null);
  const [reviews, setReviews] = useState<RankReview[] | null>(null);
  const [awards, setAwards] = useState<Award[] | null>(null);
  const [plaques, setPlaques] = useState<Plaque[] | null>(null);
  const [shipped, setShipped] = useState<Plaque[] | null>(null);
  const [levels, setLevels] = useState<RankLevel[] | null>(null);
  const [forms, setForms] = useState<Record<string, LevelForm>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [deciding, setDeciding] = useState<Deciding | null>(null);
  const [reason, setReason] = useState('');
  const [shipping, setShipping] = useState<Plaque | null>(null);
  const [carrier, setCarrier] = useState('');
  const [tracking, setTracking] = useState('');

  const load = useCallback(async () => {
    try {
      const [v, a, r, aw, p, s, l] = await Promise.all([fetchVerifications('requested'), fetchVerifications('approved'), fetchReviews('pending'), fetchAwards(), fetchPlaques('requested'), fetchPlaques('shipped'), fetchLevels()]);
      setVerifications(v);
      setApproved(a);
      setReviews(r);
      setAwards(aw);
      setPlaques(p);
      setShipped(s);
      setLevels(l);
      setForms(Object.fromEntries(l.map((x) => [x.key, levelForm(x)])));
      setError(null);
    } catch (e) {
      setError(errorText(e, 'Could not load this page.'));
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const run = async (work: () => Promise<void>, done: string) => {
    setBusy(true);
    try {
      await work();
      toast({ title: done });
      await load();
      return true;
    } catch (e) {
      toast({ title: 'Could not do that', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
      return false;
    } finally {
      setBusy(false);
    }
  };

  const decide = async () => {
    if (!deciding) return;
    const needsReason = deciding.kind === 'award' || (deciding.kind === 'verification' && deciding.decision !== 'approve') || (deciding.kind === 'review' && !deciding.approve);
    if (needsReason && reason.trim().length < 3) {
      toast({ title: 'Check this', description: 'Write the reason (at least 3 characters). The person reads it.', variant: 'destructive' });
      return;
    }
    const d = deciding;
    const ok = await run(async () => {
      if (d.kind === 'verification') await decideVerification(d.item.id, d.decision, reason);
      else if (d.kind === 'review') await decideReview(d.item.id, d.approve, reason);
      else await revokeAward(d.item.id, reason);
    }, 'Done');
    if (ok) setDeciding(null);
  };

  const ship = async () => {
    if (!shipping) return;
    if (carrier.trim().length < 2 || tracking.trim().length < 3) {
      toast({ title: 'Check this', description: 'Write the carrier and the tracking number.', variant: 'destructive' });
      return;
    }
    const p = shipping;
    const ok = await run(() => markShipped(p.id, carrier, tracking), 'Marked as shipped');
    if (ok) setShipping(null);
  };

  const saveOne = async (key: string) => {
    const f = forms[key];
    if (!f) return;
    const problem = levelProblem(f, key);
    if (problem) {
      toast({ title: 'Check this', description: problem, variant: 'destructive' });
      return;
    }
    await run(() => saveLevel(key, f), 'Saved');
  };

  const setLevel = (key: string, patch: Partial<LevelForm>) => setForms((all) => ({ ...all, [key]: { ...all[key], ...patch } }));
  const open = (d: Deciding) => { setDeciding(d); setReason(''); };

  const verificationCard = (v: Verification) => (
    <div key={v.id} className="rounded-lg border border-gray-800 p-4" data-testid="verification">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{who(v.profile)}</Badge>
        {v.profile.category && <Badge variant="secondary">{v.profile.category}</Badge>}
        <Badge variant="outline">{followersText(v.followers)} followers</Badge>
        {v.state !== 'requested' && <Badge variant="outline">{v.state}</Badge>}
      </div>
      <p className="mt-2 text-xs text-gray-400">Asked {when(v.createdAt)}</p>
      {v.note && <p className="mt-2 text-sm text-gray-200">{v.note}</p>}
      {v.reason && <p className="mt-2 text-xs text-gray-400">Reason given: {v.reason}</p>}
      <div className="mt-3 flex flex-wrap gap-2">
        {v.state === 'requested' && <Button size="sm" onClick={() => open({ kind: 'verification', item: v, decision: 'approve' })}>Verify</Button>}
        {v.state === 'requested' && <Button size="sm" variant="outline" onClick={() => open({ kind: 'verification', item: v, decision: 'reject' })}>Turn down</Button>}
        {v.state === 'approved' && <Button size="sm" variant="outline" onClick={() => open({ kind: 'verification', item: v, decision: 'revoke' })}>Take back</Button>}
      </div>
    </div>
  );

  const reviewCard = (r: RankReview) => (
    <div key={r.id} className="rounded-lg border border-gray-800 p-4" data-testid="review">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{who(r.profile)}</Badge>
        <Badge variant="secondary">Asks for {r.levelName}</Badge>
        <Badge variant="outline">{followersText(r.followers)} when asked, {followersText(r.followersNow)} now</Badge>
        {!r.verified && <Badge variant="destructive">Not verified now</Badge>}
      </div>
      <p className="mt-2 text-xs text-gray-400">Asked {when(r.createdAt)}. Look at who follows them before you decide: only genuine followers count.</p>
      <div className="mt-3 flex flex-wrap gap-2">
        <Button size="sm" onClick={() => open({ kind: 'review', item: r, approve: true })} disabled={!r.verified}>Award {r.levelName}</Button>
        <Button size="sm" variant="outline" onClick={() => open({ kind: 'review', item: r, approve: false })}>Turn down</Button>
      </div>
    </div>
  );

  const plaqueCard = (p: Plaque) => (
    <div key={p.id} className="rounded-lg border border-gray-800 p-4" data-testid="plaque">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{who(p.profile)}</Badge>
        <Badge variant="secondary">{p.levelName} plaque</Badge>
        <Badge variant="outline">{p.state}</Badge>
      </div>
      {p.addressRemoved ? <p className="mt-2 text-xs text-gray-500">The address has been removed.</p> : (
        <p className="mt-2 whitespace-pre-line text-sm text-gray-200">{p.address.join('\n')}{p.phone ? `\n${p.phone}` : ''}</p>
      )}
      {p.carrier && <p className="mt-2 text-xs text-gray-400">{p.carrier}: {p.tracking}</p>}
      <div className="mt-3 flex flex-wrap gap-2">
        {p.state === 'requested' && <Button size="sm" onClick={() => { setShipping(p); setCarrier(''); setTracking(''); }}>I have posted it</Button>}
        {p.state === 'shipped' && <Button size="sm" onClick={() => void run(() => markDelivered(p.id), 'Marked as delivered')} disabled={busy}>It arrived</Button>}
      </div>
    </div>
  );

  return (
    <div className="max-w-3xl">
      <h1 className="mb-2 text-2xl font-bold text-white">Verification, ranks and plaques{verifications && reviews && plaques ? ` (${verifications.length + reviews.length + plaques.length} waiting)` : ''}</h1>
      <p className="mb-6 text-sm text-gray-400">
        A tick is never for sale. Verify a person or professional when you are sure who they are; award a rank when you have looked at their followers and they are genuine. The person reads the reason when you turn them down.
      </p>
      {error && <div className="mb-4 rounded border border-red-900 p-3 text-sm text-red-300">{error} <Button size="sm" variant="outline" onClick={() => void load()}>Try again</Button></div>}

      <Tabs defaultValue="verification">
        <TabsList>
          <TabsTrigger value="verification">Verification{verifications && verifications.length > 0 ? ` (${verifications.length})` : ''}</TabsTrigger>
          <TabsTrigger value="ranks">Ranks{reviews && reviews.length > 0 ? ` (${reviews.length})` : ''}</TabsTrigger>
          <TabsTrigger value="awards">Awards</TabsTrigger>
          <TabsTrigger value="plaques">Plaques{plaques && plaques.length > 0 ? ` (${plaques.length})` : ''}</TabsTrigger>
          <TabsTrigger value="levels">The ranks</TabsTrigger>
        </TabsList>

        <TabsContent value="verification" className="space-y-3">
          {verifications === null ? <div className="text-gray-400">Loading...</div> : verifications.length === 0 ? <div className="text-gray-500">Nobody is waiting to be verified.</div> : verifications.map(verificationCard)}
          {approved && approved.length > 0 && <h2 className="pt-4 text-sm font-semibold text-gray-300">Verified through a request</h2>}
          {approved?.map(verificationCard)}
          <p className="pt-2 text-xs text-gray-500">A venue or event group is verified through its business account in BottlesUp Business, not here.</p>
        </TabsContent>

        <TabsContent value="ranks" className="space-y-3">
          {reviews === null ? <div className="text-gray-400">Loading...</div> : reviews.length === 0 ? <div className="text-gray-500">No rank is waiting to be looked at.</div> : reviews.map(reviewCard)}
        </TabsContent>

        <TabsContent value="awards" className="space-y-3">
          {awards === null ? <div className="text-gray-400">Loading...</div> : awards.length === 0 ? <div className="text-gray-500">No rank has been awarded yet.</div> : awards.map((a) => (
            <div key={a.id} className="rounded-lg border border-gray-800 p-4" data-testid="award">
              <div className="flex flex-wrap items-center gap-2">
                <Badge>{who(a.profile)}</Badge>
                <Badge variant="secondary">{a.levelName}</Badge>
                <Badge variant="outline">{followersText(a.followersNow)} followers now</Badge>
              </div>
              <p className="mt-2 text-xs text-gray-400">Awarded {when(a.awardedAt)}</p>
              <div className="mt-3"><Button size="sm" variant="outline" onClick={() => open({ kind: 'award', item: a })}>Take back</Button></div>
            </div>
          ))}
        </TabsContent>

        <TabsContent value="plaques" className="space-y-3">
          <p className="text-sm text-gray-400">The address is here only so that you can post the plaque. It is wiped 90 days after the plaque arrives, and at once if the person cancels.</p>
          {plaques === null ? <div className="text-gray-400">Loading...</div> : plaques.length === 0 ? <div className="text-gray-500">No plaque is waiting to be posted.</div> : plaques.map(plaqueCard)}
          {shipped && shipped.length > 0 && <h2 className="pt-4 text-sm font-semibold text-gray-300">On their way</h2>}
          {shipped?.map(plaqueCard)}
        </TabsContent>

        <TabsContent value="levels" className="space-y-4">
          <p className="text-sm text-gray-400">The names, colours and followers needed are yours to change: the client's plan says they still need approval. A rank needs more followers than the one below it and fewer than the one above.</p>
          {levels === null ? <div className="text-gray-400">Loading...</div> : levels.map((l) => {
            const f = forms[l.key];
            if (!f) return null;
            const verified = l.key === 'verified';
            return (
              <div key={l.key} className="space-y-2 rounded-lg border border-gray-800 p-4" data-testid="level">
                <div className="flex flex-wrap items-end gap-3">
                  <label className="text-sm text-gray-300">Name
                    <Input className="mt-1 w-48" value={f.name} onChange={(e) => setLevel(l.key, { name: e.target.value })} aria-label={`Name of ${l.key}`} />
                  </label>
                  <label className="text-sm text-gray-300">Followers needed
                    <Input className="mt-1 w-40" value={f.minFollowers} onChange={(e) => setLevel(l.key, { minFollowers: e.target.value })} disabled={verified} inputMode="numeric" aria-label={`Followers needed for ${l.key}`} />
                  </label>
                  <label className="text-sm text-gray-300">Colour
                    <Input className="mt-1 w-28" value={f.colour} onChange={(e) => setLevel(l.key, { colour: e.target.value })} aria-label={`Colour of ${l.key}`} />
                  </label>
                  <span className="mb-2 inline-block size-5 rounded-full border border-gray-700" style={{ backgroundColor: /^#[0-9A-Fa-f]{6}$/.test(f.colour) ? f.colour : 'transparent' }} aria-hidden />
                </div>
                {!verified && (
                  <div className="flex flex-wrap gap-4 text-sm text-gray-300">
                    <label className="flex items-center gap-2"><input type="checkbox" checked={f.plaque} onChange={(e) => setLevel(l.key, { plaque: e.target.checked })} aria-label={`Plaque for ${l.key}`} /> Comes with a plaque</label>
                    <label className="flex items-center gap-2"><input type="checkbox" checked={f.active} onChange={(e) => setLevel(l.key, { active: e.target.checked })} aria-label={`In use: ${l.key}`} /> In use</label>
                  </div>
                )}
                <Button size="sm" onClick={() => void saveOne(l.key)} disabled={busy}>Save {l.key.replace('_', ' ')}</Button>
              </div>
            );
          })}
        </TabsContent>
      </Tabs>

      <Dialog open={deciding !== null} onOpenChange={(o) => { if (!o) setDeciding(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {deciding?.kind === 'verification' ? { approve: 'Verify this profile', reject: 'Turn down this request', revoke: 'Take the tick back' }[deciding.decision] : deciding?.kind === 'review' ? (deciding.approve ? 'Award this rank' : 'Turn down this rank') : 'Take this rank back'}
            </DialogTitle>
            <DialogDescription>
              {deciding ? who(deciding.item.profile) : ''}
              {deciding?.kind === 'verification' && deciding.decision === 'approve' ? '. They get the tick at once. You can write a note for your own records.' : '. The person reads the reason, so write it kindly.'}
            </DialogDescription>
          </DialogHeader>
          <Input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} placeholder="Reason" aria-label="Reason" />
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeciding(null)} disabled={busy}>Cancel</Button>
            <Button onClick={() => void decide()} disabled={busy}>{busy ? 'Working...' : 'Confirm'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={shipping !== null} onOpenChange={(o) => { if (!o) setShipping(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Posted</DialogTitle>
            <DialogDescription>{shipping ? `${shipping.levelName} plaque for ${who(shipping.profile)}. The person sees the tracking number.` : ''}</DialogDescription>
          </DialogHeader>
          <Input value={carrier} onChange={(e) => setCarrier(e.target.value)} maxLength={60} placeholder="Carrier" aria-label="Carrier" />
          <Input value={tracking} onChange={(e) => setTracking(e.target.value)} maxLength={80} placeholder="Tracking number" aria-label="Tracking number" />
          <DialogFooter>
            <Button variant="outline" onClick={() => setShipping(null)} disabled={busy}>Cancel</Button>
            <Button onClick={() => void ship()} disabled={busy}>{busy ? 'Working...' : 'Mark as shipped'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Recognition;
