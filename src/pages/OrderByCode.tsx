import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { Minus, Plus, Wine, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database, BottlePaymentMode, BottlePaymentChoice } from '@/types/database';
import BackLink from '@/components/BackLink';
import BottlePreviewDialog from '@/components/BottlePreviewDialog';

type BottleRow = Database['public']['Tables']['site_bottles']['Row'];

interface OrderContext {
  found: boolean;
  venueId?: string;
  venueName?: string;
  bottlePaymentMode?: BottlePaymentMode;
  tableTypeName?: string;
  currency?: string;
  showBottleImages?: boolean;
}

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

// Public, no login required - reached by scanning a table's QR code (section
// 8: "customers can also order through...a table QR code"), which encodes
// this booking's own confirmation code. Shares its actual ordering logic
// with the authenticated dashboard flow via the order-bottles-by-code /
// add-table-booking-bottles edge functions, both built on the same
// addBottlesToBooking() core.
const OrderByCode = () => {
  const { code } = useParams<{ code: string }>();
  const { toast } = useToast();
  const [loading, setLoading] = useState(true);
  const [context, setContext] = useState<OrderContext | null>(null);
  const [bottles, setBottles] = useState<BottleRow[]>([]);
  const [cart, setCart] = useState<Record<string, number>>({});
  const [paymentChoice, setPaymentChoice] = useState<BottlePaymentChoice>('pay_ahead');
  const [submitting, setSubmitting] = useState(false);
  const [previewBottle, setPreviewBottle] = useState<BottleRow | null>(null);

  useEffect(() => {
    if (!code) return;
    (async () => {
      const { data, error } = await supabase.functions.invoke('lookup-order-context', {
        body: { confirmation_code: code },
      });
      if (error || !data?.found) {
        setContext({ found: false });
        setLoading(false);
        return;
      }
      setContext(data);
      setPaymentChoice(data.bottlePaymentMode === 'pay_at_club' ? 'pay_at_club' : 'pay_ahead');

      const { data: bottleRows } = await supabase
        .from('site_bottles')
        .select('*')
        .eq('venue_id', data.venueId)
        .eq('is_available', true)
        .eq('is_sold_out', false)
        .order('sort_order', { ascending: true });
      setBottles(bottleRows ?? []);
      setLoading(false);
    })();
  }, [code]);

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
    if (!code || cartLines.length === 0) return;
    setSubmitting(true);
    try {
      const { data: result, error } = await supabase.functions.invoke('order-bottles-by-code', {
        body: {
          confirmation_code: code,
          bottles: cartLines.map((l) => ({ bottle_id: l.bottle.id, quantity: l.quantity })),
          bottle_payment_choice: paymentChoice,
        },
      });

      if (error) throw error;
      if (result?.error) throw new Error(result.error);

      if (result?.mode === 'pay_ahead' && result.url) {
        window.location.href = result.url;
        return;
      }

      toast({ title: 'Bottles reserved', description: 'Pay at the venue when you arrive.' });
      setCart({});
    } catch (err) {
      toast({
        title: 'Could not place order',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black">
        <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
      </div>
    );
  }

  if (!context?.found) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center">
        <p className="text-gray-400">We couldn't find an active reservation for that code.</p>
        <Button asChild className="mt-4 bg-gradient-orange text-black font-bold hover:opacity-90">
          <Link to="/">Back to BottlesUp</Link>
        </Button>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-black px-4 py-10">
      <div className="mx-auto max-w-sm">
        <BackLink to="/" label="Back to BottlesUp" />
        <h1 className="mb-1 mt-4 text-center text-xl font-bold text-white">
          {context.tableTypeName} - {context.venueName}
        </h1>
        <p className="mb-6 text-center text-sm text-gray-500">Order more bottles for your table</p>

        {bottles.length === 0 ? (
          <p className="py-8 text-center text-sm text-gray-500">No bottle menu available for this venue.</p>
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
                      {context.showBottleImages && bottle.image_url ? (
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

            {context.bottlePaymentMode === 'both' && cartLines.length > 0 && (
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

            <Button
              type="button"
              disabled={cartLines.length === 0 || submitting}
              className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
              onClick={handleSubmit}
            >
              {submitting ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : paymentChoice === 'pay_at_club' ? (
                'Reserve Bottles'
              ) : (
                'Continue to Payment'
              )}
            </Button>
          </div>
        )}
      </div>
      <BottlePreviewDialog
        bottle={previewBottle}
        onOpenChange={(nextOpen) => !nextOpen && setPreviewBottle(null)}
        showImage={context.showBottleImages}
      />
    </div>
  );
};

export default OrderByCode;
