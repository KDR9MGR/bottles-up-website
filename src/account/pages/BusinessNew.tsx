import { useState } from 'react';
import { Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { Building2, Loader2, Megaphone } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { useAccount } from '@/hooks/useAccount';
import { AccountError, createOrganization } from '@/lib/account';
import { leaveAddBusinessTo, type BusinessKind } from '@/lib/accountRouting';
import AccountShell from '../components/AccountShell';
import { FullPageSpinner } from './Home';

const TYPES: { value: BusinessKind; label: string; description: string; icon: typeof Building2 }[] = [
  { value: 'venue_owner', label: 'Venue Owner', description: 'Own and manage one or more clubs, appoint managers, configure bookings and run operations.', icon: Building2 },
  { value: 'organizer', label: 'Event Organizer', description: 'Create events and manage tickets, guests and approved venue partnerships.', icon: Megaphone },
];

const asKind = (v: string | null): BusinessKind | null => (v === 'venue_owner' || v === 'organizer' ? v : null);

/**
 * Adds a business to the account the person is already signed in with: the same identity, profile and
 * bookings, never a second account. The database function creates the business and makes them its owner.
 */
const BusinessNew = () => {
  const { loading, session, snapshot, refresh } = useAccount();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [kind, setKind] = useState<BusinessKind>(asKind(params.get('type')) ?? 'venue_owner');
  const [name, setName] = useState('');
  const [saving, setSaving] = useState(false);

  if (loading) return <FullPageSpinner />;
  if (!session) return <Navigate to={`/signup/business?type=${kind}`} replace />;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast({ title: 'Enter your business name', variant: 'destructive' });
      return;
    }
    setSaving(true);
    try {
      const orgId = await createOrganization(name.trim(), kind);
      await refresh();
      navigate(`/business/${orgId}/onboarding`, { replace: true });
    } catch (err) {
      toast({ title: 'Could not create the business', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <AccountShell
      title="Add your business"
      subtitle={<>Signed in as <span className="text-white">{session.user.email}</span>. Your business will be added to this account.</>}
      backTo={leaveAddBusinessTo(snapshot)}
      backLabel="Back"
    >
      <form onSubmit={submit} className="space-y-5" noValidate>
        <div className="grid grid-cols-1 gap-2" role="radiogroup" aria-label="Business type">
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
                className={`rounded-lg border p-3 text-left transition-colors ${selected ? 'border-primary bg-primary/10 ring-1 ring-primary' : 'border-gray-800 hover:border-primary/40'}`}
              >
                <span className="flex items-center gap-2 text-sm font-medium text-white"><Icon className="h-4 w-4 text-primary" />{t.label}</span>
                <span className="mt-1 block text-xs text-gray-400">{t.description}</span>
              </button>
            );
          })}
        </div>
        <div className="space-y-2">
          <Label htmlFor="bn-name" className="text-gray-300">{kind === 'venue_owner' ? 'Business name' : 'Organizer name'}</Label>
          <Input id="bn-name" value={name} onChange={(e) => setName(e.target.value)} maxLength={120} required />
          <p className="text-xs text-gray-500">You can add the legal details and your venues on the next page.</p>
        </div>
        <Button type="submit" disabled={saving} className="w-full bg-gradient-orange font-bold text-black hover:opacity-90">
          {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Continue'}
        </Button>
      </form>
    </AccountShell>
  );
};

export default BusinessNew;
