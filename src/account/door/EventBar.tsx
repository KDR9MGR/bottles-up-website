import NativeSelect from '../components/NativeSelect';
import { admittedPercent, admittedSummary, type DoorEvent } from '@/lib/doorScan';

/** Which event is being worked, and how many guests are in. A picker only appears when there is a choice. */
const EventBar = ({ events, selected, onSelect }: { events: DoorEvent[]; selected: DoorEvent; onSelect: (id: string) => void }) => (
  <div className="mb-5 rounded-xl border border-gray-800 bg-gray-900/50 p-4">
    {events.length > 1 ? (
      <NativeSelect aria-label="Event" value={selected.eventId} onChange={(e) => onSelect(e.target.value)} className="mb-3">
        {events.map((e) => <option key={e.eventId} value={e.eventId}>{e.title}</option>)}
      </NativeSelect>
    ) : (
      <p className="mb-1 font-medium text-white">{selected.title}</p>
    )}
    <div className="flex justify-between text-xs text-gray-400">
      <span>{selected.venueName}</span>
      <span aria-live="polite">{admittedSummary(selected)}</span>
    </div>
    <div
      className="mt-2 h-2 overflow-hidden rounded-full bg-gray-800"
      role="progressbar"
      aria-valuenow={admittedPercent(selected)}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label="Guests admitted"
    >
      <div className="h-full rounded-full bg-gradient-orange transition-all" style={{ width: `${admittedPercent(selected)}%` }} />
    </div>
  </div>
);

export default EventBar;
