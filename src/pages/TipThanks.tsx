import { Link, useSearchParams } from 'react-router-dom';
import { CheckCircle2, XCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';

/** Where Stripe's page sends someone after they tip (or leave). The BottlesUp app, which opened the page, shows the result by itself. */
export const TipThanksView = ({ cancelled }: { cancelled: boolean }) => (
  <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center" data-testid={cancelled ? 'tip-cancelled' : 'tip-thanks'}>
    {cancelled ? <XCircle className="mb-6 h-12 w-12 text-gray-500" /> : <CheckCircle2 className="mb-6 h-12 w-12 text-green-500" />}
    <h1 className="mb-4 text-3xl font-bold text-white">{cancelled ? 'Nothing was charged' : 'Thank you'}</h1>
    <p className="mb-8 max-w-md text-gray-400">
      {cancelled
        ? 'You left before paying. Go back to the BottlesUp app to try again.'
        : 'Your tip is on its way to the creator, less BottlesUp\'s commission. Go back to the BottlesUp app; Stripe e-mails you a receipt.'}
    </p>
    <Button asChild className="bg-gradient-orange text-black font-bold hover:opacity-90">
      <Link to="/">Back to BottlesUp</Link>
    </Button>
  </div>
);

const TipThanks = () => {
  const [params] = useSearchParams();
  return <TipThanksView cancelled={params.get('cancelled') === '1'} />;
};

export default TipThanks;
