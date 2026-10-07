import { useEffect, useState } from 'react';
import { Link, NavLink, Navigate, useNavigate, useParams } from 'react-router-dom';
import { Check, ChevronDown, LogOut } from 'lucide-react';
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { rememberWorkspace, useAccount } from '@/hooks/useAccount';
import { buildDestinations, type Workspace } from '@/lib/accountRouting';
import { ROLE_LABEL, sectionLabel, sectionsFor, workspacePath } from '@/lib/roleNavigation';
import { resolveWorkspaceView } from '@/lib/workspaceAccess';
import { supabase } from '@/lib/supabase';
import { contextFor, nightLabel } from '@/lib/workspaceContext';
import AccountShell from '../components/AccountShell';
import { FullPageSpinner } from '../pages/Home';
import ComingSoon from './ComingSoon';
import TeamSection from '../team/TeamSection';
import DoorGuests from '../door/DoorGuests';
import DoorScanner from '../door/DoorScanner';
import BookingLinkSection from './BookingLinkSection';
import BookingsSection from './BookingsSection';
import { OwnerOverview, OwnerVenues, VerificationBanner } from './OwnerSections';
import { sectionDescription } from './sectionInfo';

// Operational access can end while a tab stays open (a shift ends, a role is revoked). Re-reading what the
// person holds every minute, and when the tab comes back, closes the dashboard soon after instead of never.
const RECHECK_MS = 60_000;

const ContextBar = ({ workspace }: { workspace: Workspace }) => {
  const c = contextFor(workspace);
  const parts = [c.business, c.venue, c.event, c.shift].filter((p): p is string => !!p);
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-0.5 text-sm">
      <span className="truncate font-medium text-white">{parts.join(' · ')}</span>
      <span className="text-gray-500">{nightLabel(new Date())}</span>
    </div>
  );
};

