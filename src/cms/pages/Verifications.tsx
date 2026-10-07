import { useCallback, useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { useToast } from '@/hooks/use-toast';
import {
  AccountError, fetchClaimQueue, fetchVerificationQueue, reviewVenueClaim, reviewVerification,
  type QueuedBusiness, type QueuedClaim,
} from '@/lib/account';
import { logAudit } from '@/lib/auditLog';

type Pending =
  | { kind: 'verify'; business: QueuedBusiness }
  | { kind: 'request_info'; business: QueuedBusiness }
  | { kind: 'approve'; claim: QueuedClaim }
  | { kind: 'reject'; claim: QueuedClaim };

const Detail = ({ label, value }: { label: string; value: string | number | null }) => (
  <div>
    <dt className="text-xs text-muted-foreground">{label}</dt>
    <dd className="text-sm">{value === null || value === '' ? <span className="text-muted-foreground">Not provided</span> : value}</dd>
  </div>
);

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : 'Unknown');

/**
 * Where BottlesUp staff decide on business verification and venue ownership requests. Nothing is approved
 * automatically: a business is only verified here, and an existing owner is only replaced by an explicit
 * approval that shows who currently owns the venue.
 */
const Verifications = () => {
  const { toast } = useToast();
  const [businesses, setBusinesses] = useState<QueuedBusiness[] | null>(null);
  const [claims, setClaims] = useState<QueuedClaim[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [b, c] = await Promise.all([fetchVerificationQueue(), fetchClaimQueue()]);
      setBusinesses(b);
      setClaims(c);
      setError(null);
    } catch (err) {
      setError(err instanceof AccountError ? err.message : 'Could not load the review queues.');
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const close = () => { setPending(null); setNote(''); };

  const needsNote = pending?.kind === 'request_info' || pending?.kind === 'reject';
  const noteTooShort = needsNote && note.trim().length < 3;

  const confirm = async () => {
    if (!pending) return;
    setBusy(true);
    try {
      if (pending.kind === 'verify' || pending.kind === 'request_info') {
        await reviewVerification(pending.business.orgId, pending.kind, note.trim());
        await logAudit({ action: `business.${pending.kind}`, entityType: 'site_organization', entityId: pending.business.orgId, details: { name: pending.business.orgName, note: note.trim() || null } });
        toast({ title: pending.kind === 'verify' ? 'Business verified' : 'Information requested' });
      } else {
        const approve = pending.kind === 'approve';
        await reviewVenueClaim(pending.claim.claimId, approve, note.trim());
        await logAudit({ action: `venue_claim.${approve ? 'approve' : 'reject'}`, entityType: 'site_venue', entityId: pending.claim.venueId, details: { business: pending.claim.orgName, note: note.trim() || null } });
        toast({ title: approve ? 'Venue assigned' : 'Request rejected' });
      }
      close();
      await load();
    } catch (err) {
      toast({ title: 'Could not complete that', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const dialog = (() => {
    if (!pending) return null;
    switch (pending.kind) {
      case 'verify':
        return { title: `Verify ${pending.business.orgName}?`, body: 'The business will be told it is verified. This is recorded against your name.', action: 'Verify', noteLabel: 'Note (optional)' };
      case 'request_info':
        return { title: 'Ask for more information', body: `Tell ${pending.business.orgName} exactly what you need. They will see this message and can resubmit.`, action: 'Send request', noteLabel: 'What do you need?' };
      case 'approve':
        return {
          title: `Assign ${pending.claim.venueName} to ${pending.claim.orgName}?`,
          body: pending.claim.currentOwnerName
            ? `This venue currently belongs to ${pending.claim.currentOwnerName}. Approving moves it to ${pending.claim.orgName}. Other pending requests for it will be closed.`
            : 'Other pending requests for this venue will be closed.',
          action: 'Assign venue',
          noteLabel: 'Note (optional)',
        };
      case 'reject':
        return { title: 'Reject this request', body: 'The business will see your reason.', action: 'Reject', noteLabel: 'Reason' };
    }
  })();

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-bold">Business verification</h1>
        <p className="text-sm text-muted-foreground">Review businesses that asked to be verified, and requests to take over an existing venue.</p>
      </div>

      {error && <p role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">{error}</p>}

      <section aria-labelledby="queue-businesses" className="space-y-4">
        <h2 id="queue-businesses" className="text-lg font-semibold">Businesses under review {businesses && <Badge variant="secondary">{businesses.length}</Badge>}</h2>
        {businesses === null && !error && <p className="text-sm text-muted-foreground">Loading…</p>}
        {businesses?.length === 0 && <p className="text-sm text-muted-foreground">Nothing is waiting for review.</p>}
        {businesses?.map((b) => (
          <article key={b.orgId} className="rounded-lg border p-4">
            <header className="flex flex-wrap items-center justify-between gap-2">
              <div>
                <h3 className="font-semibold">{b.orgName}</h3>
                <p className="text-xs text-muted-foreground">
                  {b.orgKind === 'organizer' ? 'Event organizer' : 'Venue owner'} · submitted {when(b.submittedAt)}
                  {b.submissionCount > 1 && ` · submission ${b.submissionCount}`}
                </p>
              </div>
              <div className="flex gap-2">
                <Button size="sm" variant="outline" onClick={() => setPending({ kind: 'request_info', business: b })}>Request information</Button>
                <Button size="sm" onClick={() => setPending({ kind: 'verify', business: b })}>Verify</Button>
              </div>
            </header>
            <dl className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <Detail label="Legal name" value={b.legalName} />
              <Detail label="Representative" value={b.representativeName} />
              <Detail label="Representative phone" value={b.representativePhone} />
              <Detail label="Contact email" value={b.contactEmail} />
              <Detail label="Account email" value={b.ownerEmail} />
              <Detail label="Address" value={[b.address, b.city].filter(Boolean).join(', ') || null} />
              <Detail label="Website" value={b.website} />
              {b.orgKind === 'venue_owner' && <Detail label="Venues added" value={b.venueCount} />}
            </dl>
            {b.description && <p className="mt-3 text-sm text-muted-foreground">{b.description}</p>}
          </article>
        ))}
      </section>

      <section aria-labelledby="queue-claims" className="space-y-4">
        <h2 id="queue-claims" className="text-lg font-semibold">Venue ownership requests {claims && <Badge variant="secondary">{claims.length}</Badge>}</h2>
        {claims?.length === 0 && <p className="text-sm text-muted-foreground">No pending requests.</p>}
        {claims?.map((c) => (
          <article key={c.claimId} className="rounded-lg border p-4">
            <header className="flex flex-wrap items-center justify-between gap-2">
              <div>
                <h3 className="font-semibold">{c.venueName}</h3>
                <p className="text-xs text-muted-foreground">{c.venueAddress ?? 'No address'} · requested {when(c.createdAt)}</p>
              </div>
              <div className="flex gap-2">
                <Button size="sm" variant="outline" onClick={() => setPending({ kind: 'reject', claim: c })}>Reject</Button>
                <Button size="sm" onClick={() => setPending({ kind: 'approve', claim: c })}>Approve</Button>
              </div>
            </header>
            <p className="mt-3 text-sm"><span className="text-muted-foreground">Requested by</span> {c.orgName}</p>
            {c.currentOwnerName && (
              <p className="mt-1 rounded-md border border-amber-500/40 bg-amber-500/10 p-2 text-sm">
                Currently managed by <strong>{c.currentOwnerName}</strong>. Approving replaces them.
              </p>
            )}
            {c.message && <p className="mt-2 text-sm text-muted-foreground">“{c.message}”</p>}
          </article>
        ))}
      </section>

      <Dialog open={pending !== null} onOpenChange={(o) => { if (!o) close(); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{dialog?.title}</DialogTitle>
            <DialogDescription>{dialog?.body}</DialogDescription>
          </DialogHeader>
          <div className="space-y-2">
            <Label htmlFor="review-note">{dialog?.noteLabel}</Label>
            <Textarea id="review-note" value={note} onChange={(e) => setNote(e.target.value)} rows={3} maxLength={500} />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={close} disabled={busy}>Cancel</Button>
            <Button onClick={() => void confirm()} disabled={busy || noteTooShort}>{dialog?.action}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Verifications;
