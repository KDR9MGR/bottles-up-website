import { useState } from 'react';
import { Loader2, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { addVenueTimeSlot, listVenueTimeSlots, removeVenueTimeSlot } from '@/lib/venueSetupApi';
import {
  DAY_LABELS, DAY_ORDER, DAY_SHORT, formatSlotTime, groupSlotsByDay, summarizeSlotAttempts, validateSlotForm,
  type SlotAttempt, type TimeSlot,
} from '@/lib/venueSetupForms';
import { errorMessage, useLoad } from './useLoad';

interface Props {
  venueId: string;
  onChanged: () => void;
}

/**
 * The days and arrival times a venue accepts bookings. Guests choose among these when they book a table. Several days can
 * be added at once; one that already exists is skipped and said so.
 */
const BookingTimesEditor = ({ venueId, onChanged }: Props) => {
  const { toast } = useToast();
  const { data: slots, error, reload } = useLoad(() => listVenueTimeSlots(venueId), venueId);
  const [days, setDays] = useState<number[]>([]);
  const [time, setTime] = useState('21:00');
  const [label, setLabel] = useState('');
  const [busy, setBusy] = useState(false);
  const [problems, setProblems] = useState<string[]>([]);

  const toggleDay = (day: number, on: boolean) => setDays((d) => (on ? [...new Set([...d, day])] : d.filter((x) => x !== day)));

  const add = async (e: React.FormEvent) => {
    e.preventDefault();
    const found = validateSlotForm({ days, time, label });
    setProblems(found);
    if (found.length > 0) return;
    setBusy(true);
    const attempts: SlotAttempt[] = [];
    for (const day of [...days].sort((a, b) => a - b)) {
      try {
        await addVenueTimeSlot(venueId, day, time, label);
        attempts.push({ day, error: null });
      } catch (err) {
        attempts.push({ day, error: errorMessage(err) });
      }
    }
    const summary = summarizeSlotAttempts(attempts);
    toast({ title: summary.title, description: summary.description, variant: summary.failed ? 'destructive' : undefined });
    setBusy(false);
    if (attempts.some((a) => a.error === null)) {
      setDays([]);
      setLabel('');
      await reload();
      onChanged();
    }
  };

  const remove = async (slot: TimeSlot) => {
    try {
      await removeVenueTimeSlot(venueId, slot.slotId);
      await reload();
      onChanged();
    } catch (err) {
      toast({ title: 'Could not remove that time', description: errorMessage(err), variant: 'destructive' });
    }
  };

  if (error) return <p className="text-sm text-red-300" role="alert">{error}</p>;
  if (!slots) return <p className="text-sm text-gray-500">Loading arrival times…</p>;

  return (
    <div className="space-y-6">
      <p className="text-sm text-gray-400">
        The days and times guests can choose to arrive for a table. A venue that takes bookings on Friday and Saturday at 9 PM and 11 PM adds those four.
      </p>

      <ul className="divide-y divide-gray-800 rounded-xl border border-gray-800">
        {groupSlotsByDay(slots).map((g) => (
          <li key={g.day} className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
            <span className="w-24 shrink-0 text-sm text-gray-300">{g.label}</span>
            {g.slots.length === 0 && <span className="text-sm text-gray-600">No bookings accepted</span>}
            {g.slots.map((s) => (
              <span key={s.slotId} className="inline-flex items-center gap-1 rounded-full border border-gray-700 bg-black/40 py-1 pl-3 pr-1 text-sm text-white">
                {formatSlotTime(s.startTime)}
                {s.label && <span className="text-xs text-gray-400">· {s.label}</span>}
                <button
                  type="button"
                  onClick={() => void remove(s)}
                  disabled={s.bookingCount > 0}
                  title={s.bookingCount > 0 ? `${s.bookingCount} ${s.bookingCount === 1 ? 'booking uses' : 'bookings use'} this time, so it cannot be removed` : 'Remove'}
                  aria-label={`Remove ${formatSlotTime(s.startTime)} on ${DAY_LABELS[s.dayOfWeek]}`}
                  className="rounded-full p-1 text-gray-400 hover:bg-white/10 hover:text-white disabled:cursor-not-allowed disabled:opacity-30"
                >
                  <X className="h-3.5 w-3.5" />
                </button>
              </span>
            ))}
          </li>
        ))}
      </ul>

      <form onSubmit={add} className="space-y-4 rounded-xl border border-gray-800 bg-black/30 p-4" noValidate>
        <h4 className="text-sm font-medium text-white">Add arrival times</h4>
        <fieldset>
          <legend className="mb-2 text-sm text-gray-300">Days</legend>
          <div className="flex flex-wrap gap-x-4 gap-y-2">
            {DAY_ORDER.map((d) => (
              <label key={d} className="flex cursor-pointer items-center gap-2 text-sm text-gray-200">
                <Checkbox checked={days.includes(d)} onCheckedChange={(c) => toggleDay(d, c === true)} aria-label={DAY_LABELS[d]} />
                {DAY_SHORT[d]}
              </label>
            ))}
          </div>
        </fieldset>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor={`slot-time-${venueId}`} className="text-gray-300">Arrival time</Label>
            <Input id={`slot-time-${venueId}`} type="time" value={time} onChange={(e) => setTime(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label htmlFor={`slot-label-${venueId}`} className="text-gray-300">Note (optional)</Label>
            <Input id={`slot-label-${venueId}`} value={label} onChange={(e) => setLabel(e.target.value)} maxLength={60} placeholder="Early seating" />
          </div>
        </div>
        {problems.length > 0 && (
          <ul className="space-y-1 text-sm text-red-300" role="alert">
            {problems.map((p) => <li key={p}>{p}</li>)}
          </ul>
        )}
        <Button type="submit" disabled={busy} className="bg-gradient-orange font-bold text-black hover:opacity-90">
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Add arrival time'}
        </Button>
      </form>
    </div>
  );
};

export default BookingTimesEditor;
