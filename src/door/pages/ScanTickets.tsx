import { useEffect, useRef, useState } from 'react';
import { Html5Qrcode } from 'html5-qrcode';
import { CheckCircle2, XCircle, AlertTriangle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { supabase } from '@/lib/supabase';
import { doorSignOut } from '../useDoorAuth';
import type { ScanResult } from '@/types/database';

const READER_ID = 'door-qr-reader';
// Ignore an identical decoded code for this long after it was last processed, so a
// ticket still sitting in front of the camera after "Scan Next" doesn't instantly
// re-trigger and report "Already checked in" before staff can move to the next guest.
const SAME_CODE_COOLDOWN_MS = 5000;

type ClientResult = ScanResult | 'session_expired' | 'scan_error';

type CheckinResult = {
  result: ClientResult;
  customer_name: string | null;
  event_title: string | null;
  tier_name: string | null;
  quantity: number | null;
  ticket_code?: string;
  attempts_remaining?: number | null;
};

const resultCopy: Record<ClientResult, { label: string; tone: 'ok' | 'warn' | 'error' }> = {
  ok: { label: 'Admit', tone: 'ok' },
  already_checked_in: { label: 'Already checked in', tone: 'warn' },
  not_paid: { label: 'Not paid', tone: 'error' },
  not_found: { label: 'Ticket not found', tone: 'error' },
  expired: { label: 'Event has ended', tone: 'error' },
  code_required: { label: 'Entry code required', tone: 'warn' },
  code_incorrect: { label: 'Code is incorrect', tone: 'error' },
  code_expired: { label: 'Code expired', tone: 'error' },
  no_code_requested: { label: 'No code requested yet', tone: 'error' },
  session_expired: { label: 'Session expired', tone: 'error' },
  scan_error: { label: 'Scan failed - try again', tone: 'error' },
};

const ScanTickets = () => {
  const scannerRef = useRef<Html5Qrcode | null>(null);
  const busyRef = useRef(false);
  const pausedRef = useRef(false);
  const lastCodeRef = useRef<{ code: string; at: number } | null>(null);
  const [cameraError, setCameraError] = useState<string | null>(null);
  const [manualCode, setManualCode] = useState('');
  const [otpCode, setOtpCode] = useState('');
  const [checking, setChecking] = useState(false);
  const [result, setResult] = useState<CheckinResult | null>(null);

  const authErrorResult = (): CheckinResult => ({
    result: 'session_expired',
    customer_name: null,
    event_title: null,
    tier_name: null,
    quantity: null,
  });

  const runCheckin = async (code: string) => {
    if (!code.trim() || busyRef.current) return;
    busyRef.current = true;
    pausedRef.current = true;
    setChecking(true);
    const ticketCode = code.trim();
    const { data, error } = await supabase.rpc('checkin_ticket', { p_ticket_code: ticketCode });
    setChecking(false);
    busyRef.current = false;

    if (error) {
      // checkin_ticket() raises 'not authorized' when the caller's session/door-staff
      // membership no longer checks out - most commonly an expired session. Surface
      // that distinctly instead of implying the ticket itself is the problem.
      const isAuthError = /not authorized/i.test(error.message ?? '');
      setResult(
        isAuthError
          ? authErrorResult()
          : { result: 'scan_error', customer_name: null, event_title: null, tier_name: null, quantity: null },
      );
      return;
    }
    if (!data?.[0]) {
      setResult(null);
      return;
    }
    setResult({ ...(data[0] as CheckinResult), ticket_code: ticketCode });
  };

  const runVerifyOtp = async () => {
    if (!result?.ticket_code || !otpCode.trim() || busyRef.current) return;
    busyRef.current = true;
    setChecking(true);
    const { data, error } = await supabase.rpc('verify_ticket_otp', {
      p_ticket_code: result.ticket_code,
      p_code: otpCode.trim(),
    });
    setChecking(false);
    busyRef.current = false;
    setOtpCode('');

    if (error) {
      const isAuthError = /not authorized/i.test(error.message ?? '');
      setResult(isAuthError ? authErrorResult() : { ...result, result: 'scan_error' });
      return;
    }
    setResult({ ...(data?.[0] as CheckinResult), ticket_code: result.ticket_code });
  };

  useEffect(() => {
    const scanner = new Html5Qrcode(READER_ID);
    scannerRef.current = scanner;

    scanner
      .start(
        { facingMode: 'environment' },
        { fps: 10, qrbox: { width: 250, height: 250 } },
        (decodedText) => {
          if (busyRef.current || pausedRef.current) return;
          const last = lastCodeRef.current;
          if (last && last.code === decodedText && Date.now() - last.at < SAME_CODE_COOLDOWN_MS) return;
          lastCodeRef.current = { code: decodedText, at: Date.now() };
          runCheckin(decodedText);
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
    setOtpCode('');
  };

  const needsOtp =
    result &&
    (result.result === 'code_required' ||
      result.result === 'code_incorrect' ||
      result.result === 'code_expired' ||
      result.result === 'no_code_requested');

  const handleOtpSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    runVerifyOtp();
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
          {result.result === 'session_expired' ? (
            <p className="mt-4 text-sm opacity-90">Your login expired. Sign in again to keep scanning.</p>
          ) : null}
          {needsOtp ? (
            <>
              <p className="mt-4 text-sm opacity-90">
                This ticket is non-transferable. Ask the customer for the entry code from their email
                {typeof result.attempts_remaining === 'number' ? ` (${result.attempts_remaining} attempts left)` : ''}.
              </p>
              <form onSubmit={handleOtpSubmit} className="mt-4 flex gap-2">
                <Input
                  placeholder="6-digit code"
                  value={otpCode}
                  onChange={(e) => setOtpCode(e.target.value)}
                  className="text-center font-mono text-white"
                  inputMode="numeric"
                  maxLength={6}
                  autoFocus
                />
                <Button type="submit" disabled={checking || !otpCode.trim()}>
                  Verify
                </Button>
              </form>
              <Button variant="ghost" size="sm" className="mt-2 w-full text-gray-400" onClick={scanNext}>
                Cancel
              </Button>
            </>
          ) : (
            <Button
              className="mt-6 w-full bg-gradient-orange text-black font-bold hover:opacity-90"
              onClick={result.result === 'session_expired' ? () => doorSignOut() : scanNext}
            >
              {result.result === 'session_expired' ? 'Sign In Again' : 'Scan Next'}
            </Button>
          )}
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
