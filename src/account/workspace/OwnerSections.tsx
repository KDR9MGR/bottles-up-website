import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { fetchOrgVenues } from '@/lib/account';
import { onboardingPath, type Business, type Workspace } from '@/lib/accountRouting';
import { workspacePath } from '@/lib/roleNavigation';
import { stateInfo } from '@/lib/verification';
import { supabase } from '@/lib/supabase';
import StateBadge from '../components/StateBadge';
import VenueCard from './VenueCard';
import VenueProfileForm, { type VenueProfile } from './VenueProfileForm';

interface Props {
  workspace: Workspace;
  business: Business | undefined;
}

/** The business's verification state with a direct action, shown above every owner or organizer screen. */
export const VerificationBanner = ({ workspace, business }: Props) => {
  if (!business) return null;
  const info = stateInfo(business.verificationState);
  if (business.verificationState === 'verified') return null;
  return (
    <div className="mb-6 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-gray-800 bg-gray-900/50 p-4">
      <div className="flex min-w-0 flex-wrap items-center gap-3">
        <StateBadge state={business.verificationState} />
        <p className="text-sm text-gray-300">{info.summary}</p>
      </div>
      <Link to={onboardingPath(workspace.orgId)} className="text-sm font-medium text-primary hover:underline">
        {business.verificationState === 'under_review' ? 'See progress' : 'Open business details'}
      </Link>
    </div>
  );
};

type VenueRow = { venueId: string; name: string; status: string };

function useOrgVenues(orgId: string) {
  const [venues, setVenues] = useState<VenueRow[] | null>(null);
  const load = useCallback(async () => {
    try {
      setVenues(await fetchOrgVenues(orgId));
    } catch {
      setVenues([]);
    }
  }, [orgId]);
  useEffect(() => { void load(); }, [load]);
  return { venues, reload: load };
}

/** Owner Overview: how each venue is set up, and what still needs attention. */
export const OwnerOverview = ({ workspace, business }: Props) => {
  const { venues } = useOrgVenues(workspace.orgId);
  const state = business?.verificationState ?? 'not_submitted';
  const venuesPath = workspacePath(workspace.membershipId, 'venues');

  return (
    <div>
      <VerificationBanner workspace={workspace} business={business} />
      {venues === null && <p className="text-sm text-gray-500">Loading your venues…</p>}
      {venues?.length === 0 && (
        <div className="rounded-2xl border border-dashed border-gray-800 p-8 text-center">
          <p className="text-white">No venues yet</p>
          <p className="mt-1 text-sm text-gray-400">Add a venue, or ask to claim one that is already on BottlesUp.</p>
          <Link to={onboardingPath(workspace.orgId)} className="mt-4 inline-block text-sm font-medium text-primary hover:underline">Add or claim a venue</Link>
        </div>
      )}
      {venues && venues.length > 0 && (
        <>
          <h2 className="mb-3 text-sm font-medium uppercase tracking-wide text-gray-500">{venues.length === 1 ? 'Your venue' : `All venues (${venues.length})`}</h2>
          <div className="grid gap-4 lg:grid-cols-2">
            {venues.map((v) => (
              <VenueCard key={v.venueId} orgId={workspace.orgId} venueId={v.venueId} name={v.name} status={v.status} businessState={state} setupPath={venuesPath} detailed={venues.length === 1}>
                <Link to={`${venuesPath}#venue-${v.venueId}`} className="mt-4 inline-block text-sm font-medium text-primary hover:underline">Manage venue</Link>
              </VenueCard>
            ))}
          </div>
        </>
      )}
    </div>
  );
};

/** My Venues: every club with its full checklist and an editable public profile. */
export const OwnerVenues = ({ workspace, business }: Props) => {
  const { venues, reload } = useOrgVenues(workspace.orgId);
  const [profiles, setProfiles] = useState<Record<string, VenueProfile>>({});
  const state = business?.verificationState ?? 'not_submitted';
  const venuesPath = workspacePath(workspace.membershipId, 'venues');

  const loadProfiles = useCallback(async () => {
    if (!venues || venues.length === 0) return;
    const { data } = await supabase
      .from('site_venues')
      .select('id, name, description, address, cover_image_url')
      .in('id', venues.map((v) => v.venueId));
    const map: Record<string, VenueProfile> = {};
    for (const row of data ?? []) map[row.id] = row as VenueProfile;
    setProfiles(map);
  }, [venues]);

  useEffect(() => { void loadProfiles(); }, [loadProfiles]);

  return (
    <div>
      <VerificationBanner workspace={workspace} business={business} />
      {venues === null && <p className="text-sm text-gray-500">Loading your venues…</p>}
      {venues?.length === 0 && <p className="text-sm text-gray-400">You have no venues yet. <Link to={onboardingPath(workspace.orgId)} className="text-primary hover:underline">Add or claim one</Link>.</p>}
      <div className="space-y-5">
        {venues?.map((v) => (
          <VenueCard key={`${v.venueId}-${profiles[v.venueId]?.name ?? ''}`} orgId={workspace.orgId} venueId={v.venueId} name={profiles[v.venueId]?.name ?? v.name} status={v.status} businessState={state} setupPath={venuesPath} detailed>
            {profiles[v.venueId] && (
              <VenueProfileForm orgId={workspace.orgId} venue={profiles[v.venueId]} onSaved={() => { void reload(); void loadProfiles(); }} />
            )}
          </VenueCard>
        ))}
      </div>
      <p className="mt-6 text-xs text-gray-500">
        Floor plans, tables, bottle menus and booking rules are managed with the BottlesUp team for now; editing them here is coming.
      </p>
    </div>
  );
};
