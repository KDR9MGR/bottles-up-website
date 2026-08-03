import { useEffect, useMemo, useState } from 'react';
import { format, startOfDay } from 'date-fns';
import { Users, Wine, Crown, CalendarDays } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Calendar } from '@/components/ui/calendar';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];
type FloorRow = Database['public']['Tables']['site_venue_floors']['Row'];

interface VenueFloorPlanPickerProps {
  venue: VenueRow;
  floors: FloorRow[];
  tableTypes: TableTypeRow[];
  timeSlots: TimeSlotRow[];
  onSelectTable: (tableType: TableTypeRow, date: Date, slotId: string) => void;
}

const formatTimeSlot = (startTime: string) => {
  const [h, m] = startTime.split(':').map((v) => parseInt(v, 10));
  const period = h >= 12 ? 'PM' : 'AM';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${m.toString().padStart(2, '0')} ${period}`;
};

const priceLabel = (tableType: TableTypeRow) =>
  tableType.pricing_mode === 'hourly'
    ? `$${((tableType.hourly_rate_cents ?? 0) / 100).toFixed(0)}/hr · ${tableType.min_hours ?? 1}hr min`
    : `$${(tableType.min_spend_cents / 100).toFixed(0)} min spend`;

const VenueFloorPlanPicker = ({ venue, floors, tableTypes, timeSlots, onSelectTable }: VenueFloorPlanPickerProps) => {
  const [date, setDate] = useState<Date | undefined>(undefined);
  const [slotId, setSlotId] = useState('');
  const [unavailableIds, setUnavailableIds] = useState<Set<string>>(new Set());
  const [checkingAvailability, setCheckingAvailability] = useState(false);
  const [selectedFloorId, setSelectedFloorId] = useState<string | null>(null);

  const availableDaysOfWeek = useMemo(() => new Set(timeSlots.map((s) => s.day_of_week)), [timeSlots]);
  const bookingStart = venue.booking_start_date ? startOfDay(new Date(`${venue.booking_start_date}T00:00:00`)) : null;
  const bookingEnd = venue.booking_end_date ? startOfDay(new Date(`${venue.booking_end_date}T00:00:00`)) : null;

  const slotsForSelectedDate = useMemo(() => {
    if (!date) return [];
    return timeSlots.filter((s) => s.day_of_week === date.getDay());
  }, [timeSlots, date]);

  useEffect(() => {
    if (slotsForSelectedDate.length > 0 && !slotsForSelectedDate.some((s) => s.id === slotId)) {
      setSlotId(slotsForSelectedDate[0].id);
    } else if (slotsForSelectedDate.length === 0) {
      setSlotId('');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [slotsForSelectedDate]);

  useEffect(() => {
    if (!date || !slotId) {
      setUnavailableIds(new Set());
      return;
    }
    setCheckingAvailability(true);
    supabase
      .rpc('get_unavailable_table_types', {
        p_venue_id: venue.id,
        p_booking_date: format(date, 'yyyy-MM-dd'),
        p_time_slot_id: slotId,
      })
      .then(({ data }) => {
        setUnavailableIds(new Set(data ?? []));
        setCheckingAvailability(false);
      });
  }, [venue.id, date, slotId]);

  const positionedTableTypes = useMemo(
    () => tableTypes.filter((t) => t.floor_id && t.pos_x !== null),
    [tableTypes],
  );
  const unpositionedTableTypes = useMemo(
    () => tableTypes.filter((t) => !(t.floor_id && t.pos_x !== null)),
    [tableTypes],
  );

  const floorsWithTables = useMemo(
    () => floors.filter((f) => positionedTableTypes.some((t) => t.floor_id === f.id)),
    [floors, positionedTableTypes],
  );

  useEffect(() => {
    if (floorsWithTables.length > 0 && !floorsWithTables.some((f) => f.id === selectedFloorId)) {
      setSelectedFloorId(floorsWithTables[0].id);
    }
  }, [floorsWithTables, selectedFloorId]);

  const activeFloor = floorsWithTables.find((f) => f.id === selectedFloorId);
  const hotspotTables = activeFloor ? positionedTableTypes.filter((t) => t.floor_id === activeFloor.id) : [];

  const canPickTable = !!date && !!slotId;
  const noSlots = timeSlots.length === 0;

  return (
    <div className="space-y-6">
      <div className="rounded-lg border border-border bg-card p-4">
        <div className="mb-3 flex items-center gap-2 text-white">
          <CalendarDays className="h-4 w-4 text-primary" />
          <span className="font-semibold">Pick a date &amp; time</span>
        </div>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Popover>
            <PopoverTrigger asChild>
              <Button type="button" variant="outline" className="w-full justify-start">
                {date ? format(date, 'PPP') : 'Select a date'}
              </Button>
            </PopoverTrigger>
            <PopoverContent className="w-auto p-3" align="start">
              <Calendar
                mode="single"
                selected={date}
                onSelect={setDate}
                disabled={(d) => {
                  const day = startOfDay(d);
                  if (day < startOfDay(new Date())) return true;
                  if (!availableDaysOfWeek.has(d.getDay())) return true;
                  if (bookingStart && day < bookingStart) return true;
                  if (bookingEnd && day > bookingEnd) return true;
                  return false;
                }}
              />
            </PopoverContent>
          </Popover>

          <Select value={slotId} onValueChange={setSlotId} disabled={slotsForSelectedDate.length === 0}>
            <SelectTrigger>
              <SelectValue placeholder={date ? 'Select a time' : 'Pick a date first'} />
            </SelectTrigger>
            <SelectContent>
              {slotsForSelectedDate.map((slot) => (
                <SelectItem key={slot.id} value={slot.id}>
                  {formatTimeSlot(slot.start_time)}
                  {slot.label ? ` (${slot.label})` : ''}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        {(bookingStart || bookingEnd) && (
          <p className="mt-2 text-xs text-muted-foreground">
            Bookings open {bookingStart ? format(bookingStart, 'MMM d, yyyy') : 'now'}
            {bookingEnd ? ` through ${format(bookingEnd, 'MMM d, yyyy')}` : ''}.
          </p>
        )}
      </div>

      {activeFloor && (
        <div className="rounded-lg border border-border bg-card p-4">
          <div className="mb-3 flex items-center justify-between gap-2">
            <div className="flex items-center gap-2 text-white">
              <Crown className="h-4 w-4 text-primary" />
              <span className="font-semibold">Select a table</span>
            </div>
            {floorsWithTables.length > 1 && (
              <div className="flex gap-1">
                {floorsWithTables.map((f) => (
                  <button
                    key={f.id}
                    type="button"
                    onClick={() => setSelectedFloorId(f.id)}
                    className={`rounded-full px-3 py-1 text-xs font-medium transition-colors ${
                      f.id === selectedFloorId
                        ? 'bg-gradient-orange text-black'
                        : 'bg-black/40 text-gray-400 hover:text-white'
                    }`}
                  >
                    {f.label}
                  </button>
                ))}
              </div>
            )}
          </div>

          {!canPickTable && (
            <p className="mb-3 text-xs text-muted-foreground">Pick a date and time above to see live availability.</p>
          )}

          <div className="relative w-full select-none overflow-hidden rounded-lg border border-border">
            <img src={activeFloor.image_url} alt={activeFloor.label} className="block w-full" />
            {hotspotTables.map((tableType) => {
              const isUnavailable = canPickTable && unavailableIds.has(tableType.id);
              return (
                <button
                  key={tableType.id}
                  type="button"
                  disabled={!canPickTable || isUnavailable}
                  title={`${tableType.name} · up to ${tableType.max_guests} guests · ${priceLabel(tableType)}`}
                  onClick={() => date && slotId && onSelectTable(tableType, date, slotId)}
                  className={`absolute flex items-center justify-center rounded border-2 text-[10px] font-bold uppercase tracking-wide transition-colors ${
                    isUnavailable
                      ? 'cursor-not-allowed border-gray-600 bg-gray-800/70 text-gray-500'
                      : canPickTable
                        ? 'cursor-pointer border-primary bg-primary/25 text-white hover:bg-primary/40'
                        : 'cursor-not-allowed border-gray-500 bg-gray-700/40 text-gray-300'
                  }`}
                  style={{
                    left: `${tableType.pos_x}%`,
                    top: `${tableType.pos_y}%`,
                    width: `${tableType.width}%`,
                    height: `${tableType.height}%`,
                  }}
                >
                  <span className="truncate px-1">{tableType.name}</span>
                </button>
              );
            })}
          </div>

          <div className="mt-3 flex items-center gap-4 text-xs text-muted-foreground">
            <div className="flex items-center gap-1.5">
              <span className="h-2.5 w-2.5 rounded-sm border-2 border-primary bg-primary/25" />
              Available
            </div>
            <div className="flex items-center gap-1.5">
              <span className="h-2.5 w-2.5 rounded-sm border-2 border-gray-600 bg-gray-800/70" />
              Booked
            </div>
            {checkingAvailability && <span>Checking availability...</span>}
          </div>
        </div>
      )}

      {unpositionedTableTypes.length > 0 && (
        <div className="space-y-3">
          {activeFloor && <p className="text-sm font-semibold text-white">More Tables</p>}
          {unpositionedTableTypes.map((tableType) => (
            <div key={tableType.id} className="rounded-lg border border-border bg-card p-3">
              <div className="mb-2 flex items-start justify-between gap-2">
                <div className="text-sm font-medium text-white">{tableType.name}</div>
                {tableType.badge_label && (
                  <span
                    className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide ${
                      tableType.is_featured ? 'bg-gradient-orange text-black' : 'bg-black/70 text-white'
                    }`}
                  >
                    {tableType.badge_label}
                  </span>
                )}
              </div>
              <div className="mb-3 space-y-1 text-xs text-muted-foreground">
                <div className="flex items-center gap-1.5">
                  <Users className="h-3.5 w-3.5 text-primary" />
                  <span>Up to {tableType.max_guests} guests</span>
                </div>
                {tableType.description && (
                  <div className="flex items-center gap-1.5">
                    <Wine className="h-3.5 w-3.5 text-primary" />
                    <span>{tableType.description}</span>
                  </div>
                )}
                <div className="flex items-center justify-between pt-1">
                  <span>{tableType.pricing_mode === 'hourly' ? 'Hourly rate' : 'Minimum Spend'}</span>
                  <span className="font-semibold text-white">{priceLabel(tableType)}</span>
                </div>
              </div>
              <Button
                size="sm"
                className={
                  tableType.is_featured ? 'w-full bg-gradient-orange text-black font-bold hover:opacity-90' : 'w-full'
                }
                variant={tableType.is_featured ? 'default' : 'outline'}
                disabled={noSlots || (canPickTable && unavailableIds.has(tableType.id))}
                onClick={() => date && slotId && onSelectTable(tableType, date, slotId)}
              >
                {noSlots
                  ? 'Coming Soon'
                  : canPickTable && unavailableIds.has(tableType.id)
                    ? 'Booked for this date'
                    : canPickTable
                      ? 'Buy Table'
                      : 'Pick a date above'}
              </Button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default VenueFloorPlanPicker;
