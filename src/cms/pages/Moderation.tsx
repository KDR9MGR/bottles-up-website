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
  ACTION_LABELS, KIND_LABELS, STATE_LABELS, actionHelp, actionsFor, fetchReports, findProfiles, profileName, reasonText, resolveReport, setProfileSuspended,
  type FoundProfile, type ReportAction, type ReportGroup,
} from '@/lib/moderation';

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : '');
const errorText = (e: unknown, fallback: string) => (e instanceof AccountError ? e.message : fallback);

type Deciding = { group: ReportGroup; action: ReportAction } | { person: FoundProfile; suspend: boolean };

/**
 * Where BottlesUp staff look after what people report in the customer app. Reports are grouped by the thing reported, oldest first. Nothing is removed or suspended on its own: a
 * number of reports is a reason to look, and every decision here is written to the audit log with the note. Reporters are counted, never named.
 */
const Moderation = () => {
  const { toast } = useToast();
  const [tab, setTab] = useState<'open' | 'handled'>('open');
  const [open, setOpen] = useState<ReportGroup[] | null>(null);
  const [handled, setHandled] = useState<ReportGroup[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [deciding, setDeciding] = useState<Deciding | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [query, setQuery] = useState('');
  const [found, setFound] = useState<FoundProfile[] | null>(null);

  const load = useCallback(async () => {
    try {
      const [o, h] = await Promise.all([fetchReports('open', 100), fetchReports('all', 100)]);
      setOpen(o);
      setHandled(h.filter((g) => g.status !== 'open'));
      setError(null);
    } catch (e) {
      setError(errorText(e, 'Could not load the reports.'));
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const close = () => { setDeciding(null); setNote(''); };

  const confirm = async () => {
    if (!deciding) return;
    setBusy(true);
    try {
      if ('group' in deciding) {
        await resolveReport(deciding.group.kind, deciding.group.target, deciding.action, note);
        toast({ title: `${ACTION_LABELS[deciding.action]}: done` });
      } else {
        await setProfileSuspended(deciding.person.id, deciding.suspend, note);
        toast({ title: deciding.suspend ? 'Suspended' : 'Restored' });
        setFound(await findProfiles(query));
      }
      close();
      await load();
    } catch (e) {
      toast({ title: 'Could not do that', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const search = async () => {
    try {
      setFound(await findProfiles(query));
    } catch (e) {
      setFound(null);
      toast({ title: 'Search failed', description: errorText(e, 'Type at least 2 letters.'), variant: 'destructive' });
    }
  };

  const card = (g: ReportGroup) => (
    <div key={`${g.kind}:${g.target}:${g.handledAt ?? 'open'}`} className="rounded-lg border border-gray-800 p-4" data-testid="report-group">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{KIND_LABELS[g.kind]}</Badge>
        <Badge variant="secondary">{g.reports} report{g.reports === 1 ? '' : 's'} from {g.reporters} {g.reporters === 1 ? 'person' : 'people'}</Badge>
        {g.state !== 'active' && <Badge variant="destructive">{STATE_LABELS[g.state]}</Badge>}
        {g.status !== 'open' && <Badge variant="outline">{g.action ?? g.status}{g.handledAt ? `, ${when(g.handledAt)}` : ''}</Badge>}
      </div>
      <p className="mt-2 text-sm text-gray-300">{reasonText(g.reasons)}</p>
      {g.excerpt && <blockquote className="mt-2 whitespace-pre-wrap border-l-2 border-gray-700 pl-3 text-sm text-white">{g.excerpt}</blockquote>}
      <p className="mt-2 text-xs text-gray-400">By {profileName(g.profile)}{g.profile?.status === 'suspended' ? ' (suspended)' : ''} - first reported {when(g.firstAt)}</p>
      {g.details.length > 0 && (
        <ul className="mt-2 list-disc pl-5 text-xs text-gray-400">
          {g.details.map((d, i) => <li key={i}>{d}</li>)}
        </ul>
      )}
      {g.note && <p className="mt-2 text-xs text-gray-500">Note: {g.note}</p>}
      <div className="mt-3 flex flex-wrap gap-2">
        {actionsFor(g).map((a) => (
          <Button key={a} size="sm" variant={a === 'suspend' || a === 'remove' ? 'destructive' : 'outline'} onClick={() => { setNote(''); setDeciding({ group: g, action: a }); }}>
            {ACTION_LABELS[a]}
          </Button>
        ))}
      </div>
    </div>
  );

  return (
    <div className="max-w-3xl">
      <h1 className="mb-2 text-2xl font-bold text-white">Moderation{open ? ` (${open.length} open)` : ''}</h1>
      <p className="mb-6 text-sm text-gray-400">
        What people report in the customer app, oldest first. App stores expect reports to be looked at promptly: check this page every day. Reporters are counted, never named.
      </p>
      {error && <div className="mb-4 rounded border border-red-900 p-3 text-sm text-red-300">{error} <Button size="sm" variant="outline" onClick={() => void load()}>Try again</Button></div>}

      <Tabs value={tab} onValueChange={(v) => setTab(v as 'open' | 'handled')}>
        <TabsList>
          <TabsTrigger value="open">Open</TabsTrigger>
          <TabsTrigger value="handled">Decided</TabsTrigger>
          <TabsTrigger value="find">Find a profile</TabsTrigger>
        </TabsList>
        <TabsContent value="open" className="space-y-3">
          {open === null ? <div className="text-gray-400">Loading...</div> : open.length === 0 ? <div className="text-gray-500">Nothing waiting. </div> : open.map(card)}
        </TabsContent>
        <TabsContent value="handled" className="space-y-3">
          {handled === null ? <div className="text-gray-400">Loading...</div> : handled.length === 0 ? <div className="text-gray-500">Nothing decided yet.</div> : handled.map(card)}
        </TabsContent>
        <TabsContent value="find" className="space-y-3">
          <p className="text-sm text-gray-400">Look up a person or business by username or name to suspend or restore them without a report (an appeal, or something nobody reported).</p>
          <div className="flex gap-2">
            <Input value={query} onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') void search(); }} placeholder="Username or name" />
            <Button onClick={() => void search()}>Search</Button>
          </div>
          {found && found.length === 0 && <div className="text-gray-500">Nobody found.</div>}
          {found?.map((p) => (
            <div key={p.id} className="flex items-center justify-between rounded border border-gray-800 p-3">
              <div>
                <div className="text-white">{p.displayName ?? p.handle} <span className="text-gray-400">@{p.handle}</span></div>
                <div className="text-xs text-gray-400">{p.kind === 'personal' ? 'Personal profile' : p.category ?? 'Business profile'} - {p.status}</div>
              </div>
              <Button size="sm" variant={p.status === 'active' ? 'destructive' : 'outline'} onClick={() => { setNote(''); setDeciding({ person: p, suspend: p.status === 'active' }); }}>
                {p.status === 'active' ? 'Suspend' : 'Restore'}
              </Button>
            </div>
          ))}
        </TabsContent>
      </Tabs>

      <Dialog open={deciding !== null} onOpenChange={(o) => { if (!o) close(); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {deciding && ('group' in deciding ? ACTION_LABELS[deciding.action] : deciding.suspend ? `Suspend ${deciding.person.displayName ?? deciding.person.handle}` : `Restore ${deciding.person.displayName ?? deciding.person.handle}`)}
            </DialogTitle>
            <DialogDescription>
              {deciding && ('group' in deciding
                ? actionHelp(deciding.action, deciding.group)
                : deciding.suspend ? actionHelp('suspend', {} as ReportGroup) : actionHelp('restore', {} as ReportGroup))}
            </DialogDescription>
          </DialogHeader>
          <Textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} placeholder="A note for the audit log (optional)" />
          <DialogFooter>
            <Button variant="outline" onClick={close} disabled={busy}>Cancel</Button>
            <Button onClick={() => void confirm()} disabled={busy}>{busy ? 'Working...' : 'Confirm'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Moderation;