const Switcher = ({ currentKey }: { currentKey: string }) => {
  const { snapshot } = useAccount();
  const navigate = useNavigate();
  const items = buildDestinations(snapshot);
  const current = items.find((d) => d.key === currentKey);
  return (
    <DropdownMenu>
      <DropdownMenuTrigger className="inline-flex items-center gap-1.5 rounded-full border border-gray-700 px-3 py-1.5 text-sm text-gray-200 hover:bg-white/5">
        <span className="max-w-[10rem] truncate">{current?.subtitle.split(' · ')[0] ?? 'Workspace'}</span>
        <ChevronDown className="h-4 w-4" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-64 border-white/10 bg-zinc-950 text-white">
        <DropdownMenuLabel className="text-xs font-normal text-gray-400">Switch workspace</DropdownMenuLabel>
        {items.map((d) => (
          <DropdownMenuItem key={d.key} className="cursor-pointer gap-2" onClick={() => { rememberWorkspace(d.key); navigate(d.path); }}>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm">{d.title}</span>
              <span className="block truncate text-xs text-gray-400">{d.subtitle}</span>
            </span>
            {d.key === currentKey && <Check className="h-4 w-4 text-primary" />}
          </DropdownMenuItem>
        ))}
        <DropdownMenuSeparator className="bg-white/10" />
        <DropdownMenuItem className="cursor-pointer" onClick={() => navigate('/workspaces')}>All workspaces</DropdownMenuItem>
        <DropdownMenuItem className="cursor-pointer gap-2 text-red-400" onClick={async () => { await supabase.auth.signOut(); navigate('/'); }}>
          <LogOut className="h-4 w-4" /> Sign out
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
};

/**
 * `/w/:membershipId/:section`. The role's own navigation, always showing the current business, venue, event
 * and night. Only a workspace the database currently lists for this person opens; a revoked or expired one
 * gets an explicit "no access" page, never an operational screen.
 */
const WorkspacePage = () => {
  const { membershipId = '', section } = useParams();
  const { loading, snapshot, refresh } = useAccount();
  const [, setTick] = useState(0);

  const view = resolveWorkspaceView(snapshot, membershipId, section);
  const ws = view.kind === 'show' ? view.workspace : undefined;

  useEffect(() => {
    if (ws) rememberWorkspace(ws.membershipId);
  }, [ws]);

  useEffect(() => {
    if (!snapshot.signedIn) return;
    const recheck = () => { void refresh(); setTick((t) => t + 1); };
    const timer = window.setInterval(recheck, RECHECK_MS);
    const onVisible = () => { if (document.visibilityState === 'visible') recheck(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [snapshot.signedIn, refresh]);

  if (loading) return <FullPageSpinner />;
  if (view.kind === 'signed_out') {
    return <Navigate to={`/login?next=${encodeURIComponent(`/w/${membershipId}/${section ?? ''}`)}`} replace />;
  }
  if (view.kind === 'no_access') {
    return (
      <AccountShell title="You no longer have access to this workspace" subtitle="Your access may have ended, or the link may be for someone else." backTo="/home" backLabel="Back">
        <Link to="/home" className="text-sm font-medium text-primary hover:underline">Go to my workspaces</Link>
      </AccountShell>
    );
  }
  if (view.kind === 'redirect') return <Navigate to={view.to} replace />;

  const { workspace: current, section: activeSection } = view;
  const business = snapshot.businesses.find((b) => b.orgId === current.orgId);
  const nav = sectionsFor(current.role);
  const title = sectionLabel(current.role, activeSection) ?? activeSection;

  let content: React.ReactNode;
  if (current.role === 'owner' && activeSection === 'overview') content = <OwnerOverview workspace={current} business={business} />;
  else if (current.role === 'owner' && activeSection === 'venues') content = <OwnerVenues workspace={current} business={business} />;
  else if ((current.role === 'owner' && activeSection === 'tables') || (current.role === 'manager' && activeSection === 'floor')) {
    // The verification banner is about the business, which only its owner can act on.
    content = <BookingsSection workspace={current} business={current.role === 'owner' ? business : undefined} />;
  }
  else if (current.role === 'owner' && activeSection === 'booking-link') content = <BookingLinkSection workspace={current} business={business} />;
  else if (current.role === 'door' && activeSection === 'scan') content = <DoorScanner workspace={current} />;
  else if (current.role === 'door' && activeSection === 'guests') content = <DoorGuests workspace={current} />;
  else if ((current.role === 'owner' || current.role === 'manager') && activeSection === 'team') {
    content = (
      <>
        {current.role === 'owner' && <VerificationBanner workspace={current} business={business} />}
        <TeamSection workspace={current} />
      </>
    );
  }
  else if (current.role === 'organizer' && activeSection === 'home') {
    content = (
      <>
        <VerificationBanner workspace={current} business={business} />
        <ComingSoon title="My Events" description={sectionDescription(current.role, activeSection)} />
      </>
    );
  } else {
    content = (
      <>
        {(current.role === 'owner' || current.role === 'organizer') && <VerificationBanner workspace={current} business={business} />}
        <ComingSoon title={title} description={sectionDescription(current.role, activeSection)} />
      </>
    );
  }

  return (
    <div className="min-h-screen bg-black text-white">
      <header className="sticky top-0 z-20 border-b border-white/10 bg-black/90 backdrop-blur">
        <div className="flex items-center justify-between gap-4 px-4 py-3 lg:px-6">
          <div className="flex min-w-0 items-center gap-4">
            <Link to="/" className="flex shrink-0 items-center gap-2" aria-label="BottlesUp home">
              <img src="/app_logo.svg" alt="" className="h-7 w-7" />
            </Link>
            <ContextBar workspace={current} />
          </div>
          <div className="flex shrink-0 items-center gap-3">
            <span className="hidden text-xs text-gray-500 sm:inline">{ROLE_LABEL[current.role]}</span>
            <Switcher currentKey={current.membershipId} />
          </div>
        </div>
        {/* Phones and tablets: the role's navigation as a scrollable row. */}
        <nav aria-label="Workspace sections" className="flex gap-1 overflow-x-auto px-3 pb-2 md:hidden">
          {nav.map((s) => (
            <NavLink
              key={s.id}
              to={workspacePath(current.membershipId, s.id)}
              className={({ isActive }) => `whitespace-nowrap rounded-full px-3 py-1.5 text-sm ${isActive ? 'bg-primary/15 text-primary' : 'text-gray-400 hover:text-white'}`}
            >
              {s.label}
            </NavLink>
          ))}
        </nav>
      </header>

      <div className="md:flex">
        {/* Desktop: the same navigation as a sidebar. */}
        <nav aria-label="Workspace sections" className="hidden w-60 shrink-0 border-r border-white/10 p-3 md:block">
          <ul className="space-y-0.5">
            {nav.map((s) => (
              <li key={s.id}>
                <NavLink
                  to={workspacePath(current.membershipId, s.id)}
                  className={({ isActive }) => `block rounded-lg px-3 py-2 text-sm ${isActive ? 'bg-primary/15 font-medium text-primary' : 'text-gray-400 hover:bg-white/5 hover:text-white'}`}
                >
                  {s.label}
                </NavLink>
              </li>
            ))}
          </ul>
        </nav>
        <main className="min-w-0 flex-1 p-4 lg:p-8">
          <h1 className="mb-6 text-2xl font-bold">{title}</h1>
          {content}
        </main>
      </div>
    </div>
  );
};

export default WorkspacePage;
