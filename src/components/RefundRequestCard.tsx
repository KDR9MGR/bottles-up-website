import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { RefundRequestError, requestRefund } from '@/lib/refundPolicy';

interface RefundRequestCardProps {
  confirmationCode: string;
  email: string;
}

/**
 * "Need to cancel? Ask for a refund." A guest tells the venue why; the venue looks at the request against its own refund policy (shown before payment) and answers. Nothing is
 * refunded by pressing this: it only sends the request, once per booking while the venue is looking at it.
 */
const RefundRequestCard = ({ confirmationCode, email }: RefundRequestCardProps) => {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const tooShort = reason.trim().length < 3;

  const send = async () => {
    if (busy || tooShort) return;
    setBusy(true);
    setError(null);
    try {
      setSent(await requestRefund(confirmationCode, email, reason));
    } catch (err) {
      setError(err instanceof RefundRequestError ? err.message : 'Your request could not be sent just now. Try again in a moment.');
    } finally {
      setBusy(false);
    }
  };

  if (sent) {
    return <p className="mt-4 w-full max-w-sm rounded-xl border border-green-900/60 bg-green-950/30 p-3 text-sm text-green-300">{sent}</p>;
  }

  return (
    <div className="mt-4 w-full max-w-sm text-left">
      {!open ? (
        <button type="button" className="text-sm text-gray-400 underline" onClick={() => setOpen(true)}>
          Need to cancel? Ask the venue for a refund
        </button>
      ) : (
        <div className="space-y-2 rounded-xl border border-gray-800 bg-gray-950 p-4">
          <p className="text-sm text-gray-300">Tell the venue why. They will look at your request against their refund policy and update you.</p>
          <Textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            maxLength={500}
            placeholder="For example: I can no longer come on Saturday"
            className="bg-zinc-900 border-white/10"
            aria-label="Why do you need a refund?"
          />
          {error && <p className="text-xs text-red-400">{error}</p>}
          <div className="flex gap-2">
            <Button type="button" variant="outline" className="border-gray-700" disabled={busy} onClick={() => setOpen(false)}>Not now</Button>
            <Button type="button" disabled={busy || tooShort} onClick={() => void send()}>{busy ? 'Sending...' : 'Send my request'}</Button>
          </div>
        </div>
      )}
    </div>
  );
};

export default RefundRequestCard;
