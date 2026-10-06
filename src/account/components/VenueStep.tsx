import { useCallback, useEffect, useState } from 'react';
import { Loader2, MapPin, Search } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { useToast } from '@/hooks/use-toast';
import {
  AccountError, createOrgVenue, fetchOrgVenues, listVenueClaims, requestVenueClaim, searchVenues,
  type VenueClaim, type VenueMatch,
} from '@/lib/account';

interface Props {
  orgId: string;
  /** Called after a venue is added or a claim is requested, so the page can refresh what is missing. */
  onChanged: () => void;
}

const CLAIM_LABEL: Record<VenueClaim['status'], string> = {
  pending: 'Waiting for review',
  approved: 'Approved',
  rejected: 'Not approved',
};

/**
 * "Add or Claim Venue". Existing venues are searched first so there is never a duplicate listing. A venue
 * that already exists is requested, not taken: a BottlesUp reviewer decides, and an existing owner is never
 * replaced automatically.
 */
const VenueStep = ({ orgId, onChanged }: Props) => {
  const { toast } = useToast();
  const [venues, setVenues] = useState<{ venueId: string; name: string; status: string }[]>([]);
  const [claims, setClaims] = useState<VenueClaim[]>([]);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<VenueMatch[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [claiming, setClaiming] = useState<string | null>(null);
  const [message, setMessage] = useState('');
  const [newName, setNewName] = useState('');
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    try {
      const [v, c] = await Promise.all([fetchOrgVenues(orgId), listVenueClaims(orgId)]);
      setVenues(v);
      setClaims(c);
    } catch {
      /* the lists are an aid; the search and create actions below still work */
    }
  }, [orgId]);

  useEffect(() => { void load(); }, [load]);

  const search = async (e: React.FormEvent) => {
    e.preventDefault();
    if (query.trim().length < 2) {
      toast({ title: 'Type at least two letters', variant: 'destructive' });
      return;
    }
    setSearching(true);
    try {
      setResults(await searchVenues(query));
    } catch (err) {
      toast({ title: 'Search failed', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setSearching(false);
    }
  };

  const claim = async (venueId: string) => {
    try {
      await requestVenueClaim(orgId, venueId, message);
      toast({ title: 'Request sent', description: 'Our team will review it and email you.' });
      setClaiming(null);
      setMessage('');
      await load();
      onChanged();
    } catch (err) {
      toast({ title: 'Could not send the request', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    }
  };

  const create = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newName.trim()) return;
    setCreating(true);
    try {
      await createOrgVenue(orgId, newName.trim());
      setNewName('');
      await load();
      onChanged();
      toast({ title: 'Venue added' });
    } catch (err) {
      toast({ title: 'Could not add the venue', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="space-y-6">
      {(venues.length > 0 || claims.length > 0) && (
        <div className="space-y-2">
          <h3 className="text-sm font-medium text-gray-300">Your venues</h3>
          <ul className="space-y-2">
            {venues.map((v) => (
              <li key={v.venueId} className="flex items-center justify-between rounded-lg border border-gray-800 bg-black/40 px-3 py-2 text-sm">
                <span className="text-white">{v.name}</span>
                <span className="text-xs text-gray-500">Added</span>
              </li>
            ))}
            {claims.map((c) => (
              <li key={c.claimId} className="rounded-lg border border-gray-800 bg-black/40 px-3 py-2 text-sm">
                <div className="flex items-center justify-between">
                  <span className="text-white">{c.venueName}</span>
                  <span className={`text-xs ${c.status === 'pending' ? 'text-blue-300' : c.status === 'approved' ? 'text-green-300' : 'text-amber-300'}`}>{CLAIM_LABEL[c.status]}</span>
                </div>
                {c.reviewNote && <p className="mt-1 text-xs text-gray-400">{c.reviewNote}</p>}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="space-y-3">
        <h3 className="text-sm font-medium text-gray-300">Is your venue already on BottlesUp?</h3>
        <form onSubmit={search} className="flex gap-2">
          <Input aria-label="Search venues" placeholder="Search by name or address" value={query} onChange={(e) => setQuery(e.target.value)} />
          <Button type="submit" variant="outline" disabled={searching} className="border-gray-700 text-white hover:bg-gray-900">
            {searching ? <Loader2 className="h-4 w-4 animate-spin" /> : <Search className="h-4 w-4" />}
            <span className="sr-only">Search</span>
          </Button>
        </form>
        {results && results.length === 0 && <p className="text-sm text-gray-500">No venue found. You can add it below.</p>}
        {results && results.length > 0 && (
          <ul className="space-y-2">
            {results.map((m) => (
              <li key={m.venueId} className="rounded-lg border border-gray-800 bg-black/40 p-3">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-white">{m.name}</p>
                    {m.address && <p className="flex items-center gap-1 truncate text-xs text-gray-500"><MapPin className="h-3 w-3" />{m.address}</p>}
                    {m.isClaimed && !m.claimedByYou && <p className="mt-1 text-xs text-amber-300">Already managed by another business. We review every ownership request.</p>}
                  </div>
                  {m.claimedByYou ? (
                    <span className="shrink-0 text-xs text-green-300">Yours</span>
                  ) : (
                    <Button size="sm" variant="outline" className="shrink-0 border-gray-700 text-white hover:bg-gray-900" onClick={() => setClaiming(claiming === m.venueId ? null : m.venueId)}>
                      Request ownership
                    </Button>
                  )}
                </div>
                {claiming === m.venueId && (
                  <div className="mt-3 space-y-2">
                    <Input aria-label="Message to our team" placeholder="Anything that helps us confirm you run this venue (optional)" value={message} onChange={(e) => setMessage(e.target.value)} maxLength={500} />
                    <p className="text-xs text-gray-500">Our team reviews every request. A venue is never transferred automatically.</p>
                    <Button size="sm" className="bg-gradient-orange font-bold text-black hover:opacity-90" onClick={() => void claim(m.venueId)}>Send request</Button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>

      <form onSubmit={create} className="space-y-3">
        <h3 className="text-sm font-medium text-gray-300">Not listed? Add a new venue</h3>
        <div className="flex gap-2">
          <Input aria-label="New venue name" placeholder="Venue name" value={newName} onChange={(e) => setNewName(e.target.value)} maxLength={120} />
          <Button type="submit" disabled={creating || !newName.trim()} className="bg-gradient-orange font-bold text-black hover:opacity-90">
            {creating ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Add venue'}
          </Button>
        </div>
        <p className="text-xs text-gray-500">Search first so a venue is not listed twice.</p>
      </form>
    </div>
  );
};

export default VenueStep;
