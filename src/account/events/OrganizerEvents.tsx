import { useCallback, useEffect, useState } from 'react';
import { Plus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useToast } from '@/hooks/use-toast';
import { AccountError } from '@/lib/account';
import type { Workspace } from '@/lib/accountRouting';
import { sentence, type OrgEvent } from '@/lib/organizerEvents';
import { listOrgEvents, removeOrgEvent } from '@/lib/organizerEventsApi';
import ConfirmRemove from '../setup/ConfirmRemove';
import EventsList from './EventsList';
import OrganizerEventDialog from './OrganizerEventDialog';

const failureText = (err: unknown) => sentence(err instanceof AccountError ? err.message : 'Check your connection and try again.');

/**
 * The organizer's My Events: create an event, change or remove a draft, and see what is published. The database decides what
 * this person may do; nothing here grants access.
 */
const OrganizerEvents = ({ workspace }: { workspace: Workspace }) => {
  const orgId = workspace.orgId;
  const { toast } = useToast();
  const [events, setEvents] = useState<OrgEvent[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [editing, setEditing] = useState<{ event: OrgEvent | null } | null>(null);
  const [removing, setRemoving] = useState<OrgEvent | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setEvents(await listOrgEvents(orgId));
      setLoadError(null);
    } catch (err) {
      setLoadError(failureText(err));
    }
  }, [orgId]);

  useEffect(() => { void load(); }, [load]);

  const remove = async () => {
    if (!removing) return;
    setBusy(true);
    try {
      await removeOrgEvent(orgId, removing.eventId);
      toast({ title: 'Event removed', description: `${removing.title} was deleted.` });
      setRemoving(null);
      await load();
    } catch (err) {
      toast({ title: 'Could not remove the event', description: failureText(err), variant: 'destructive' });
      setRemoving(null);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-xl text-sm text-gray-400">Create your events here. They stay private drafts until the BottlesUp team publishes them and sets up tickets with you.</p>
        <Button type="button" onClick={() => setEditing({ event: null })} className="bg-gradient-orange font-bold text-black hover:opacity-90">
          <Plus className="mr-1 h-4 w-4" />Create event
        </Button>
      </div>

      {loadError && (
        <div role="alert" className="rounded-xl border border-red-900/60 bg-red-950/20 p-4 text-sm text-red-200">
          We could not load your events. {loadError}{' '}
          <button type="button" onClick={() => void load()} className="underline">Try again</button>
        </div>
      )}
      {!loadError && events === null && <p className="text-sm text-gray-500">Getting your events…</p>}
      {events && (
        <EventsList events={events} now={new Date()} onCreate={() => setEditing({ event: null })} onEdit={(e) => setEditing({ event: e })} onRemove={setRemoving} />
      )}

      <OrganizerEventDialog
        open={editing !== null}
        orgId={orgId}
        event={editing?.event ?? null}
        onClose={() => setEditing(null)}
        onSaved={(created) => {
          setEditing(null);
          toast({ title: created ? 'Draft created' : 'Draft saved', description: 'It stays private until the BottlesUp team publishes it.' });
          void load();
        }}
      />
      <ConfirmRemove
        open={removing !== null}
        busy={busy}
        title={`Remove ${removing?.title ?? 'this event'}?`}
        description="The draft is deleted. This cannot be undone."
        onConfirm={() => void remove()}
        onClose={() => setRemoving(null)}
      />
    </div>
  );
};

export default OrganizerEvents;
