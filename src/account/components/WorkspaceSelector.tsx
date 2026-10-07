import { Link, useNavigate } from 'react-router-dom';
import { Briefcase, ChevronRight, ShieldCheck, User, Users } from 'lucide-react';
import { rememberWorkspace, useAccount } from '@/hooks/useAccount';
import { buildDestinations, type Attention, type Destination } from '@/lib/accountRouting';
import AccountShell from './AccountShell';

const ATTENTION_LABEL: Record<Attention, string> = {
  finish_setup: 'Finish setup',
  more_information: 'More information needed',
  under_review: 'Under review',
};
const ATTENTION_CLASS: Record<Attention, string> = {
  finish_setup: 'border-amber-500/40 bg-amber-500/10 text-amber-300',
  more_information: 'border-amber-500/40 bg-amber-500/10 text-amber-300',
  under_review: 'border-blue-500/40 bg-blue-500/10 text-blue-300',
};

const ICON: Record<Destination['kind'], typeof User> = {
  personal: User,
  workspace: Briefcase,
  cms: ShieldCheck,
  'legacy-staff': Users,
};

/**
 * "Several businesses or roles -> workspace selector". Role switching is always explicit: nothing
 * here changes your access, it only lists what the database says you currently hold.
 */
const WorkspaceSelector = ({ destinations }: { destinations?: Destination[] }) => {
  const { snapshot } = useAccount();
  const navigate = useNavigate();
  const items = destinations ?? buildDestinations(snapshot);

  const open = (d: Destination) => {
    rememberWorkspace(d.key);
    navigate(d.path);
  };

  return (
    <AccountShell title="Choose a workspace" subtitle="You can switch at any time from the menu at the top of a workspace.">
      <ul className="space-y-3">
        {items.map((d) => {
          const Icon = ICON[d.kind];
          return (
            <li key={d.key}>
              <button
                type="button"
                onClick={() => open(d)}
                className="group flex w-full items-center gap-4 rounded-xl border border-gray-800 bg-black/40 p-4 text-left transition-colors hover:border-primary/60"
              >
                <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
                  <Icon className="h-5 w-5" />
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate font-medium text-white">{d.title}</span>
                  <span className="block truncate text-sm text-gray-400">{d.subtitle}</span>
                  {d.attention && (
                    <span className={`mt-1 inline-flex rounded-full border px-2 py-0.5 text-xs ${ATTENTION_CLASS[d.attention]}`}>
                      {ATTENTION_LABEL[d.attention]}
                    </span>
                  )}
                </span>
                <ChevronRight className="h-5 w-5 text-gray-600 transition-colors group-hover:text-primary" />
              </button>
            </li>
          );
        })}
      </ul>
      <p className="mt-6 text-center text-xs text-gray-500">
        Running another business?{' '}
        <Link to="/business/new" className="text-primary hover:underline">Add a business to this account</Link>
      </p>
    </AccountShell>
  );
};

export default WorkspaceSelector;
