import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { useToast } from '@/hooks/use-toast';
import { useAccount } from '@/hooks/useAccount';
import { cancelBusinessSteps, confirmCancelBusiness } from '@/lib/cancelBusiness';
import { canCancelBusiness, type VerificationState } from '@/lib/verification';
import ConfirmRemove from '../setup/ConfirmRemove';

interface Props {
  orgId: string;
  name: string;
  state: VerificationState;
}

/**
 * "I added this business by mistake." Offered until the business is verified; after that it says who to ask. The database
 * makes the same decision, so a stale page cannot cancel something that is no longer allowed.
 */
const CancelBusiness = ({ orgId, name, state }: Props) => {
  const { refresh } = useAccount();
  const { toast } = useToast();
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);

  if (!canCancelBusiness(state)) {
    return (
      <p className="text-xs text-gray-500" data-testid="cancel-unavailable">
        Added this business by mistake? A business that is under review or verified cannot be cancelled here. Contact BottlesUp and we will help.
      </p>
    );
  }

  const confirm = async () => {
    setBusy(true);
    const outcome = await confirmCancelBusiness(orgId, cancelBusinessSteps(refresh));
    setBusy(false);
    if (outcome.ok) {
      toast({ title: 'Business cancelled', description: `${name} has been deleted.` });
      navigate(outcome.goTo ?? '/home', { replace: true });
    } else {
      setOpen(false);
      toast({ title: 'Could not cancel the business', description: outcome.message ?? 'Please try again.', variant: 'destructive' });
    }
  };

  return (
    <section className="rounded-xl border border-red-900/50 bg-red-950/10 p-4 sm:p-5" aria-labelledby="cancel-business-title">
      <h2 id="cancel-business-title" className="text-base font-semibold text-white">Added this business by mistake?</h2>
      <p className="mt-1 text-sm text-gray-400">
        Cancel it to delete <span className="text-white">{name}</span>, the details you entered and any venues you added to it. This cannot be undone.
        Nobody else's account is affected.
      </p>
      <Button type="button" variant="outline" onClick={() => setOpen(true)} className="mt-4 border-red-800 text-red-300 hover:bg-red-950/40 hover:text-red-200">
        Cancel this business
      </Button>
      <ConfirmRemove
        open={open}
        busy={busy}
        title={`Cancel ${name}?`}
        description={`${name}, the details you entered and any venues you added to it will be deleted. This cannot be undone.`}
        confirmLabel="Yes, cancel it"
        busyLabel="Cancelling…"
        keepLabel="Keep it"
        onConfirm={() => void confirm()}
        onClose={() => setOpen(false)}
      />
    </section>
  );
};

export default CancelBusiness;
