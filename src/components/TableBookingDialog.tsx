import { useEffect, useMemo, useState } from 'react';
import { format, startOfDay } from 'date-fns';
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
import { Calendar } from '@/components/ui/calendar';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { TableTypeWithVenue } from '@/pages/VipTables';

interface TableBookingDialogProps {
  tableType: TableTypeWithVenue | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const formatTimeSlot = (startTime: string) => {
  const [h, m] = startTime.split(':').map((v) => parseInt(v, 10));
  const period = h >= 12 ? 'PM' : 'AM';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${m.toString().padStart(2, '0')} ${period}`;
};

const TableBookingDialog = ({ tableType, open, onOpenChange }: TableBookingDialogProps) => {
  const { toast } = useToast();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [confirmEmail, setConfirmEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [date, setDate] = useState<Date | undefined>(undefined);
  const [slotId, setSlotId] = useState('');
  const [guestCount, setGuestCount] = useState('2');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    setName('');
    setEmail('');
    setConfirmEmail('');
    setPhone('');
    setDate(undefined);
    setSlotId('');
    setGuestCount('2');
  }, [tableType]);

  const availableDaysOfWeek = useMemo(
    () => new Set(tableType?.timeSlots.map((s) => s.day_of_week) ?? []),
    [tableType],
  );

  const slotsForSelectedDate = useMemo(() => {
    if (!tableType || !date) return [];
    return tableType.timeSlots.filter((s) => s.day_of_week === date.getDay());
  }, [tableType, date]);

  useEffect(() => {
    if (slotsForSelectedDate.length > 0 && !slotsForSelectedDate.some((s) => s.id === slotId)) {
      setSlotId(slotsForSelectedDate[0].id);
    } else if (slotsForSelectedDate.length === 0) {
      setSlotId('');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [slotsForSelectedDate]);

  if (!tableType) return null;

  const guests = parseInt(guestCount, 10) || 0;
  const depositTotal = tableType.deposit_cents / 100;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name || !email || !date || !slotId || guests < 1) {
      toast({ title: 'Please fill in all required fields', variant: 'destructive' });
      return;
    }
    if (!EMAIL_RE.test(email)) {
      toast({ title: 'Please enter a valid email', variant: 'destructive' });
      return;
    }
    if (email.trim().toLowerCase() !== confirmEmail.trim().toLowerCase()) {
      toast({ title: 'Emails do not match', description: 'Please make sure both email fields match.', variant: 'destructive' });
      return;
    }
    if (guests > tableType.max_guests) {
      toast({ title: `This table seats up to ${tableType.max_guests} guests`, variant: 'destructive' });
      return;
    }

    setSubmitting(true);
    try {
      const { data, error } = await supabase.functions.invoke('create-table-booking-checkout', {
        body: {
          venue_id: tableType.venue.id,
          table_type_id: tableType.id,
          time_slot_id: slotId,
          booking_date: format(date, 'yyyy-MM-dd'),
          guest_count: guests,
          customer_name: name,
          customer_email: email,
          customer_phone: phone || null,
        },
      });

      if (error) throw error;
      if (data?.error) throw new Error(data.error);
      if (!data?.url) throw new Error('No checkout URL returned');

      window.location.href = data.url;
    } catch (error) {
      toast({
        title: 'Could not start checkout',
        description: error instanceof Error ? error.message : 'Please try again.',
        variant: 'destructive',
      });
      setSubmitting(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">
            Book: {tableType.name} - {tableType.venue.name}
          </DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="rounded-lg border border-gray-800 p-3 text-sm text-gray-400">
            <div className="flex justify-between">
              <span>Up to {tableType.max_guests} guests</span>
              <span>Min spend ${(tableType.min_spend_cents / 100).toFixed(0)}</span>
            </div>
          </div>

          <div className="space-y-2">
            <Label>Date</Label>
            <Popover>
              <PopoverTrigger asChild>
                <Button type="button" variant="outline" className="w-full justify-start border-gray-800 bg-gray-950 text-white">
                  {date ? format(date, 'PPP') : 'Select a date'}
                </Button>
              </PopoverTrigger>
              <PopoverContent className="w-auto border-gray-800 bg-gray-950 p-3 text-white" align="start">
                <Calendar
                  mode="single"
                  selected={date}
                  onSelect={setDate}
                  disabled={(d) => startOfDay(d) < startOfDay(new Date()) || !availableDaysOfWeek.has(d.getDay())}
                />
              </PopoverContent>
            </Popover>
          </div>

          <div className="space-y-2">
            <Label>Arrival Time</Label>
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

          <div className="space-y-2">
            <Label>Full Name</Label>
            <Input value={name} onChange={(e) => setName(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label>Email</Label>
            <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label>Confirm Email</Label>
            <Input
              type="email"
              value={confirmEmail}
              onChange={(e) => setConfirmEmail(e.target.value)}
              onPaste={(e) => e.preventDefault()}
              required
            />
            <p className="text-xs text-gray-500">Your confirmation and QR code are sent here - please double-check it.</p>
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Phone (optional)</Label>
              <Input type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>Guests</Label>
              <Input
                type="number"
                min="1"
                max={tableType.max_guests}
                value={guestCount}
                onChange={(e) => setGuestCount(e.target.value)}
              />
            </div>
          </div>

          <div className="text-right text-lg font-semibold text-white">
            Deposit due today: ${depositTotal.toFixed(2)}
          </div>

          <DialogFooter>
            <Button
              type="submit"
              disabled={submitting}
              className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
            >
              {submitting ? 'Redirecting to checkout...' : 'Continue to Payment'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
};

export default TableBookingDialog;
