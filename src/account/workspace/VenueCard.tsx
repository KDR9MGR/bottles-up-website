import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Check, Circle, Clock } from 'lucide-react';
import { venueSetupStatus } from '@/lib/account';
import { onboardingPath } from '@/lib/accountRouting';
import { orderSteps, statusLabel, stepDescription, stepLabel, summarizeSetup, type SetupStep } from '@/lib/venueSetup';
import { publishVenueGate, type VerificationState } from '@/lib/verification';

interface Props {
  orgId: string;
  venueId: string;
  name: string;
  status: string;
  businessState: VerificationState;
  /** Where the "finish setup" action should go. */
  setupPath: string;
  /** Show every step with its description (the venue page) rather than just the summary. */
  detailed?: boolean;
  children?: React.ReactNode;
}

const StepIcon = ({ status }: { status: SetupStep['status'] }) =>
  status === 'done' ? <Check className="h-4 w-4 text-green-400" /> : status === 'unavailable' ? <Clock className="h-4 w-4 text-gray-500" /> : <Circle className="h-4 w-4 text-amber-400" />;

/**
 * One venue's setup progress. Readiness counts only the required steps and is separate from the
 * business's verification: both must be satisfied before publishing, and the card says which one is in the way.
 */
const VenueCard = ({ orgId, venueId, name, status, businessState, setupPath, detailed = false, children }: Props) => {
  const [steps, setSteps] = useState<SetupStep[] | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    venueSetupStatus(venueId)
      .then((s) => !cancelled && setSteps(orderSteps(s)))
      .catch(() => !cancelled && setFailed(true));
    return () => {
      cancelled = true;
    };
  }, [venueId]);

  const summary = steps ? summarizeSetup(steps) : null;
  const gate = summary
    ? publishVenueGate({ state: businessState, requiredStepsTodo: summary.requiredTodo, onboardingPath: onboardingPath(orgId), setupPath })
    : null;

  return (
    <article id={`venue-${venueId}`} className="rounded-2xl border border-gray-800 bg-gray-900/50 p-5">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-lg font-semibold text-white">{name}</h3>
        <span className="rounded-full border border-gray-700 px-2.5 py-0.5 text-xs capitalize text-gray-300">{status === 'published' ? 'Live' : 'Draft'}</span>
      </header>

      {failed && <p className="mt-3 text-sm text-gray-500">Setup progress is not available right now.</p>}

      {summary && (
        <>
          <div className="mt-4">
            <div className="mb-1 flex justify-between text-xs text-gray-400">
              <span>Venue setup</span>
              <span>{summary.requiredDone} of {summary.requiredTotal} required steps</span>
            </div>
            <div className="h-2 overflow-hidden rounded-full bg-gray-800" role="progressbar" aria-valuenow={summary.percent} aria-valuemin={0} aria-valuemax={100} aria-label={`${name} setup progress`}>
              <div className="h-full rounded-full bg-gradient-orange transition-all" style={{ width: `${summary.percent}%` }} />
            </div>
          </div>

          {gate && !gate.allowed && gate.reason && gate.action && (
            <p className="mt-4 rounded-lg border border-gray-800 bg-black/40 p-3 text-sm text-gray-300">
              {gate.reason}{' '}
              <Link to={gate.action.to} className="font-medium text-primary hover:underline">{gate.action.label}</Link>
            </p>
          )}
          {gate?.allowed && status !== 'published' && (
            <p className="mt-4 rounded-lg border border-green-500/30 bg-green-500/10 p-3 text-sm text-green-200">
              Verified and fully set up. Contact the BottlesUp team to take this venue live.
            </p>
          )}

          <ul className="mt-4 divide-y divide-gray-800">
            {steps?.filter((s) => detailed || s.status === 'todo' || s.required).map((s) => (
              <li key={s.step} className="flex items-start gap-3 py-2.5">
                <span className="mt-0.5"><StepIcon status={s.status} /></span>
                <div className="min-w-0 flex-1">
                  <p className="text-sm text-white">
                    {stepLabel(s.step)} {!s.required && <span className="text-xs text-gray-500">(optional)</span>}
                  </p>
                  {detailed && <p className="text-xs text-gray-500">{stepDescription(s.step)}</p>}
                  {s.status === 'todo' && s.detail && <p className="text-xs text-amber-300">To do: {s.detail}</p>}
                </div>
                <span className="text-xs text-gray-500">{statusLabel(s.status)}</span>
              </li>
            ))}
          </ul>
        </>
      )}
      {children}
    </article>
  );
};

export default VenueCard;
