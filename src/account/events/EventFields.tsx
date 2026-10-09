import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { EVENT_LIMITS, type EventForm } from '@/lib/organizerEvents';
import ImageField from '../setup/ImageField';

interface Props {
  form: EventForm;
  orgId: string;
  onChange: (patch: Partial<EventForm>) => void;
  /** What is wrong with the form, in plain words. */
  problems: string[];
  /** The zone the times are read in, shown so nobody has to wonder. */
  timeZone: string;
}

/** The boxes of the event form. State lives in the dialog around it; this only shows and reports. */
const EventFields = ({ form, orgId, onChange, problems, timeZone }: Props) => (
  <div className="space-y-4">
    <div className="space-y-2">
      <Label htmlFor="ev-title" className="text-gray-300">Title</Label>
      <Input id="ev-title" value={form.title} onChange={(e) => onChange({ title: e.target.value })} maxLength={EVENT_LIMITS.title + 20} placeholder="Rooftop Sessions" />
    </div>
    <div className="space-y-2">
      <Label htmlFor="ev-description" className="text-gray-300">Description</Label>
      <Textarea id="ev-description" value={form.description} onChange={(e) => onChange({ description: e.target.value })} rows={4} placeholder="What guests can expect: music, dress code, anything they should know." />
    </div>
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
      <div className="space-y-2">
        <Label htmlFor="ev-venue" className="text-gray-300">Venue or place name</Label>
        <Input id="ev-venue" value={form.venueName} onChange={(e) => onChange({ venueName: e.target.value })} placeholder="The Roof" />
      </div>
      <div className="space-y-2">
        <Label htmlFor="ev-address" className="text-gray-300">Address <span className="text-gray-500">(optional)</span></Label>
        <Input id="ev-address" value={form.address} onChange={(e) => onChange({ address: e.target.value })} placeholder="1 King St W, Toronto" />
      </div>
    </div>
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
      <div className="space-y-2">
        <Label htmlFor="ev-start" className="text-gray-300">Starts</Label>
        <Input id="ev-start" type="datetime-local" value={form.startsAt} onChange={(e) => onChange({ startsAt: e.target.value })} />
      </div>
      <div className="space-y-2">
        <Label htmlFor="ev-end" className="text-gray-300">Ends <span className="text-gray-500">(optional)</span></Label>
        <Input id="ev-end" type="datetime-local" value={form.endsAt} onChange={(e) => onChange({ endsAt: e.target.value })} />
      </div>
    </div>
    <p className="-mt-2 text-xs text-gray-500">Times are in your device's time zone ({timeZone}).</p>
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
      <div className="space-y-2">
        <Label htmlFor="ev-category" className="text-gray-300">Category <span className="text-gray-500">(optional)</span></Label>
        <Input id="ev-category" value={form.category} onChange={(e) => onChange({ category: e.target.value })} placeholder="Club night" />
      </div>
      <div className="space-y-2">
        <Label htmlFor="ev-capacity" className="text-gray-300">Capacity <span className="text-gray-500">(optional)</span></Label>
        <Input id="ev-capacity" inputMode="numeric" value={form.capacity} onChange={(e) => onChange({ capacity: e.target.value })} placeholder="250" />
      </div>
    </div>
    <ImageField id="ev-cover" label="Cover photo (optional)" orgId={orgId} value={form.coverImageUrl} onChange={(url) => onChange({ coverImageUrl: url })} wide hint="JPEG, PNG or WebP, up to 5 MB." />
    {problems.length > 0 && (
      <ul role="alert" data-testid="event-problems" className="space-y-1 rounded-lg border border-red-900/60 bg-red-950/20 p-3 text-sm text-red-200">
        {problems.map((p) => <li key={p}>{p}</li>)}
      </ul>
    )}
  </div>
);

export default EventFields;
