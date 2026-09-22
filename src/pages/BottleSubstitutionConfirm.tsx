import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { CheckCircle2, Loader2, XCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useToast } from '@/hooks/use-toast';
import {
  lookupBottleSubstitution,
  respondToBottleSubstitution,
  type BottleSubstitutionLookup,
} from '@/lib/bottleExceptions';

const money = (cents: number, currency: string) => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

// Public, no login required - reached via the link in the "a bottle is
// unavailable" email (section 9). The token in the URL is the capability,
// same pattern as /club-payment/confirm/:token.
const BottleSubstitutionConfirm = () => {
  const { token } = useParams<{ token: string }>();
  const { toast } = useToast();
  const [loading, setLoading] = useState(true);
  const [lookup, setLookup] = useState<BottleSubstitutionLookup | null>(null);
  const [status, setStatus] = useState<'pending' | 'approved' | 'declined' | undefined>(undefined);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!token) return;
    lookupBottleSubstitution(token)
      .then((result) => {
        setLookup(result);
        setStatus(result.status);
      })
      .catch(() => setLookup({ found: false }))
      .finally(() => setLoading(false));
  }, [token]);

  const respond = async (action: 'approve' | 'decline') => {
    if (!token || submitting) return;
    setSubmitting(true);
    try {
      const result = await respondToBottleSubstitution({ token, action });
      if (!result.success) {
        toast({
          title: 'Could not submit',
          description: result.error === 'already_responded' ? 'You already responded to this request.' : undefined,
          variant: 'destructive',
        });
        if (result.status) setStatus(result.status as 'approved' | 'declined');
        return;
      }
      setStatus(action === 'approve' ? 'approved' : 'declined');
    } catch {
      toast({ title: 'Could not submit', description: 'Please try again.', variant: 'destructive' });
    } finally {
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black">
        <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
      </div>
    );
  }

  if (!token || !lookup?.found) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center">
        <p className="text-gray-400">We couldn't find this request.</p>
        <Button asChild className="mt-4 bg-gradient-orange text-black font-bold hover:opacity-90">
          <Link to="/">Back to BottlesUp</Link>
        </Button>
      </div>
    );
  }

  const originalLabel = `${lookup.originalBottleName}${lookup.originalSize ? ` (${lookup.originalSize})` : ''} × ${lookup.quantity}`;

  return (
    <div className="flex min-h-screen flex-col items-center bg-black px-4 py-12">
      <div className="w-full max-w-sm">
        <h1 className="mb-1 text-center text-xl font-bold text-white">{lookup.venueName}</h1>
        <p className="mb-6 text-center text-sm text-gray-500">Confirmation {lookup.confirmationCode}</p>

        {status === 'approved' ? (
          <div className="rounded-2xl border-2 border-green-600 bg-green-950/40 p-5 text-center text-green-400">
            <CheckCircle2 className="mx-auto mb-2 h-8 w-8" />
            <p className="font-bold">Change Approved</p>
            <p className="mt-1 text-sm text-green-300">Your order has been updated.</p>
          </div>
        ) : status === 'declined' ? (
          <div className="rounded-2xl border-2 border-gray-700 bg-gray-950 p-5 text-center text-gray-300">
            <XCircle className="mx-auto mb-2 h-8 w-8" />
            <p className="font-bold">Change Declined</p>
            <p className="mt-1 text-sm text-gray-400">Your original order is unchanged. The venue has been notified.</p>
          </div>
        ) : (
          <div className="rounded-2xl border border-orange-500/30 bg-orange-500/5 p-5">
            <p className="mb-3 text-sm font-medium text-white">One of your bottles is unavailable</p>
            <div className="mb-4 space-y-2 rounded-lg border border-gray-800 bg-black/30 p-3 text-sm">
              <div className="text-gray-300">{originalLabel}</div>
              <div className="text-xs text-gray-500">Reason: {lookup.reason}</div>
              {lookup.replacementBottleName ? (
                <div className="border-t border-gray-800 pt-2 text-gray-300">
                  Proposed replacement: <strong>{lookup.replacementBottleName}{lookup.replacementSize ? ` (${lookup.replacementSize})` : ''}</strong>
                </div>
              ) : (
                <div className="border-t border-gray-800 pt-2 text-gray-300">The venue is proposing to remove this item.</div>
              )}
              {lookup.priceDiffCents !== 0 && (
                <div className={lookup.priceDiffCents! > 0 ? 'text-orange-400' : 'text-emerald-400'}>
                  {lookup.priceDiffCents! > 0
                    ? `Adds ${money(lookup.priceDiffCents!, lookup.currency ?? 'cad')} to your order`
                    : `Reduces your order by ${money(-lookup.priceDiffCents!, lookup.currency ?? 'cad')}`}
                </div>
              )}
            </div>
            <div className="flex gap-2">
              <Button variant="outline" className="flex-1 border-gray-700" disabled={submitting} onClick={() => respond('decline')}>
                Decline
              </Button>
              <Button
                className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90"
                disabled={submitting}
                onClick={() => respond('approve')}
              >
                {submitting ? 'Saving...' : 'Approve'}
              </Button>
            </div>
          </div>
        )}

        <Button asChild variant="outline" className="mt-6 w-full border-gray-700 text-gray-300">
          <Link to="/">Back to BottlesUp</Link>
        </Button>
      </div>
    </div>
  );
};

export default BottleSubstitutionConfirm;
