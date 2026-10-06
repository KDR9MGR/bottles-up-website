import { Link } from 'react-router-dom';
import { Briefcase, LifeBuoy, LogIn, User } from 'lucide-react';
import { useAccountOptional } from '@/hooks/useAccount';
import { useSiteContent } from '@/hooks/useSiteContent';
import { safeStoreUrl } from '@/lib/accountPrompt';
import { APP_STORE_URL, PLAY_STORE_URL } from '@/lib/features';

/**
 * The permanent, undismissable version of the account options (client brief, section 1): personal and
 * business accounts, log in, help, and app download links once the apps are published.
 */
const GetStarted = () => {
  const account = useAccountOptional();
  const content = useSiteContent();
  if (!account || account.loading || account.snapshot.signedIn) return null;

  const appStore = safeStoreUrl(APP_STORE_URL);
  const playStore = safeStoreUrl(PLAY_STORE_URL);

  return (
    <section id="get-started" aria-labelledby="get-started-title" className="border-t border-white/5 bg-black py-16">
      <div className="container mx-auto max-w-5xl px-4">
        <h2 id="get-started-title" className="text-center text-3xl font-bold text-white">Get started with BottlesUp</h2>
        <p className="mx-auto mt-3 max-w-2xl text-center text-gray-400">
          Guests discover and book tables and tickets. Venues run bookings, bottle service and payments. Organizers create events and
          manage guests. One account works on the website and in the app.
        </p>
        <div className="mt-10 grid gap-4 md:grid-cols-3">
          <Link to="/signup/personal" className="rounded-2xl border border-gray-800 bg-gray-900/50 p-6 transition-colors hover:border-primary/60">
            <User className="mb-3 h-6 w-6 text-primary" />
            <h3 className="font-semibold text-white">Create a Personal Account</h3>
            <p className="mt-1 text-sm text-gray-400">Register, verify your contact and set up your profile.</p>
          </Link>
          <Link to="/signup/business" className="rounded-2xl border border-gray-800 bg-gray-900/50 p-6 transition-colors hover:border-primary/60">
            <Briefcase className="mb-3 h-6 w-6 text-primary" />
            <h3 className="font-semibold text-white">Create a Business Account</h3>
            <p className="mt-1 text-sm text-gray-400">Choose Venue Owner or Event Organizer and begin business onboarding.</p>
          </Link>
          <Link to="/login" className="rounded-2xl border border-gray-800 bg-gray-900/50 p-6 transition-colors hover:border-primary/60">
            <LogIn className="mb-3 h-6 w-6 text-primary" />
            <h3 className="font-semibold text-white">Already have an account? Log in</h3>
            <p className="mt-1 text-sm text-gray-400">Use your existing BottlesUp account and open your workspace.</p>
          </Link>
        </div>
        <div className="mt-8 flex flex-col items-center gap-4 sm:flex-row sm:justify-center">
          {appStore && <a href={appStore} className="rounded-lg border border-gray-700 px-5 py-2.5 text-sm text-white hover:bg-white/5" rel="noopener noreferrer">Download on the App Store</a>}
          {playStore && <a href={playStore} className="rounded-lg border border-gray-700 px-5 py-2.5 text-sm text-white hover:bg-white/5" rel="noopener noreferrer">Get it on Google Play</a>}
          <a href={`mailto:${content.contact_email}`} className="inline-flex items-center gap-2 text-sm text-gray-400 hover:text-primary">
            <LifeBuoy className="h-4 w-4" /> Need help? {content.contact_email}
          </a>
        </div>
      </div>
    </section>
  );
};

export default GetStarted;
