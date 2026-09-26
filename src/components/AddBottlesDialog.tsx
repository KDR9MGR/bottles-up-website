import { useEffect, useState } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Minus, Plus, Wine, Loader2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database, BottlePaymentMode, BottlePaymentChoice } from '@/types/database';
import BottlePreviewDialog from '@/components/BottlePreviewDialog';

type BottleRow = Database['public']['Tables']['site_bottles']['Row'];

interface AddBottlesDialogProps {
  bookingId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onAdded: () => void;
  // 'staff' is used from the CMS/door check-in screens (section 8: "staff
  // opens the table and taps Add Bottles") - the edge function always settles
  // a staff-added item the same way a club payment is (due at venue, no
  // Stripe redirect), so the pay-now/pay-at-club chooser doesn't apply.
  mode?: 'customer' | 'staff';
}

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

const AddBottlesDialog = ({ bookingId, open, onOpenChange, onAdded, mode = 'customer' }: AddBottlesDialogProps) => {
  const { toast } = useToast();
  const [loading, setLoading] = useState(true);
  const [bottles, setBottles] = useState<BottleRow[]>([]);
  const [cart, setCart] = useState<Record<string, number>>({});
  const [venuePaymentMode, setVenuePaymentMode] = useState<BottlePaymentMode>('pay_ahead');
  const [showBottleImages, setShowBottleImages] = useState(true);
  const [paymentChoice, setPaymentChoice] = useState<BottlePaymentChoice>('pay_ahead');
  const [submitting, setSubmitting] = useState(false);
  const [previewBottle, setPreviewBottle] = useState<BottleRow | null>(null);

  useEffect(() => {
    if (!open) return;
    setCart({});
    setLoading(true);

    (async () => {
      const { data: booking } = await supabase
        .from('site_table_bookings')
        .select('venue_id')
        .eq('id', bookingId)
        .maybeSingle();
      if (!booking) {
        setLoading(false);
        return;
      }

      const [{ data: venue }, { data: bottleRows }] = await Promise.all([
        supabase.from('site_venues').select('bottle_payment_mode, show_bottle_images').eq('id', booking.venue_id).maybeSingle(),
        supabase
          .from('site_bottles')
          .select('*')
          .eq('venue_id', booking.venue_id)
          .eq('is_available', true)
          .eq('is_sold_out', false)
          .order('sort_order', { ascending: true }),
      ]);

      const mode = venue?.bottle_payment_mode ?? 'pay_ahead';
      setVenuePaymentMode(mode);
      setShowBottleImages(venue?.show_bottle_images ?? true);
      setPaymentChoice(mode === 'pay_at_club' ? 'pay_at_club' : 'pay_ahead');
      setBottles(bottleRows ?? []);
      setLoading(false);
    })();
  }, [open, bookingId]);

  const cartLines = bottles
    .filter((b) => (cart[b.id] ?? 0) > 0)
    .map((b) => ({ bottle: b, quantity: cart[b.id], lineTotalCents: b.price_cents * cart[b.id] }));
  const subtotalCents = cartLines.reduce((sum, l) => sum + l.lineTotalCents, 0);

  const setQuantity = (bottleId: string, quantity: number) =>
    setCart((prev) => {
      if (quantity <= 0) {
        const { [bottleId]: _removed, ...rest } = prev;
        return rest;
      }
      return { ...prev, [bottleId]: quantity };
    });

  const handleSubmit = async () => {
    if (cartLines.length === 0) return;
    setSubmitting(true);
    try {
      const { data: sessionData } = await supabase.auth.getSession();
      const token = sessionData.session?.access_token;
      const { data: result, error } = await supabase.functions.invoke('add-table-booking-bottles', {
        body: {
          booking_id: bookingId,
          bottles: cartLines.map((l) => ({ bottle_id: l.bottle.id, quantity: l.quantity })),
          bottle_payment_choice: paymentChoice,
        },
        headers: token ? { Authorization: `Bearer ${token}` } : undefined,
      });

      if (error) throw error;
      if (result?.error) throw new Error(result.error);

      if (result?.mode === 'pay_ahead' && result.url) {
        window.location.href = result.url;
        return;
      }

      toast({
        title: mode === 'staff' ? 'Bottles added to tab' : 'Bottles reserved',
        description: mode === 'staff' ? 'Settle up along with the rest of the tab.' : 'Pay at the venue when you arrive.',
      });
      onOpenChange(false);
      onAdded();
    } catch (err) {
      toast({
        title: 'Could not add bottles',
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
          <DialogTitle className="text-white">{mode === 'staff' ? 'Add Bottles to Tab' : 'Add Bottles'}</DialogTitle>
        </DialogHeader>

        {loading ? (
          <div className="py-8 text-center text-sm text-gray-500">Loading bottle menu...</div>
        ) : bottles.length === 0 ? (
          <div className="py-8 text-center text-sm text-gray-500">No bottle menu available for this venue.</div>
        ) : (
          <div className="space-y-4">
            <div className="space-y-3">
              {bottles.map((bottle) => {
                const qty = cart[bottle.id] ?? 0;
                return (
                  <div key={bottle.id} className="flex items-center gap-3 rounded-lg border border-gray-800 p-3">
                    <button
                      type="button"
                      onClick={() => setPreviewBottle(bottle)}
                      className="flex flex-1 items-center gap-3 text-left"
                    >
                      {showBottleImages && bottle.image_url ? (
                        <img src={bottle.image_url} alt={bottle.name} className="h-12 w-12 shrink-0 rounded object-cover" />
                      ) : (
                        <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded bg-gray-900 text-gray-600">
                          <Wine className="h-5 w-5" />
                        </div>
                      )}
                      <div className="flex-1">
                        <div className="text-sm font-medium text-white">
                          {bottle.name}
                          {bottle.size ? <span className="text-gray-500"> ({bottle.size})</span> : ''}
                        </div>
                        {bottle.description && <div className="text-xs text-gray-500">{bottle.description}</div>}
                        <div className="text-sm text-gray-400">{money(bottle.price_cents)}</div>
                      </div>
                    </button>
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

            {mode === 'customer' && venuePaymentMode === 'both' && cartLines.length > 0 && (
              <div className="space-y-2 rounded-lg border border-gray-800 p-3">
                <p className="text-sm text-white">How do you want to pay?</p>
                <div className="grid grid-cols-2 gap-2">
                  <button
                    type="button"
                    onClick={() => setPaymentChoice('pay_ahead')}
                    className={`rounded-md border p-2 text-left text-xs transition-colors ${
                      paymentChoice === 'pay_ahead'
                        ? 'border-orange-500 bg-orange-500/10 text-white'
                        : 'border-gray-800 text-gray-400 hover:border-gray-700'
                    }`}
                  >
                    <div className="font-semibold">Pay Now</div>
                    <div className="text-gray-500">Charged online today.</div>
                  </button>
                  <button
                    type="button"
                    onClick={() => setPaymentChoice('pay_at_club')}
                    className={`rounded-md border p-2 text-left text-xs transition-colors ${
                      paymentChoice === 'pay_at_club'
                        ? 'border-orange-500 bg-orange-500/10 text-white'
                        : 'border-gray-800 text-gray-400 hover:border-gray-700'
                    }`}
                  >
                    <div className="font-semibold">Pay at Club</div>
                    <div className="text-gray-500">Reserved, pay in person.</div>
                  </button>
                </div>
              </div>
            )}

            {subtotalCents > 0 && (
              <div className="text-right text-sm text-gray-400">
                Subtotal: <span className="font-semibold text-white">{money(subtotalCents)}</span>
                <span className="ml-1 text-xs text-gray-600">(plus tax/fees where applicable)</span>
              </div>
            )}

            <DialogFooter>
              <Button
                type="button"
                disabled={cartLines.length === 0 || submitting}
                className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
                onClick={handleSubmit}
              >
                {submitting ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : mode === 'staff' ? (
                  'Add to Tab'
                ) : paymentChoice === 'pay_at_club' ? (
                  'Reserve Bottles'
                ) : (
                  'Continue to Payment'
                )}
              </Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
      <BottlePreviewDialog
        bottle={previewBottle}
        onOpenChange={(nextOpen) => !nextOpen && setPreviewBottle(null)}
        showImage={showBottleImages}
      />
    </Dialog>
  );
};

export default AddBottlesDialog;
