import { Link, useSearchParams } from 'react-router-dom';
import { CheckCircle2, XCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';

/** Where Stripe's page sends a friend after they pay (or leave) their share of a table. The BottlesUp app, which opened the page, shows the result by itself. */
export const SplitShareThanksView = ({ cancelled }: { cancelled: boolean }) => (
  <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center" data-testid={cancelled ? 'share-cancelled' : 'share-thanks'}>
    {cancelled ? <XCircle className="mb-6 h-12 w-12 text-gray-500" /> : <CheckCircle2 className="mb-6 h-12 w-12 text-green-500" />}
    <h1 className="mb-4 text-3xl font-bold text-white">{cancelled ? 'Nothing was charged' : 'Thank you'}</h1>
    <p className="mb-8 max-w-md text-gray-400">
      {cancelled
        ? 'You left before paying. Go back to the BottlesUp app to try again; your request is still there until the deadline.'
        : 'Your share is on its way to the table. Go back to the BottlesUp app: it shows your share as paid in a moment, and Stripe e-mails you a receipt.'}
    </p>
    <Button asChild className="bg-gradient-orange text-black font-bold hover:opacity-90">
      <Link to="/">Back to BottlesUp</Link>
    </Button>
  </div>
);

const SplitShareThanks = () => {
  const [params] = useSearchParams();
  return <SplitShareThanksView cancelled={params.get('cancelled') === '1'} />;
};

export default SplitShareThanks;
