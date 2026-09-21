import { useState } from 'react';
import { CheckCircle2, AlertTriangle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { respondToClubPayment, type CustomerConfirmationStatus } from '@/lib/clubPayment';

const methodLabel: Record<string, string> = {
  cash: 'Cash',
  debit: 'Debit',
  credit: 'Credit',
  split: 'Split payment',
};

const money = (cents: number, currency: string) => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

interface ClubPaymentConfirmCardProps {
  token: string;
  billedAmountCents: number;
  amountPaidCents: number;
  paymentMethod: string;
  currency: string;
  status: CustomerConfirmationStatus;
  disputeReason?: string | null;
  onResponded?: (status: 'confirmed' | 'disputed') => void;
}

const ClubPaymentConfirmCard = ({
  token,
  billedAmountCents,
  amountPaidCents,
  paymentMethod,
  currency,
  status: initialStatus,
  disputeReason: initialDisputeReason,
  onResponded,
}: ClubPaymentConfirmCardProps) => {
  const { toast } = useToast();
  const [status, setStatus] = useState(initialStatus);
  const [disputeReason, setDisputeReason] = useState(initialDisputeReason ?? null);
  const [showDisputeForm, setShowDisputeForm] = useState(false);
  const [reason, setReason] = useState('');
  const [evidenceFile, setEvidenceFile] = useState<File | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const handleConfirm = async () => {
    setSubmitting(true);
    try {
      const result = await respondToClubPayment({ token, action: 'confirm' });
      if (!result.success) {
        toast({ title: 'Could not confirm', description: result.error === 'already_responded' ? 'This payment already has a response on file.' : undefined, variant: 'destructive' });
        if (result.status) setStatus(result.status);
        return;
      }
      setStatus('confirmed');
      onResponded?.('confirmed');
    } catch {
      toast({ title: 'Could not confirm', description: 'Please try again.', variant: 'destructive' });
    } finally {
      setSubmitting(false);
    }
  };

  const handleDispute = async () => {
    if (!reason.trim()) {
      toast({ title: 'Please describe the issue', variant: 'destructive' });
      return;
    }
    setSubmitting(true);
    try {
      const result = await respondToClubPayment({ token, action: 'dispute', reason, evidenceFile });
      if (!result.success) {
        toast({ title: 'Could not submit', description: result.error === 'already_responded' ? 'This payment already has a response on file.' : undefined, variant: 'destructive' });
        if (result.status) setStatus(result.status);
        return;
      }
      setStatus('disputed');
      setDisputeReason(reason);
      onResponded?.('disputed');
    } catch {
      toast({ title: 'Could not submit', description: 'Please try again.', variant: 'destructive' });
    } finally {
      setSubmitting(false);
    }
  };

  if (status === 'confirmed') {
    return (
      <div className="rounded-2xl border-2 border-green-600 bg-green-950/40 p-5 text-center text-green-400">
        <CheckCircle2 className="mx-auto mb-2 h-8 w-8" />
        <p className="font-bold">Customer Confirmed</p>
        <p className="mt-1 text-sm text-green-300">Thanks for confirming - you're all set.</p>
      </div>
    );
  }

  if (status === 'disputed') {
    return (
      <div className="rounded-2xl border-2 border-red-600 bg-red-950/40 p-5 text-center text-red-400">
        <AlertTriangle className="mx-auto mb-2 h-8 w-8" />
        <p className="font-bold">Reported - Under Review</p>
        {disputeReason && <p className="mt-1 text-sm text-red-300">"{disputeReason}"</p>}
        <p className="mt-1 text-xs text-red-300/80">The venue has been notified and will follow up.</p>
      </div>
    );
  }

  return (
    <div className="rounded-2xl border border-orange-500/30 bg-orange-500/5 p-5">
      <p className="mb-3 text-sm font-medium text-white">Please confirm this payment</p>
      <div className="mb-4 space-y-1.5 rounded-lg border border-gray-800 bg-black/30 p-3 text-sm">
        <div className="flex justify-between text-gray-300">
          <span>Billed amount</span>
          <span>{money(billedAmountCents, currency)}</span>
        </div>
        <div className="flex justify-between text-gray-300">
          <span>Amount paid</span>
          <span>{money(amountPaidCents, currency)}</span>
        </div>
        <div className="flex justify-between text-gray-300">
          <span>Payment method</span>
          <span>{methodLabel[paymentMethod] ?? paymentMethod}</span>
        </div>
      </div>

      {showDisputeForm ? (
        <div className="space-y-3">
          <div className="space-y-1">
            <Label className="text-xs text-gray-400">What's wrong?</Label>
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Tell us what doesn't look right" />
          </div>
          <div className="space-y-1">
            <Label className="text-xs text-gray-400">Evidence photo (optional)</Label>
            <Input type="file" accept="image/*" onChange={(e) => setEvidenceFile(e.target.files?.[0] ?? null)} />
          </div>
          <div className="flex gap-2">
            <Button variant="outline" className="flex-1 border-gray-700" onClick={() => setShowDisputeForm(false)}>
              Back
            </Button>
            <Button className="flex-1 bg-red-600 text-white hover:bg-red-700" disabled={submitting} onClick={handleDispute}>
              {submitting ? 'Submitting...' : 'Submit Report'}
            </Button>
          </div>
        </div>
      ) : (
        <div className="flex gap-2">
          <Button variant="outline" className="flex-1 border-gray-700 text-gray-300" onClick={() => setShowDisputeForm(true)}>
            Report an Issue
          </Button>
          <Button
            className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90"
            disabled={submitting}
            onClick={handleConfirm}
          >
            {submitting ? 'Saving...' : 'Confirm Details Are Correct'}
          </Button>
        </div>
      )}
    </div>
  );
};

export default ClubPaymentConfirmCard;
