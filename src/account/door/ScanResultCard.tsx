import { useState } from 'react';
import { Link } from 'react-router-dom';
import { AlertTriangle, CheckCircle2, Loader2, XCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { canRetryCode, needsEntryCode, RESULT_COPY, type ScanOutcome } from '@/lib/doorScan';

const TONE_CLASS = {
  ok: 'border-green-500 bg-green-950 text-green-300',
  warn: 'border-amber-500 bg-amber-950 text-amber-300',
  error: 'border-red-500 bg-red-950 text-red-300',
} as const;

interface Props {
  outcome: ScanOutcome;
  checking: boolean;
  onNext: () => void;
  /** Submits the 6-digit entry code. */
  onVerify: (code: string) => void;
}

/**
 * The answer after a scan. Only "Admit" is green, and the next step is spelled out in words, so nobody has to read a
 * colour at a dark door. A guest's details are shown only when the database returned them.
 */
const ScanResultCard = ({ outcome, checking, onNext, onVerify }: Props) => {
  const [code, setCode] = useState('');
  const copy = RESULT_COPY[outcome.result];
  const Icon = copy.tone === 'ok' ? CheckCircle2 : copy.tone === 'warn' ? AlertTriangle : XCircle;

  return (
    <div role="alert" aria-live="assertive" className={`rounded-2xl border-2 p-6 text-center ${TONE_CLASS[copy.tone]}`}>
      <Icon className="mx-auto mb-3 h-14 w-14" aria-hidden="true" />
      <div className="mb-1 text-3xl font-bold">{copy.label}</div>
      {outcome.customerName && (
        <p className="text-lg">
          {outcome.customerName}
          {outcome.tierName && <> · {outcome.tierName}</>}
          {outcome.quantity !== null && <> × {outcome.quantity}</>}
        </p>
      )}
      {outcome.eventTitle && <p className="text-sm opacity-90">{outcome.eventTitle}</p>}
      <p className="mt-3 text-sm opacity-90">{copy.hint}</p>
      {typeof outcome.attemptsRemaining === 'number' && outcome.result === 'code_incorrect' && (
        <p className="mt-1 text-sm font-medium">{outcome.attemptsRemaining} {outcome.attemptsRemaining === 1 ? 'try' : 'tries'} left</p>
      )}

      {needsEntryCode(outcome.result) && canRetryCode(outcome.result) && (
        <form onSubmit={(e) => { e.preventDefault(); if (code.trim()) { onVerify(code); setCode(''); } }} className="mt-4 flex gap-2">
          <Input
            aria-label="Entry code"
            placeholder="6-digit code"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            className="text-center font-mono text-lg text-white"
            inputMode="numeric"
            autoComplete="one-time-code"
            maxLength={6}
            autoFocus
          />
          <Button type="submit" disabled={checking || !code.trim()}>
            {checking ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Verify'}
          </Button>
        </form>
      )}

      {outcome.result === 'access_ended' ? (
        <Button asChild className="mt-5 w-full bg-gradient-orange font-bold text-black hover:opacity-90">
          <Link to="/home">Back to my workspaces</Link>
        </Button>
      ) : (
        <Button onClick={onNext} className={`mt-5 w-full font-bold ${needsEntryCode(outcome.result) && canRetryCode(outcome.result) ? 'bg-transparent text-current hover:bg-white/10' : 'bg-gradient-orange text-black hover:opacity-90'}`}>
          {needsEntryCode(outcome.result) && canRetryCode(outcome.result) ? 'Cancel' : 'Scan next'}
        </Button>
      )}
    </div>
  );
};

export default ScanResultCard;
