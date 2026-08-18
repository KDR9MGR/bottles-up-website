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
import { Minus, Plus, Wine, Tag, X, Loader2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import type { TableTypeWithVenue } from '@/pages/VipTables';

type BottleRow = Database['public']['Tables']['site_bottles']['Row'];

interface TableBookingDialogProps {
  tableType: TableTypeWithVenue | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  initialDate?: Date;
  initialSlotId?: string;
}

type Step = 'details' | 'bottles' | 'review';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const formatTimeSlot = (startTime: string) => {
  const [h, m] = startTime.split(':').map((v) => parseInt(v, 10));
  const period = h >= 12 ? 'PM' : 'AM';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${m.toString().padStart(2, '0')} ${period}`;
};

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

const TableBookingDialog = ({ tableType, open, onOpenChange, initialDate, initialSlotId }: TableBookingDialogProps) => {
  const { toast } = useToast();
  const [step, setStep] = useState<Step>('details');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [confirmEmail, setConfirmEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [date, setDate] = useState<Date | undefined>(undefined);
  const [slotId, setSlotId] = useState('');
  const [guestCount, setGuestCount] = useState('2');
  const [hours, setHours] = useState('1');
  const [submitting, setSubmitting] = useState(false);

  const [bottles, setBottles] = useState<BottleRow[]>([]);
  const [loadingBottles, setLoadingBottles] = useState(false);
  const [cart, setCart] = useState<Record<string, number>>({});
  const [bottlesupFeeBps, setBottlesupFeeBps] = useState(0);

  const [promoInput, setPromoInput] = useState('');
  const [appliedPromo, setAppliedPromo] = useState<{ code: string; discountCents: number } | null>(null);
  const [promoError, setPromoError] = useState<string | null>(null);
  const [applyingPromo, setApplyingPromo] = useState(false);

  useEffect(() => {
    setStep('details');
    setName('');
    setEmail('');
    setConfirmEmail('');
    setPhone('');
    setDate(initialDate);
    setSlotId(initialSlotId ?? '');
    setGuestCount('2');
    setHours(tableType?.min_hours ? tableType.min_hours.toString() : '1');
    setCart({});
    setPromoInput('');
    setAppliedPromo(null);
    setPromoError(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tableType]);

  useEffect(() => {
    if (!open || !tableType) return;
    setLoadingBottles(true);
    supabase
      .from('site_bottles')
      .select('*')
      .eq('venue_id', tableType.venue.id)
      .eq('is_available', true)
      .eq('is_sold_out', false)
      .order('sort_order', { ascending: true })
      .then(({ data }) => {
        setBottles(data ?? []);
        setLoadingBottles(false);
      });
    supabase
      .from('site_content')
      .select('bottlesup_fee_bps')
      .eq('id', 1)
      .maybeSingle()
      .then(({ data }) => setBottlesupFeeBps(data?.bottlesup_fee_bps ?? 0));
  }, [open, tableType]);

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
  const isHourly = tableType.pricing_mode === 'hourly';
  const bookedHours = parseInt(hours, 10) || 0;
  const minHours = tableType.min_hours ?? 1;
  const depositCents = isHourly ? (tableType.hourly_rate_cents ?? 0) * bookedHours : tableType.deposit_cents;

  const bookingStart = tableType.venue.booking_start_date ? startOfDay(new Date(`${tableType.venue.booking_start_date}T00:00:00`)) : null;
  const bookingEnd = tableType.venue.booking_end_date ? startOfDay(new Date(`${tableType.venue.booking_end_date}T00:00:00`)) : null;

  const cartLines = bottles
    .filter((b) => (cart[b.id] ?? 0) > 0)
    .map((b) => ({ bottle: b, quantity: cart[b.id], lineTotalCents: b.price_cents * cart[b.id] }));
  const bottleSubtotalCents = cartLines.reduce((sum, l) => sum + l.lineTotalCents, 0);
  const preTaxSubtotalCents = depositCents + bottleSubtotalCents;
  const discountCents = appliedPromo?.discountCents ?? 0;
  const discountedSubtotalCents = preTaxSubtotalCents - discountCents;
  const taxCents = Math.round((discountedSubtotalCents * (tableType.venue.tax_rate_bps ?? 0)) / 10000);
  const bottlesupFeeCents = Math.round((discountedSubtotalCents * bottlesupFeeBps) / 10000);
  const totalCents = discountedSubtotalCents + taxCents + bottlesupFeeCents;

  const setQuantity = (bottleId: string, quantity: number) =>
    setCart((prev) => {
      if (quantity <= 0) {
        const { [bottleId]: _removed, ...rest } = prev;
        return rest;
      }
      return { ...prev, [bottleId]: quantity };
    });

  const validateDetails = () => {
    if (!name || !email || !date || !slotId || guests < 1) {
      toast({ title: 'Please fill in all required fields', variant: 'destructive' });
      return false;
    }
    if (!EMAIL_RE.test(email)) {
      toast({ title: 'Please enter a valid email', variant: 'destructive' });
      return false;
    }
    if (email.trim().toLowerCase() !== confirmEmail.trim().toLowerCase()) {
      toast({ title: 'Emails do not match', description: 'Please make sure both email fields match.', variant: 'destructive' });
      return false;
    }
    if (guests > tableType.max_guests) {
      toast({ title: `This table seats up to ${tableType.max_guests} guests`, variant: 'destructive' });
      return false;
    }
    if (isHourly && bookedHours < minHours) {
      toast({ title: `This table requires a minimum of ${minHours} hour${minHours === 1 ? '' : 's'}`, variant: 'destructive' });
      return false;
    }
    return true;
  };

  const goToBottles = () => {
    if (!validateDetails()) return;
    setStep('bottles');
  };

  const handleApplyPromo = async () => {
    if (!promoInput.trim()) return;
    setApplyingPromo(true);
    setPromoError(null);
    try {
      const { data, error } = await supabase.functions.invoke('validate-promo-code', {
        body: {
          code: promoInput,
          applies_to: 'tables',
          venue_id: tableType.venue.id,
          subtotal_cents: preTaxSubtotalCents,
        },
      });
      if (error) throw error;
      if (!data?.valid) {
        setPromoError(data?.message ?? 'Invalid promo code');
        return;
      }
      setAppliedPromo({ code: promoInput.trim().toUpperCase(), discountCents: data.discountCents });
      setPromoInput('');
    } catch (err) {
      setPromoError(err instanceof Error ? err.message : 'Could not validate promo code');
    } finally {
      setApplyingPromo(false);
    }
  };

  const handleRemovePromo = () => {
    setAppliedPromo(null);
    setPromoError(null);
  };

  const handleSubmit = async () => {
    if (!validateDetails()) {
      setStep('details');
      return;
    }

    setSubmitting(true);
    try {
      const { data, error } = await supabase.functions.invoke('create-table-booking-checkout', {
        body: {
          venue_id: tableType.venue.id,
          table_type_id: tableType.id,
          time_slot_id: slotId,
          booking_date: format(date!, 'yyyy-MM-dd'),
          guest_count: guests,
          customer_name: name,
          customer_email: email,
          customer_phone: phone || null,
          hours: isHourly ? bookedHours : undefined,
          bottles: cartLines.map((l) => ({ bottle_id: l.bottle.id, quantity: l.quantity })),
          promo_code: appliedPromo?.code,
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

        <div className="mb-2 flex items-center gap-2 text-xs text-gray-500">
          <span className={step === 'details' ? 'font-semibold text-orange-500' : ''}>1. Table</span>
          <span>&rarr;</span>
          <span className={step === 'bottles' ? 'font-semibold text-orange-500' : ''}>2. Bottles</span>
          <span>&rarr;</span>
          <span className={step === 'review' ? 'font-semibold text-orange-500' : ''}>3. Review &amp; Pay</span>
        </div>

        {step === 'details' && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              goToBottles();
            }}
            className="space-y-4"
          >
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

            {isHourly && (
              <div className="space-y-2">
                <Label>Hours</Label>
                <Input
                  type="number"
                  min={minHours}
                  value={hours}
                  onChange={(e) => setHours(e.target.value)}
                />
                <p className="text-xs text-gray-500">
                  ${((tableType.hourly_rate_cents ?? 0) / 100).toFixed(2)}/hour &middot; {minHours} hour minimum
                </p>
              </div>
            )}

            <div className="text-right text-lg font-semibold text-white">
              {isHourly ? 'Table total' : 'Deposit'}: ${(depositCents / 100).toFixed(2)}
            </div>

            <DialogFooter>
              <Button type="submit" className="w-full bg-gradient-orange text-black font-bold hover:opacity-90">
                Continue
              </Button>
            </DialogFooter>
          </form>
        )}

        {step === 'bottles' && (
          <div className="space-y-4">
            <p className="text-sm text-gray-400">Add bottles to your table - optional, you can skip this.</p>

            {loadingBottles ? (
              <div className="py-8 text-center text-sm text-gray-500">Loading bottle menu...</div>
            ) : bottles.length === 0 ? (
              <div className="py-8 text-center text-sm text-gray-500">No bottle menu available for this venue yet.</div>
            ) : (
              <div className="space-y-3">
                {bottles.map((bottle) => {
                  const qty = cart[bottle.id] ?? 0;
                  return (
                    <div key={bottle.id} className="flex items-center gap-3 rounded-lg border border-gray-800 p-3">
                      {tableType.venue.show_bottle_images && bottle.image_url ? (
                        <img src={bottle.image_url} alt={bottle.name} className="h-14 w-14 shrink-0 rounded object-cover" />
                      ) : (
                        <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded bg-gray-900 text-gray-600">
                          <Wine className="h-6 w-6" />
                        </div>
                      )}
                      <div className="flex-1">
                        <div className="text-sm font-medium text-white">
                          {bottle.name}
                          {bottle.size ? <span className="text-gray-500"> ({bottle.size})</span> : null}
                        </div>
                        {bottle.description && <div className="text-xs text-gray-500">{bottle.description}</div>}
                        <div className="text-sm text-gray-400">{money(bottle.price_cents)}</div>
                      </div>
                      <div className="flex items-center gap-2">
                        <Button
                          type="button"
                          size="icon"
                          variant="outline"
                          className="h-7 w-7 border-gray-700"
                          disabled={qty === 0}
                          onClick={() => setQuantity(bottle.id, qty - 1)}
                        >
                          <Minus className="h-3 w-3" />
                        </Button>
                        <span className="w-5 text-center text-sm text-white">{qty}</span>
                        <Button
                          type="button"
                          size="icon"
                          variant="outline"
                          className="h-7 w-7 border-gray-700"
                          onClick={() => setQuantity(bottle.id, qty + 1)}
                        >
                          <Plus className="h-3 w-3" />
                        </Button>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}

            {bottleSubtotalCents > 0 && (
              <div className="text-right text-sm text-gray-400">
                Bottle subtotal: <span className="font-semibold text-white">{money(bottleSubtotalCents)}</span>
              </div>
            )}

            <DialogFooter className="gap-2 sm:justify-between">
              <Button type="button" variant="outline" className="border-gray-800" onClick={() => setStep('details')}>
                Back
              </Button>
              <Button type="button" className="bg-gradient-orange text-black font-bold hover:opacity-90" onClick={() => setStep('review')}>
                Review Order
              </Button>
            </DialogFooter>
          </div>
        )}

        {step === 'review' && (
          <div className="space-y-4">
            <div className="space-y-2">
              <Label className="flex items-center gap-1.5 text-sm">
                <Tag className="h-3.5 w-3.5" />
                Promo Code
              </Label>
              {appliedPromo ? (
                <div className="flex items-center justify-between rounded-lg border border-green-800/50 bg-green-950/30 px-3 py-2">
                  <span className="font-mono text-sm text-green-400">{appliedPromo.code} applied</span>
                  <Button type="button" variant="ghost" size="icon" className="h-6 w-6" onClick={handleRemovePromo}>
                    <X className="h-3.5 w-3.5" />
                  </Button>
                </div>
              ) : (
                <div className="flex gap-2">
                  <Input
                    value={promoInput}
                    onChange={(e) => {
                      setPromoInput(e.target.value.toUpperCase());
                      setPromoError(null);
                    }}
                    placeholder="Enter code"
                    className="font-mono uppercase"
                  />
                  <Button
                    type="button"
                    variant="outline"
                    className="border-gray-700 shrink-0"
                    disabled={applyingPromo || !promoInput.trim()}
                    onClick={handleApplyPromo}
                  >
                    {applyingPromo ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Apply'}
                  </Button>
                </div>
              )}
              {promoError && <p className="text-xs text-red-400">{promoError}</p>}
            </div>

            <div className="space-y-2 rounded-lg border border-gray-800 p-4 text-sm">
              <div className="flex justify-between text-gray-300">
                <span>{isHourly ? `Table (${bookedHours} hr)` : 'Table deposit'}</span>
                <span>{money(depositCents)}</span>
              </div>
              {cartLines.map((l) => (
                <div key={l.bottle.id} className="flex justify-between text-gray-300">
                  <span>
                    {l.bottle.name} &times; {l.quantity}
                  </span>
                  <span>{money(l.lineTotalCents)}</span>
                </div>
              ))}
              {discountCents > 0 && (
                <div className="flex justify-between text-green-400">
                  <span>Promo ({appliedPromo?.code})</span>
                  <span>-{money(discountCents)}</span>
                </div>
              )}
              {taxCents > 0 && (
                <div className="flex justify-between text-gray-400">
                  <span>Tax</span>
                  <span>{money(taxCents)}</span>
                </div>
              )}
              {bottlesupFeeCents > 0 && (
                <div className="flex justify-between text-gray-400">
                  <span>BottlesUp fee</span>
                  <span>{money(bottlesupFeeCents)}</span>
                </div>
              )}
              <div className="flex justify-between border-t border-gray-800 pt-2 text-base font-semibold text-white">
                <span>Total due today</span>
                <span>{money(totalCents)}</span>
              </div>
            </div>

            <p className="text-xs text-gray-500">
              You'll enter payment details on the next screen (secure checkout via Stripe). Your confirmation and QR code
              are sent to {email}.
            </p>

            <DialogFooter className="gap-2 sm:justify-between">
              <Button
                type="button"
                variant="outline"
                className="border-gray-800"
                onClick={() => {
                  handleRemovePromo();
                  setStep('bottles');
                }}
              >
                Back
              </Button>
              <Button
                type="button"
                disabled={submitting}
                className="bg-gradient-orange text-black font-bold hover:opacity-90"
                onClick={handleSubmit}
              >
                {submitting ? 'Redirecting to checkout...' : 'Continue to Payment'}
              </Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
};

export default TableBookingDialog;
