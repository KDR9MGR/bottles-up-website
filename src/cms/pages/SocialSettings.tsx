import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Switch } from '@/components/ui/switch';
import { Textarea } from '@/components/ui/textarea';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useToast } from '@/hooks/use-toast';
import { AccountError } from '@/lib/account';
import {
  cleanBannedTerm, fetchBannedTerms, fetchFeatures, fetchRules, publishRules, rulesProblem, setBannedTerm, setFeature,
  type CommunityRules, type FeatureSwitch,
} from '@/lib/moderation';

const errorText = (e: unknown, fallback: string) => (e instanceof AccountError ? e.message : fallback);

/**
 * The controls for the social part of the customer app: which parts are switched on, the community rules people accept before they post, and the words that are refused. A
 * switch changes what the apps SHOW; the database enforces each rule whether or not it is on. New rules make everybody accept again.
 */
const SocialSettings = () => {
  const { toast } = useToast();
  const [features, setFeatures] = useState<FeatureSwitch[] | null>(null);
  const [rules, setRules] = useState<CommunityRules | null>(null);
  const [draft, setDraft] = useState('');
  const [terms, setTerms] = useState<string[] | null>(null);
  const [term, setTerm] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [f, r, t] = await Promise.all([fetchFeatures(), fetchRules(), fetchBannedTerms()]);
      setFeatures(f);
      setRules(r);
      setDraft((d) => (d === '' ? r.body ?? '' : d));
      setTerms(t);
    } catch (e) {
      toast({ title: 'Could not load the settings', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    }
  }, [toast]);

  useEffect(() => { void load(); }, [load]);

  const flip = async (f: FeatureSwitch, enabled: boolean) => {
    setFeatures((list) => list?.map((x) => (x.key === f.key ? { ...x, enabled } : x)) ?? null);
    try {
      await setFeature(f.key, enabled);
    } catch (e) {
      setFeatures((list) => list?.map((x) => (x.key === f.key ? { ...x, enabled: !enabled } : x)) ?? null);
      toast({ title: 'Could not change it', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    }
  };

  const publish = async () => {
    setBusy(true);
    try {
      const r = await publishRules(draft);
      setRules(r);
      toast({ title: `Rules published as version ${r.version}`, description: 'Everyone accepts them again before they next post, comment or send.' });
    } catch (e) {
      toast({ title: 'Could not publish', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const changeTerm = async (t: string, banned: boolean) => {
    try {
      await setBannedTerm(t, banned);
      setTerms(await fetchBannedTerms());
      if (banned) setTerm('');
    } catch (e) {
      toast({ title: 'Could not change the list', description: errorText(e, 'Try again in a moment.'), variant: 'destructive' });
    }
  };

  const problem = rulesProblem(draft);
  const cleaned = cleanBannedTerm(term);
  const unchanged = (rules?.body ?? '').trim() === draft.trim();

  return (
    <div className="max-w-3xl space-y-10">
      <section>
        <h1 className="mb-2 text-2xl font-bold text-white">Social settings</h1>
        <p className="mb-4 text-sm text-gray-400">
          Each part of the customer app's social side is built and tested, then switched on here. A switch off hides the part; the database refuses it either way.
        </p>
        {features === null ? <div className="text-gray-400">Loading...</div> : (
          <div className="rounded-lg border border-gray-800">
            <Table>
              <TableHeader><TableRow><TableHead>Feature</TableHead><TableHead>What it is</TableHead><TableHead className="text-right">On</TableHead></TableRow></TableHeader>
              <TableBody>
                {features.map((f) => (
                  <TableRow key={f.key}>
                    <TableCell className="font-mono text-xs">{f.key}</TableCell>
                    <TableCell className="text-sm text-gray-300">{f.note}</TableCell>
                    <TableCell className="text-right"><Switch checked={f.enabled} onCheckedChange={(v) => void flip(f, v)} aria-label={`Switch ${f.key}`} /></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </section>

      <section>
        <h2 className="mb-1 text-xl font-semibold text-white">Community rules {rules && <Badge variant="secondary">version {rules.version}{rules.body ? '' : ' - draft in the app'}</Badge>}</h2>
        <p className="mb-3 text-sm text-gray-400">
          What people read and accept before they post, comment or send a message. Until you publish, the app shows its own draft. Publishing makes everyone accept again.
        </p>
        <Textarea value={draft} onChange={(e) => setDraft(e.target.value)} rows={14} placeholder="Write the rules here (20 to 8000 characters)" />
        <div className="mt-2 flex items-center gap-3">
          <Button onClick={() => void publish()} disabled={busy || problem !== null || unchanged}>{busy ? 'Publishing...' : 'Publish as a new version'}</Button>
          <span className="text-xs text-gray-400">{draft.trim().length} characters{problem && draft !== '' ? ` - ${problem}` : ''}{unchanged && rules?.body ? ' - same as the published rules' : ''}</span>
        </div>
      </section>

      <section>
        <h2 className="mb-1 text-xl font-semibold text-white">Banned words</h2>
        <p className="mb-3 text-sm text-gray-400">Posts, captions, comments and group names that contain one of these are refused. 2 to 40 letters, numbers or spaces; capital letters do not matter.</p>
        <div className="mb-3 flex gap-2">
          <Input value={term} onChange={(e) => setTerm(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && cleaned) void changeTerm(cleaned, true); }} placeholder="A word or phrase" />
          <Button onClick={() => cleaned && void changeTerm(cleaned, true)} disabled={!cleaned}>Add</Button>
        </div>
        {terms === null ? <div className="text-gray-400">Loading...</div> : terms.length === 0 ? <div className="text-gray-500">No banned words yet.</div> : (
          <div className="flex flex-wrap gap-2">
            {terms.map((t) => (
              <Badge key={t} variant="outline" className="gap-2">{t}<button type="button" aria-label={`Remove ${t}`} className="text-gray-400 hover:text-white" onClick={() => void changeTerm(t, false)}>x</button></Badge>
            ))}
          </div>
        )}
      </section>
    </div>
  );
};

export default SocialSettings;
