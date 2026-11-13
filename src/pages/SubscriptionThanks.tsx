import { Link, useSearchParams } from 'react-router-dom';
import { CheckCircle2, XCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';

/** Where Stripe's page sends a professional after they subscribe a profile (or leave, or come back from the billing page). The BottlesUp app, which opened the page, shows the result by itself. */
export const SubscriptionThanksView = ({ cancelled }: { cancelled: boolean }) => (
  <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center" data-testid={cancelled ? 'subscription-cancelled' : 'subscription-thanks'}>
    {cancelled ? <XCircle className="mb-6 h-12 w-12 text-gray-500" /> : <CheckCircle2 className="mb-6 h-12 w-12 text-green-500" />}
    <h1 className="mb-4 text-3xl font-bold text-white">{cancelled ? 'Nothing was charged' : 'Thank you'}</h1>
    <p className="mb-8 max-w-md text-gray-400">
      {cancelled
        ? 'You left before subscribing. Go back to the BottlesUp app whenever you are ready.'
        : 'Your subscription is being set up. Go back to the BottlesUp app: it shows your profile as subscribed in a moment, and Stripe e-mails you a receipt.'}
    </p>
    <Button asChild className="bg-gradient-orange text-black font-bold hover:opacity-90">
      <Link to="/">Back to BottlesUp</Link>
    </Button>
  </div>
);

const SubscriptionThanks = () => {
  const [params] = useSearchParams();
  return <SubscriptionThanksView cancelled={params.get('cancelled') === '1'} />;
};

export default SubscriptionThanks;
