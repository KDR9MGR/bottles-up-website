import { useEffect, useState } from 'react';
import { format } from 'date-fns';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Loader2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];

interface CreateWalkInDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated: (confirmationCode: string) => void;
}

// Bottle Payment Options section 8: "for customers without reservations,
// staff creates a Walk-In Table Tab, assigns the table and follows the same
// ordering and payment process." Once created, the walk-in behaves exactly
// like any other booking - staff use the same Add Bottles / Record Club
// Payment flows already built for reservations.
const CreateWalkInDialog = ({ open, onOpenChange, onCreated }: CreateWalkInDialogProps) => {
  const { toast } = useToast();
  const [venues, setVenues] = useState<VenueRow[]>([]);
  const [tableTypes, setTableTypes] = useState<TableTypeRow[]>([]);
  const [timeSlots, setTimeSlots] = useState<TimeSlotRow[]>([]);
  const [venueId, setVenueId] = useState('');
  const [tableTypeId, setTableTypeId] = useState('');
  const [timeSlotId, setTimeSlotId] = useState('');
  const [bookingDate, setBookingDate] = useState(format(new Date(), 'yyyy-MM-dd'));
  const [guestCount, setGuestCount] = useState('2');
  const [hours, setHours] = useState('1');
  const [customerName, setCustomerName] = useState('');
  const [customerEmail, setCustomerEmail] = useState('');
  const [customerPhone, setCustomerPhone] = useState('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) return;
    setVenueId('');
    setTableTypeId('');
    setTimeSlotId('');
    setBookingDate(format(new Date(), 'yyyy-MM-dd'));
    setGuestCount('2');
    setHours('1');
    setCustomerName('');
    setCustomerEmail('');
    setCustomerPhone('');

    supabase
      .from('site_venues')
      .select('*')
      .eq('status', 'published')
      .order('name')
      .then(({ data }) => setVenues(data ?? []));
  }, [open]);

  useEffect(() => {
    if (!venueId) {
      setTableTypes([]);
      setTimeSlots([]);
      return;
    }
    setTableTypeId('');
    setTimeSlotId('');
    supabase.from('site_table_types').select('*').eq('venue_id', venueId).order('sort_order').then(({ data }) => setTableTypes(data ?? []));
    supabase.from('site_venue_time_slots').select('*').eq('venue_id', venueId).then(({ data }) => setTimeSlots(data ?? []));
  }, [venueId]);

  const selectedTableType = tableTypes.find((t) => t.id === tableTypeId) ?? null;
  const dayOfWeek = bookingDate ? new Date(`${bookingDate}T00:00:00`).getDay() : null;
  const slotsForDate = dayOfWeek === null ? [] : timeSlots.filter((s) => s.day_of_week === dayOfWeek);

  const handleSubmit = async () => {
    if (!venueId || !tableTypeId || !timeSlotId || !customerName.trim() || !customerEmail.trim()) {
      toast({ title: 'Fill in all required fields', variant: 'destructive' });
      return;
    }
    setSubmitting(true);
    try {
      const { data: sessionData } = await supabase.auth.getSession();
      const token = sessionData.session?.access_token;
      const { data: result, error } = await supabase.functions.invoke('create-walkin-table-booking', {
        body: {
          venue_id: venueId,
          table_type_id: tableTypeId,
          time_slot_id: timeSlotId,
          booking_date: bookingDate,
          guest_count: parseInt(guestCount, 10) || 1,
          hours: selectedTableType?.pricing_mode === 'hourly' ? parseInt(hours, 10) || 1 : undefined,
          customer_name: customerName.trim(),
          customer_email: customerEmail.trim(),
          customer_phone: customerPhone.trim() || undefined,
        },
        headers: token ? { Authorization: `Bearer ${token}` } : undefined,
      });

      if (error) throw error;
      if (result?.error) throw new Error(result.error);

      toast({ title: 'Walk-in tab opened', description: `Confirmation ${result.confirmation_code}` });
      onOpenChange(false);
      onCreated(result.confirmation_code);
    } catch (err) {
      toast({
        title: 'Could not create walk-in',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] overflow-y-auto border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">New Walk-In</DialogTitle>
        </DialogHeader>

        <div className="space-y-3">
          <div className="space-y-1">
            <Label className="text-xs">Venue</Label>
            <Select value={venueId} onValueChange={setVenueId}>
              <SelectTrigger>
                <SelectValue placeholder="Select a venue" />
              </SelectTrigger>
              <SelectContent>
                {venues.map((v) => (
                  <SelectItem key={v.id} value={v.id}>{v.name}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1">
            <Label className="text-xs">Table</Label>
            <Select value={tableTypeId} onValueChange={setTableTypeId} disabled={!venueId}>
              <SelectTrigger>
                <SelectValue placeholder={venueId ? 'Select a table' : 'Pick a venue first'} />
              </SelectTrigger>
              <SelectContent>
                {tableTypes.map((t) => (
                  <SelectItem key={t.id} value={t.id}>{t.name}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div className="space-y-1">
              <Label className="text-xs">Date</Label>
              <Input type="date" value={bookingDate} onChange={(e) => setBookingDate(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label className="text-xs">Arrival Time</Label>
              <Select value={timeSlotId} onValueChange={setTimeSlotId} disabled={slotsForDate.length === 0}>
                <SelectTrigger>
                  <SelectValue placeholder="Select a time" />
                </SelectTrigger>
                <SelectContent>
                  {slotsForDate.map((s) => (
                    <SelectItem key={s.id} value={s.id}>{s.start_time.slice(0, 5)}{s.label ? ` (${s.label})` : ''}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div className="space-y-1">
              <Label className="text-xs">Guests</Label>
              <Input type="number" min="1" value={guestCount} onChange={(e) => setGuestCount(e.target.value)} />
            </div>
            {selectedTableType?.pricing_mode === 'hourly' && (
              <div className="space-y-1">
                <Label className="text-xs">Hours</Label>
                <Input type="number" min={selectedTableType.min_hours ?? 1} value={hours} onChange={(e) => setHours(e.target.value)} />
              </div>
            )}
          </div>

          <div className="space-y-1">
            <Label className="text-xs">Customer name</Label>
            <Input value={customerName} onChange={(e) => setCustomerName(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label className="text-xs">Customer email</Label>
            <Input type="email" value={customerEmail} onChange={(e) => setCustomerEmail(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label className="text-xs">Phone (optional)</Label>
            <Input type="tel" value={customerPhone} onChange={(e) => setCustomerPhone(e.target.value)} />
          </div>

          {selectedTableType && (
            <p className="text-xs text-gray-500">
              Deposit due at the venue: ${(selectedTableType.pricing_mode === 'hourly'
                ? (selectedTableType.hourly_rate_cents ?? 0) * (parseInt(hours, 10) || 1)
                : selectedTableType.deposit_cents) / 100}
            </p>
          )}
        </div>

        <DialogFooter>
          <Button
            type="button"
            disabled={submitting}
            className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
            onClick={handleSubmit}
          >
            {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Open Tab'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default CreateWalkInDialog;
