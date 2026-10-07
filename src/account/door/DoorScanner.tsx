import { useCallback, useEffect, useRef, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { doorScan, doorVerifyCode } from '@/lib/account';
import type { Workspace } from '@/lib/accountRouting';
import { normalizeScan, RESULT_COPY, shouldProcessScan, type DoorResult, type ScanOutcome } from '@/lib/doorScan';
import EventBar from './EventBar';
import ScanResultCard from './ScanResultCard';
import { useDoorEvents } from './useDoorEvents';

const READER_ID = 'door-qr-reader';
const RECENT_LIMIT = 8;

interface Recent {
  at: number;
  result: DoorResult;
  name: string | null;
}

// A short buzz so the person at the door can feel the answer without looking: one for "admit", longer for anything else.
function buzz(result: DoorResult) {
  try {
    navigator.vibrate?.(result === 'ok' ? 60 : [200, 80, 200]);
  } catch {
    /* not supported */
  }
}

/**
 * The scanner for invited door staff. The camera reads QR codes; manual entry is always there under it, because a
 * camera can be denied, dirty or missing. Every scan is checked by the database against the selected event and this
 * person's own assignment, so a ticket for another event or club is refused whatever the screen does.
 */
const DoorScanner = ({ workspace }: { workspace: Workspace }) => {
  const { loading, events, selected, error, select, refresh } = useDoorEvents(workspace.membershipId);
  const [outcome, setOutcome] = useState<(ScanOutcome & { ticketCode: string }) | null>(null);
  const [checking, setChecking] = useState(false);
  const [manual, setManual] = useState('');
  const [cameraError, setCameraError] = useState<string | null>(null);
  const [recent, setRecent] = useState<Recent[]>([]);

  const eventId = selected?.eventId ?? null;
  const eventRef = useRef<string | null>(null);
  const busyRef = useRef(false);
  const pausedRef = useRef(false);
  const lastRef = useRef<{ code: string; at: number } | null>(null);
  eventRef.current = eventId;

  const record = useCallback((o: ScanOutcome) => {
    buzz(o.result);
    setRecent((r) => [{ at: Date.now(), result: o.result, name: o.customerName }, ...r].slice(0, RECENT_LIMIT));
    if (o.result === 'ok') void refresh();
  }, [refresh]);

  const runScan = useCallback(async (raw: string) => {
    const code = normalizeScan(raw);
    const event = eventRef.current;
    if (!event || !code) return;
    busyRef.current = true;
    pausedRef.current = true;
    setChecking(true);
    const o = await doorScan(code, event);
    busyRef.current = false;
    setChecking(false);
    setOutcome({ ...o, ticketCode: code });
    record(o);
  }, [record]);

  const runVerify = async (otp: string) => {
    const event = eventRef.current;
    if (!outcome || !event || busyRef.current) return;
    busyRef.current = true;
    setChecking(true);
    const o = await doorVerifyCode(outcome.ticketCode, otp, event);
    busyRef.current = false;
    setChecking(false);
    setOutcome({ ...o, ticketCode: outcome.ticketCode });
    record(o);
  };

  // The camera. Loaded on demand (it is a large library) and always cleaned up, including when the screen closes
  // before the camera has finished starting.
  useEffect(() => {
    if (!eventId) return;
    let cancelled = false;
    let scanner: { stop: () => Promise<void>; clear: () => void } | null = null;

    (async () => {
      try {
        const { Html5Qrcode } = await import('html5-qrcode');
        if (cancelled) return;
        const instance = new Html5Qrcode(READER_ID);
        scanner = instance;
        await instance.start(
          { facingMode: 'environment' },
          { fps: 10, qrbox: { width: 250, height: 250 } },
          (decoded) => {
            const gate = { busy: busyRef.current, paused: pausedRef.current, last: lastRef.current, now: Date.now() };
            if (!shouldProcessScan(decoded, gate)) return;
            lastRef.current = { code: decoded, at: Date.now() };
            void runScan(decoded);
          },
          () => { /* a frame with no code in it: expected while the camera searches */ },
        );
        if (cancelled) await instance.stop().catch(() => {});
      } catch (err) {
        if (!cancelled) setCameraError(err instanceof Error && err.message ? err.message : 'The camera is not available.');
      }
    })();

    return () => {
      cancelled = true;
      scanner?.stop().then(() => scanner?.clear()).catch(() => {});
    };
  }, [eventId, runScan]);

  const next = () => {
    pausedRef.current = false;
    setOutcome(null);
  };

  if (loading) return <p className="text-sm text-gray-500" role="status">Loading your events…</p>;
  if (error) return <p role="alert" className="rounded-lg border border-red-500/40 bg-red-500/10 p-4 text-sm text-red-200">{error}</p>;
  if (!selected) {
    return (
      <div className="rounded-2xl border border-dashed border-gray-800 p-8 text-center">
        <p className="text-white">No events to scan right now</p>
        <p className="mx-auto mt-2 max-w-md text-sm text-gray-400">
          You can scan tickets for events that are running, starting within a day, or that ended in the last few hours,
          at the club or event you were assigned to. Ask your manager if you expected one to be here.
        </p>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-md">
      <EventBar events={events} selected={selected} onSelect={(id) => { select(id); next(); }} />

      {/* The camera element stays mounted while a result shows (collapsed, not removed): removing it would leave the
          camera attached to an element that no longer exists, so the preview would be blank after the first scan. */}
      <div id={READER_ID} className={outcome ? 'h-0 overflow-hidden' : 'overflow-hidden rounded-2xl border border-gray-800'} />

      {outcome ? (
        <ScanResultCard outcome={outcome} checking={checking} onNext={next} onVerify={(c) => void runVerify(c)} />
      ) : (
        <div>
          {cameraError && (
            <p role="status" className="mt-3 rounded-lg border border-amber-500/40 bg-amber-500/10 p-3 text-center text-sm text-amber-200">
              The camera could not start ({cameraError.replace(/[.\s]+$/, '')}). You can still type the ticket code below.
            </p>
          )}
          {checking && <p className="mt-3 flex items-center justify-center gap-2 text-sm text-gray-400" role="status"><Loader2 className="h-4 w-4 animate-spin" /> Checking…</p>}
          <form onSubmit={(e) => { e.preventDefault(); void runScan(manual); setManual(''); }} className="mt-5 flex gap-2">
            <Input aria-label="Ticket code" placeholder="Or type the ticket code" value={manual} onChange={(e) => setManual(e.target.value)} className="font-mono" autoCapitalize="characters" autoComplete="off" />
            <Button type="submit" disabled={checking || !manual.trim()}>Check</Button>
          </form>
        </div>
      )}

      {recent.length > 0 && (
        <section aria-label="Recent scans" className="mt-8">
          <h2 className="mb-2 text-xs font-medium uppercase tracking-wide text-gray-500">This session</h2>
          <ul className="space-y-1.5">
            {recent.map((r, i) => (
              <li key={`${r.at}-${i}`} className="flex items-center justify-between rounded-lg border border-gray-800 px-3 py-2 text-sm">
                <span className="truncate text-gray-300">{r.name ?? 'Unknown ticket'}</span>
                <span className={`ml-3 shrink-0 text-xs ${RESULT_COPY[r.result].tone === 'ok' ? 'text-green-300' : RESULT_COPY[r.result].tone === 'warn' ? 'text-amber-300' : 'text-red-300'}`}>
                  {RESULT_COPY[r.result].label}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
};

export default DoorScanner;
