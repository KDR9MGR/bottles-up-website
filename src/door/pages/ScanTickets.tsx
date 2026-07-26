import { useEffect, useRef, useState } from 'react';
import { Html5Qrcode } from 'html5-qrcode';
import { CheckCircle2, XCircle, AlertTriangle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { supabase } from '@/lib/supabase';
import { doorSignOut } from '../useDoorAuth';

const READER_ID = 'door-qr-reader';

type CheckinResult = {
  result: 'ok' | 'already_checked_in' | 'not_paid' | 'not_found';
  customer_name: string | null;
  event_title: string | null;
  tier_name: string | null;
  quantity: number | null;
};

const resultCopy: Record<CheckinResult['result'], { label: string; tone: 'ok' | 'warn' | 'error' }> = {
  ok: { label: 'Admit', tone: 'ok' },
  already_checked_in: { label: 'Already checked in', tone: 'warn' },
  not_paid: { label: 'Not paid', tone: 'error' },
  not_found: { label: 'Ticket not found', tone: 'error' },
};

const ScanTickets = () => {
  const scannerRef = useRef<Html5Qrcode | null>(null);
  const busyRef = useRef(false);
  const pausedRef = useRef(false);
  const [cameraError, setCameraError] = useState<string | null>(null);
  const [manualCode, setManualCode] = useState('');
  const [checking, setChecking] = useState(false);
  const [result, setResult] = useState<CheckinResult | null>(null);

  const runCheckin = async (code: string) => {
    if (!code.trim() || busyRef.current) return;
    busyRef.current = true;
    pausedRef.current = true;
    setChecking(true);
    const { data, error } = await supabase.rpc('checkin_ticket', { p_ticket_code: code.trim() });
    setChecking(false);
    busyRef.current = false;

    if (error) {
      setResult({ result: 'not_found', customer_name: null, event_title: null, tier_name: null, quantity: null });
      return;
    }
    setResult((data?.[0] as CheckinResult) ?? null);
  };

  useEffect(() => {
    const scanner = new Html5Qrcode(READER_ID);
    scannerRef.current = scanner;

    scanner
      .start(
        { facingMode: 'environment' },
        { fps: 10, qrbox: { width: 250, height: 250 } },
        (decodedText) => {
          if (!busyRef.current && !pausedRef.current) {
            runCheckin(decodedText);
          }
        },
        () => {
          // per-frame decode miss - expected while the camera searches, not an error
        },
      )
      .catch((err) => {
        setCameraError(err instanceof Error ? err.message : 'Could not access the camera. Use manual entry below.');
      });

    return () => {
      scanner.stop().then(() => scanner.clear()).catch(() => {});
    };
  }, []);

  const handleManualSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    runCheckin(manualCode);
    setManualCode('');
  };

  const scanNext = () => {
    pausedRef.current = false;
    setResult(null);
  };

  const tone = result ? resultCopy[result.result].tone : null;
  const toneClasses =
    tone === 'ok'
      ? 'bg-green-950 border-green-500 text-green-400'
      : tone === 'warn'
        ? 'bg-amber-950 border-amber-500 text-amber-400'
        : 'bg-red-950 border-red-500 text-red-400';

  return (
    <div className="flex min-h-screen flex-col items-center bg-black px-4 py-8">
      <div className="mb-4 flex w-full max-w-sm items-center justify-between">
        <h1 className="text-xl font-bold text-white">Scan Tickets</h1>
        <Button variant="ghost" size="sm" className="text-gray-400" onClick={() => doorSignOut()}>
          Sign out
        </Button>
      </div>

      {result ? (
        <div className={`w-full max-w-sm rounded-2xl border-2 p-6 text-center ${toneClasses}`}>
          {tone === 'ok' ? (
            <CheckCircle2 className="mx-auto mb-3 h-12 w-12" />
          ) : tone === 'warn' ? (
            <AlertTriangle className="mx-auto mb-3 h-12 w-12" />
          ) : (
            <XCircle className="mx-auto mb-3 h-12 w-12" />
          )}
          <div className="mb-1 text-2xl font-bold">{resultCopy[result.result].label}</div>
          {result.customer_name && (
            <div className="text-sm opacity-90">
              {result.customer_name} · {result.tier_name} × {result.quantity}
              <br />
              {result.event_title}
            </div>
          )}
          <Button
            className="mt-6 w-full bg-gradient-orange text-black font-bold hover:opacity-90"
            onClick={scanNext}
          >
            Scan Next
          </Button>
        </div>
      ) : (
        <div className="w-full max-w-sm">
          <div id={READER_ID} className="overflow-hidden rounded-2xl border border-gray-800" />
          {cameraError && (
            <p className="mt-3 text-center text-sm text-amber-400">{cameraError}</p>
          )}
          {checking && <p className="mt-3 text-center text-sm text-gray-400">Checking...</p>}

          <form onSubmit={handleManualSubmit} className="mt-6 flex gap-2">
            <Input
              placeholder="Or enter ticket code manually"
              value={manualCode}
              onChange={(e) => setManualCode(e.target.value)}
              className="font-mono"
            />
            <Button type="submit" disabled={checking || !manualCode.trim()}>
              Check
            </Button>
          </form>
        </div>
      )}
    </div>
  );
};

export default ScanTickets;
