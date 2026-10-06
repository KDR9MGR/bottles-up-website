import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useToast } from '@/hooks/use-toast';
import { AccountError, submitVerification } from '@/lib/account';
import { describeMissing, stateInfo, type VerificationState } from '@/lib/verification';
import StateBadge from './StateBadge';

interface Props {
  orgId: string;
  state: VerificationState;
  requestMessage: string | null;
  missing: string[];
  onSubmitted: () => void;
}

const focusField = (field: string) => {
  const el = document.getElementById(`field-${field}`);
  el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  el?.querySelector<HTMLElement>('input, textarea, button')?.focus({ preventScroll: true });
};

/**
 * Verification progress (client brief, section 3). Shows where the business stands, the reviewer's specific
 * request when there is one, and exactly what is missing before it can be submitted.
 */
const VerificationPanel = ({ orgId, state, requestMessage, missing, onSubmitted }: Props) => {
  const { toast } = useToast();
  const [submitting, setSubmitting] = useState(false);
  const info = stateInfo(state);
  const items = describeMissing(missing);
  const canSubmitNow = info.canSubmit && items.length === 0;

  const submit = async () => {
    setSubmitting(true);
    try {
      await submitVerification(orgId);
      toast({ title: 'Submitted for review', description: 'We will email you when we have a decision. You can keep setting up your venue.' });
      onSubmitted();
    } catch (err) {
      toast({ title: 'Could not submit', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <StateBadge state={state} />
        <p className="text-sm text-gray-400">{info.summary}</p>
      </div>

      {state === 'more_information_needed' && requestMessage && (
        <div role="alert" className="rounded-lg border border-amber-500/40 bg-amber-500/10 p-4">
          <p className="text-sm font-medium text-amber-200">What we need from you</p>
          <p className="mt-1 whitespace-pre-line text-sm text-amber-100">{requestMessage}</p>
        </div>
      )}

      {info.canSubmit && items.length > 0 && (
        <div className="rounded-lg border border-gray-800 bg-black/40 p-4">
          <p className="mb-2 text-sm font-medium text-white">Before you can submit</p>
          <ul className="space-y-1.5">
            {items.map((m) => (
              <li key={m.key}>
                <button type="button" onClick={() => focusField(m.field)} className="text-left text-sm text-amber-300 hover:underline">
                  {m.message}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {info.canSubmit && (
        <Button onClick={submit} disabled={!canSubmitNow || submitting} className="bg-gradient-orange font-bold text-black hover:opacity-90 disabled:opacity-40">
          {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : state === 'more_information_needed' ? 'Submit again' : 'Submit for verification'}
        </Button>
      )}

      {(state === 'under_review' || state === 'verified') && (
        <Button asChild variant="outline" className="border-gray-700 text-white hover:bg-gray-900">
          <Link to="/home">Continue to your workspace</Link>
        </Button>
      )}
    </div>
  );
};

export default VerificationPanel;
