import { useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { EMPTY_EVENT_FORM, eventFormFrom, type EventForm, type OrgEvent } from '@/lib/organizerEvents';
import { saveOrgEvent } from '@/lib/organizerEventsApi';
import { submitEventForm } from '@/lib/organizerEventsFlow';
import EventFields from './EventFields';

interface Props {
  open: boolean;
  orgId: string;
  /** The draft being changed; null adds a new one. */
  event: OrgEvent | null;
  onClose: () => void;
  /** Called once it is saved, with whether it was a new event. */
  onSaved: (created: boolean) => void;
}

const deviceZone = () => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'local time';
  } catch {
    return 'local time';
  }
};

/**
 * Create or change a draft. Every problem is said before anything is sent; a refusal from the database is shown here, in the
 * form, so nothing typed is lost.
 */
const OrganizerEventDialog = ({ open, orgId, event, onClose, onSaved }: Props) => {
  const [form, setForm] = useState<EventForm>(EMPTY_EVENT_FORM);
  const [problems, setProblems] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setForm(event ? eventFormFrom(event) : EMPTY_EVENT_FORM);
    setProblems([]);
    setSaving(false);
  }, [open, event]);

  const save = async () => {
    if (saving) return;
    setSaving(true);
    const result = await submitEventForm(form, orgId, event?.eventId ?? null, saveOrgEvent);
    if (result.ok) {
      onSaved(event === null);
      return;
    }
    setProblems(result.problems);
    setSaving(false);
  };

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o && !saving) onClose(); }}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{event ? `Edit ${event.title}` : 'Create event'}</DialogTitle>
          <DialogDescription>It is saved as a private draft. The BottlesUp team publishes it and sets up tickets with you.</DialogDescription>
        </DialogHeader>
        <EventFields form={form} orgId={orgId} onChange={(patch) => setForm((f) => ({ ...f, ...patch }))} problems={problems} timeZone={deviceZone()} />
        <DialogFooter>
          <Button type="button" variant="ghost" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button type="button" onClick={() => void save()} disabled={saving} className="bg-gradient-orange font-bold text-black hover:opacity-90">
            {saving ? <Loader2 className="h-4 w-4 animate-spin" aria-label="Saving" /> : event ? 'Save draft' : 'Create draft'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default OrganizerEventDialog;
