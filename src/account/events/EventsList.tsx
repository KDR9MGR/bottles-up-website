import { CalendarDays, MapPin, Users } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { formatEventWhen, groupEvents, STATUS_LABEL, statusNote, type OrgEvent } from '@/lib/organizerEvents';

interface Props {
  events: OrgEvent[];
  now: Date;
  onCreate: () => void;
  onEdit: (event: OrgEvent) => void;
  onRemove: (event: OrgEvent) => void;
  /** Fixed in tests; otherwise the device's own zone is used. */
  timeZone?: string;
}

const BADGE: Record<OrgEvent['status'], string> = {
  draft: 'border-amber-500/40 bg-amber-500/10 text-amber-300',
  published: 'border-green-500/40 bg-green-500/10 text-green-300',
};

const Card = ({ event, timeZone, onEdit, onRemove }: { event: OrgEvent; timeZone?: string; onEdit: Props['onEdit']; onRemove: Props['onRemove'] }) => (
  <li data-testid={`event-${event.eventId}`} className="flex gap-4 rounded-xl border border-gray-800 bg-gray-900/50 p-4">
    {event.coverImageUrl && <img src={event.coverImageUrl} alt="" className="hidden h-20 w-20 shrink-0 rounded-lg border border-gray-800 object-cover sm:block" />}
    <div className="min-w-0 flex-1">
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="truncate text-base font-semibold text-white">{event.title}</h3>
        <span className={`rounded-full border px-2 py-0.5 text-xs ${BADGE[event.status]}`}>{STATUS_LABEL[event.status]}</span>
      </div>
      <p className="mt-1 flex items-center gap-2 text-sm text-gray-300"><CalendarDays className="h-4 w-4 shrink-0 text-gray-500" />{formatEventWhen(event.startDate, event.endDate, timeZone)}</p>
      <p className="mt-0.5 flex items-center gap-2 text-sm text-gray-400"><MapPin className="h-4 w-4 shrink-0 text-gray-500" /><span className="truncate">{event.address ? `${event.venueName}, ${event.address}` : event.venueName}</span></p>
      {event.capacity !== null && <p className="mt-0.5 flex items-center gap-2 text-sm text-gray-400"><Users className="h-4 w-4 shrink-0 text-gray-500" />{`Capacity ${event.capacity}`}</p>}
      <p className="mt-2 text-xs text-gray-500">{statusNote(event.status)}</p>
      {event.status === 'draft' && (
        <div className="mt-3 flex gap-2">
          <Button type="button" size="sm" variant="outline" onClick={() => onEdit(event)}>Edit</Button>
          <Button type="button" size="sm" variant="ghost" className="text-red-300 hover:text-red-200" onClick={() => onRemove(event)}>Remove</Button>
        </div>
      )}
    </div>
  </li>
);

const Group = ({ title, events, ...rest }: { title: string; events: OrgEvent[]; timeZone?: string; onEdit: Props['onEdit']; onRemove: Props['onRemove'] }) =>
  events.length === 0 ? null : (
    <section aria-label={title} className="mt-8 first:mt-0">
      <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-gray-400">{title}</h2>
      <ul className="space-y-3">{events.map((e) => <Card key={e.eventId} event={e} {...rest} />)}</ul>
    </section>
  );

/** The organizer's events: drafts first, then what is coming up, then what has happened. Only a draft can be changed or removed. */
const EventsList = ({ events, now, onCreate, onEdit, onRemove, timeZone }: Props) => {
  if (events.length === 0) {
    return (
      <div data-testid="no-events" className="rounded-2xl border border-dashed border-gray-800 bg-gray-900/30 p-8 text-center">
        <CalendarDays className="mx-auto mb-3 h-8 w-8 text-gray-500" />
        <h2 className="text-lg font-semibold text-white">No events yet</h2>
        <p className="mx-auto mt-2 max-w-md text-sm text-gray-400">Create your first event. It stays a private draft until the BottlesUp team publishes it.</p>
        <Button type="button" onClick={onCreate} className="mt-5 bg-gradient-orange font-bold text-black hover:opacity-90">Create event</Button>
      </div>
    );
  }
  const g = groupEvents(events, now);
  return (
    <div>
      <Group title="Drafts" events={g.drafts} timeZone={timeZone} onEdit={onEdit} onRemove={onRemove} />
      <Group title="Upcoming" events={g.upcoming} timeZone={timeZone} onEdit={onEdit} onRemove={onRemove} />
      <Group title="Past" events={g.past} timeZone={timeZone} onEdit={onEdit} onRemove={onRemove} />
    </div>
  );
};

export default EventsList;
