import { useEffect, useRef, useState } from 'react';
import { Loader2, Search } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { AccountError, doorGuests, doorScan, doorVerifyCode } from '@/lib/account';
import type { Workspace } from '@/lib/accountRouting';
import { guestStatus, needsEntryCode, RESULT_COPY, type Guest, type ScanOutcome } from '@/lib/doorScan';
import EventBar from './EventBar';
import { useDoorEvents } from './useDoorEvents';

const MIN_QUERY = 2;

type Row = Guest & { outcome?: ScanOutcome; askCode?: boolean };

/**
 * Find a guest by name or ticket code, for when a QR code will not scan, and admit them from the list. It needs at least
 * two characters, shows no contact details, and admitting goes through exactly the same checks as a scan.
 */
const DoorGuests = ({ workspace }: { workspace: Workspace }) => {
  const { loading, events, selected, error, select, refresh } = useDoorEvents(workspace.membershipId);
  const [query, setQuery] = useState('');
  const [rows, setRows] = useState<Row[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [codes, setCodes] = useState<Record<string, string>>({});
  const ticket = useRef(0);
  const eventId = selected?.eventId ?? null;

  // Search as the person types, ignoring answers that arrive late.
  useEffect(() => {
    if (!eventId) return;
    const q = query.trim();
    if (q.length < MIN_QUERY) { setRows(null); setFailed(null); return; }
    const mine = ++ticket.current;
    setSearching(true);
    const timer = window.setTimeout(async () => {
      try {
        const found = await doorGuests(eventId, q);
        if (mine === ticket.current) { setRows(found); setFailed(null); }
      } catch (err) {
        if (mine === ticket.current) setFailed(err instanceof AccountError ? err.message : 'The search failed. Try again.');
      } finally {
        if (mine === ticket.current) setSearching(false);
      }
    }, 300);
    return () => window.clearTimeout(timer);
  }, [query, eventId]);

  const apply = (orderId: string, outcome: ScanOutcome) =>
    setRows((r) => (r ?? []).map((g) => (g.orderId !== orderId ? g : {
      ...g,
      outcome,
      askCode: needsEntryCode(outcome.result),
      checkedInAt: outcome.result === 'ok' ? new Date().toISOString() : g.checkedInAt,
    })));

  const admit = async (g: Row) => {
    if (!eventId) return;
    setBusy(g.orderId);
    const outcome = await doorScan(g.ticketCode, eventId);
    setBusy(null);
    apply(g.orderId, outcome);
    if (outcome.result === 'ok') void refresh();
  };

  const verify = async (g: Row) => {
    const code = (codes[g.orderId] ?? '').trim();
    if (!eventId || !code) return;
    setBusy(g.orderId);
    const outcome = await doorVerifyCode(g.ticketCode, code, eventId);
    setBusy(null);
    setCodes((c) => ({ ...c, [g.orderId]: '' }));
    apply(g.orderId, outcome);
    if (outcome.result === 'ok') void refresh();
  };

  if (loading) return <p className="text-sm text-gray-500" role="status">Loading your events…</p>;
  if (error) return <p role="alert" className="rounded-lg border border-red-500/40 bg-red-500/10 p-4 text-sm text-red-200">{error}</p>;
  if (!selected) return <p className="text-sm text-gray-400">No events to work right now. Scanning and guest search open when an event is running or about to start.</p>;

  return (
    <div className="mx-auto max-w-xl">
      <EventBar events={events} selected={selected} onSelect={(id) => { select(id); setRows(null); }} />

      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-500" aria-hidden="true" />
        <Input
          aria-label="Search guests by name or ticket code"
          placeholder="Search by name or ticket code"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          className="pl-9"
          autoComplete="off"
        />
        {searching && <Loader2 className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-gray-500" aria-hidden="true" />}
      </div>
      <p className="mt-2 text-xs text-gray-500">Type at least two letters. Only paid guests of this event are shown.</p>

      {failed && <p role="alert" className="mt-4 text-sm text-red-300">{failed}</p>}
      {rows && rows.length === 0 && !searching && <p className="mt-6 text-sm text-gray-500">No paid guest matches “{query.trim()}”.</p>}

      <ul className="mt-4 space-y-2">
        {rows?.map((g) => {
          const status = guestStatus(g);
          return (
            <li key={g.orderId} className="rounded-xl border border-gray-800 bg-gray-900/50 p-4">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <p className="truncate font-medium text-white">{g.name}</p>
                  <p className="text-xs text-gray-400">{g.tierName} × {g.quantity} · <span className="font-mono">{g.ticketCode}</span></p>
                </div>
                {status === 'in' ? (
                  <span className="shrink-0 rounded-full border border-green-500/40 bg-green-500/10 px-2.5 py-0.5 text-xs text-green-300">In</span>
                ) : (
                  <Button size="sm" disabled={busy === g.orderId} onClick={() => void admit(g)} className="shrink-0 bg-gradient-orange font-bold text-black hover:opacity-90">
                    {busy === g.orderId ? <Loader2 className="h-4 w-4 animate-spin" /> : status === 'needs_code' ? 'Check in…' : 'Admit'}
                  </Button>
                )}
              </div>

              {g.outcome && g.outcome.result !== 'ok' && (
                <p role="status" className={`mt-3 text-sm ${RESULT_COPY[g.outcome.result].tone === 'warn' ? 'text-amber-300' : 'text-red-300'}`}>
                  <strong>{RESULT_COPY[g.outcome.result].label}.</strong> {RESULT_COPY[g.outcome.result].hint}
                  {typeof g.outcome.attemptsRemaining === 'number' && g.outcome.result === 'code_incorrect' && ` ${g.outcome.attemptsRemaining} left.`}
                </p>
              )}
              {g.outcome?.result === 'ok' && <p role="status" className="mt-3 text-sm text-green-300">Admitted.</p>}

              {g.askCode && g.outcome && (g.outcome.result === 'code_required' || g.outcome.result === 'code_incorrect') && (
                <form onSubmit={(e) => { e.preventDefault(); void verify(g); }} className="mt-3 flex gap-2">
                  <Input
                    aria-label={`Entry code for ${g.name}`}
                    placeholder="6-digit code"
                    value={codes[g.orderId] ?? ''}
                    onChange={(e) => setCodes((c) => ({ ...c, [g.orderId]: e.target.value }))}
                    inputMode="numeric"
                    maxLength={6}
                    className="font-mono"
                  />
                  <Button type="submit" size="sm" disabled={busy === g.orderId || !(codes[g.orderId] ?? '').trim()}>Verify</Button>
                </form>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
};

export default DoorGuests;
