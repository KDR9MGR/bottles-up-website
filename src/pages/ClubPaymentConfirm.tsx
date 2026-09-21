import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import ClubPaymentConfirmCard from '@/components/ClubPaymentConfirmCard';
import { lookupClubPaymentByToken, type ClubPaymentLookup } from '@/lib/clubPayment';

// Public, no login required - reached via the link in the club payment
// confirmation email (section 6). The token in the URL is the capability.
const ClubPaymentConfirm = () => {
  const { token } = useParams<{ token: string }>();
  const [loading, setLoading] = useState(true);
  const [lookup, setLookup] = useState<ClubPaymentLookup | null>(null);

  useEffect(() => {
    if (!token) return;
    lookupClubPaymentByToken(token)
      .then(setLookup)
      .catch(() => setLookup({ found: false }))
      .finally(() => setLoading(false));
  }, [token]);

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
        <p className="text-gray-400">We couldn't find this payment record.</p>
        <Button asChild className="mt-4 bg-gradient-orange text-black font-bold hover:opacity-90">
          <Link to="/">Back to BottlesUp</Link>
        </Button>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen flex-col items-center bg-black px-4 py-12">
      <div className="w-full max-w-sm">
        <h1 className="mb-1 text-center text-xl font-bold text-white">
          {lookup.tableTypeName} - {lookup.venueName}
        </h1>
        <p className="mb-6 text-center text-sm text-gray-500">Confirmation {lookup.confirmationCode}</p>

        <ClubPaymentConfirmCard
          token={token}
          billedAmountCents={lookup.billedAmountCents!}
          amountPaidCents={lookup.amountPaidCents!}
          paymentMethod={lookup.paymentMethod!}
          currency={lookup.currency!}
          status={lookup.status!}
          disputeReason={lookup.disputeReason}
        />

        <Button asChild variant="outline" className="mt-6 w-full border-gray-700 text-gray-300">
          <Link to="/">Back to BottlesUp</Link>
        </Button>
      </div>
    </div>
  );
};

export default ClubPaymentConfirm;
