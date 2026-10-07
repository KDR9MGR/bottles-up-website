import { useState } from 'react';
import { Navigate, useSearchParams } from 'react-router-dom';
import { Building2, Megaphone } from 'lucide-react';
import { useAccount } from '@/hooks/useAccount';
import { sanitizeNext, withNext } from '@/lib/safeNext';
import type { BusinessKind } from '@/lib/accountRouting';
import AccountShell from '../components/AccountShell';
import SignupForm from '../components/SignupForm';

const TYPES: { value: BusinessKind; label: string; description: string; icon: typeof Building2 }[] = [
  { value: 'venue_owner', label: 'Venue Owner', description: 'Own and manage one or more clubs, appoint managers, set up bookings and run operations.', icon: Building2 },
  { value: 'organizer', label: 'Event Organizer', description: 'Create events and manage tickets, guests and approved venue partnerships.', icon: Megaphone },
];

const asKind = (v: string | null): BusinessKind | null => (v === 'venue_owner' || v === 'organizer' ? v : null);

/** "Create a Business Account": choose Venue Owner or Event Organizer, then register. */
const SignupBusiness = () => {
  const { session, loading } = useAccount();
  const [params] = useSearchParams();
  const next = sanitizeNext(params.get('next'), '');
  const [kind, setKind] = useState<BusinessKind>(asKind(params.get('type')) ?? 'venue_owner');

  // Already has an account (for example from the app): add the business to it, no duplicate identity.
  if (!loading && session) return <Navigate to={`/business/new?type=${kind}`} replace />;

  return (
    <AccountShell
      title="Create a business account"
      subtitle="Choose your business type, then create your login. You will add your business details next."
      backTo={withNext('/signup', next)}
      backLabel="Back"
    >
      <div className="mb-6 grid grid-cols-1 gap-2" role="radiogroup" aria-label="Business type">
        {TYPES.map((t) => {
          const Icon = t.icon;
          const selected = kind === t.value;
          return (
            <button
              key={t.value}
              type="button"
              role="radio"
              aria-checked={selected}
              onClick={() => setKind(t.value)}
              className={`rounded-lg border p-3 text-left transition-colors ${
                selected ? 'border-primary bg-primary/10 ring-1 ring-primary' : 'border-gray-800 hover:border-primary/40'
              }`}
            >
              <span className="flex items-center gap-2 text-sm font-medium text-white">
                <Icon className="h-4 w-4 text-primary" />
                {t.label}
              </span>
              <span className="mt-1 block text-xs text-gray-400">{t.description}</span>
            </button>
          );
        })}
      </div>
      <SignupForm intent={{ kind: 'business', businessKind: kind }} next={next} nameLabel="Your name" submitLabel="Create business account" />
    </AccountShell>
  );
};

export default SignupBusiness;
