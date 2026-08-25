import { useEffect, useState } from 'react';
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
import { Tag, X, Loader2, Lock, Unlock } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { EventWithTiers } from './PopularEvents';

interface BookingDialogProps {
  event: EventWithTiers | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  initialTierId?: string | null;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const BookingDialog = ({ event, open, onOpenChange, initialTierId }: BookingDialogProps) => {
  const { toast } = useToast();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [confirmEmail, setConfirmEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [tierId, setTierId] = useState('');
  const [quantity, setQuantity] = useState('1');
  const [submitting, setSubmitting] = useState(false);

  const [promoInput, setPromoInput] = useState('');
  const [appliedPromo, setAppliedPromo] = useState<{ code: string; discountCents: number } | null>(null);
  const [promoError, setPromoError] = useState<string | null>(null);
  const [applyingPromo, setApplyingPromo] = useState(false);

  const [accessCodeInput, setAccessCodeInput] = useState('');
  const [accessCodeError, setAccessCodeError] = useState<string | null>(null);
  const [applyingAccessCode, setApplyingAccessCode] = useState(false);
  // Keyed by tier id, so switching tiers and back doesn't re-lock a tier
  // already unlocked earlier in this session.
  const [unlockedTiers, setUnlockedTiers] = useState<Record<string, { priceCents: number; code: string }>>({});

  useEffect(() => {
    if (event && event.ticket_tiers.length > 0) {
      const preselected = initialTierId && event.ticket_tiers.some((t) => t.id === initialTierId);
      setTierId(preselected ? initialTierId! : event.ticket_tiers[0].id);
    }
    setName('');
    setEmail('');
    setConfirmEmail('');
    setPhone('');
    setQuantity('1');
    setPromoInput('');
    setAppliedPromo(null);
    setPromoError(null);
    setAccessCodeInput('');
    setAccessCodeError(null);
    setUnlockedTiers({});
  }, [event, initialTierId]);

  // A percentage discount depends on the subtotal it was validated against -
  // clear it if the tier or quantity changes so a stale amount can never be charged.
  useEffect(() => {
    setAppliedPromo(null);
    setPromoError(null);
  }, [tierId, quantity]);

  useEffect(() => {
    setAccessCodeInput('');
    setAccessCodeError(null);
  }, [tierId]);

  if (!event) return null;

  const selectedTier = event.ticket_tiers.find((t) => t.id === tierId);
  const isSelectedTierLocked = !!selectedTier?.requires_access_code && !unlockedTiers[tierId];
  const qty = parseInt(quantity, 10) || 0;
  const unitPriceCents = selectedTier
    ? selectedTier.requires_access_code
      ? (unlockedTiers[tierId]?.priceCents ?? 0)
      : selectedTier.price_cents
    : 0;
  const fullAmountCents = isSelectedTierLocked ? 0 : unitPriceCents * qty;
  const discountCents = appliedPromo?.discountCents ?? 0;
  const total = Math.max(0, fullAmountCents - discountCents) / 100;

  const handleUnlockTier = async () => {
    if (!accessCodeInput.trim() || !selectedTier) return;
    setApplyingAccessCode(true);
    setAccessCodeError(null);
    try {
      const { data, error } = await supabase.functions.invoke('validate-tier-access-code', {
        body: { tier_id: selectedTier.id, code: accessCodeInput },
      });
      if (error) throw error;
      if (!data?.valid) {
        setAccessCodeError(data?.message ?? 'Incorrect access code');
        return;
      }
      setUnlockedTiers((prev) => ({
        ...prev,
        [selectedTier.id]: { priceCents: data.price_cents, code: accessCodeInput.trim() },
      }));
      setAccessCodeInput('');
    } catch (err) {
      setAccessCodeError(err instanceof Error ? err.message : 'Could not validate access code');
    } finally {
      setApplyingAccessCode(false);
    }
  };

  const handleApplyPromo = async () => {
    if (!promoInput.trim() || !selectedTier) return;
    setApplyingPromo(true);
    setPromoError(null);
    try {
      const { data, error } = await supabase.functions.invoke('validate-promo-code', {
        body: {
          code: promoInput,
          applies_to: 'tickets',
          venue_id: event.venue_id ?? null,
          subtotal_cents: fullAmountCents,
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

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name || !email || !tierId || qty < 1) {
      toast({ title: 'Please fill in all required fields', variant: 'destructive' });
      return;
    }
    if (isSelectedTierLocked) {
      toast({ title: 'Enter the access code for this ticket type first', variant: 'destructive' });
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

    setSubmitting(true);
    try {
      const { data, error } = await supabase.functions.invoke('site-create-checkout-session', {
        body: {
          event_id: event.id,
          tier_id: tierId,
          quantity: qty,
          customer_name: name,
          customer_email: email,
          customer_phone: phone || null,
          promo_code: appliedPromo?.code,
          access_code: selectedTier?.requires_access_code ? unlockedTiers[tierId]?.code : undefined,
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
      <DialogContent className="border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">Book: {event.title}</DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="space-y-4">
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
            <p className="text-xs text-gray-500">Your ticket and QR code are sent here - please double-check it.</p>
          </div>
          <div className="space-y-2">
            <Label>Phone (optional)</Label>
            <Input type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Ticket Type</Label>
              <Select value={tierId} onValueChange={setTierId}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {event.ticket_tiers.map((tier) => {
                    const locked = tier.requires_access_code && !unlockedTiers[tier.id];
                    const unlockedPrice = unlockedTiers[tier.id]?.priceCents;
                    return (
                      <SelectItem key={tier.id} value={tier.id}>
                        {locked
                          ? `🔒 ${tier.name} - Locked`
                          : `${tier.name} - $${((unlockedPrice ?? tier.price_cents) / 100).toFixed(2)}`}
                      </SelectItem>
                    );
                  })}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label>Quantity</Label>
              <Input
                type="number"
                min="1"
                max="10"
                value={quantity}
                onChange={(e) => setQuantity(e.target.value)}
              />
            </div>
          </div>

          {selectedTier?.requires_access_code && (
            <div className="space-y-2">
              <Label className="flex items-center gap-1.5 text-sm">
                {isSelectedTierLocked ? <Lock className="h-3.5 w-3.5" /> : <Unlock className="h-3.5 w-3.5 text-green-400" />}
                Access Code
              </Label>
              {isSelectedTierLocked ? (
                <>
                  <div className="flex gap-2">
                    <Input
                      value={accessCodeInput}
                      onChange={(e) => {
                        setAccessCodeInput(e.target.value);
                        setAccessCodeError(null);
                      }}
                      placeholder="Enter access code"
                      className="font-mono"
                    />
                    <Button
                      type="button"
                      variant="outline"
                      className="shrink-0"
                      disabled={applyingAccessCode || !accessCodeInput.trim()}
                      onClick={handleUnlockTier}
                    >
                      {applyingAccessCode ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Unlock'}
                    </Button>
                  </div>
                  {accessCodeError && <p className="text-xs text-red-400">{accessCodeError}</p>}
                  <p className="text-xs text-gray-500">This ticket type is invite-only. Contact the organizer for a code.</p>
                </>
              ) : (
                <p className="text-xs text-green-400">Access code accepted - price unlocked below.</p>
              )}
            </div>
          )}

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
                  className="shrink-0"
                  disabled={applyingPromo || !promoInput.trim()}
                  onClick={handleApplyPromo}
                >
                  {applyingPromo ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Apply'}
                </Button>
              </div>
            )}
            {promoError && <p className="text-xs text-red-400">{promoError}</p>}
          </div>

          <div className="space-y-1 text-right">
            {discountCents > 0 && (
              <div className="text-sm text-green-400">
                -${(discountCents / 100).toFixed(2)} promo discount
              </div>
            )}
            <div className="text-lg font-semibold text-white">
              {isSelectedTierLocked ? 'Total: Enter access code to see price' : `Total: $${total.toFixed(2)}`}
            </div>
          </div>

          <DialogFooter>
            <Button
              type="submit"
              disabled={submitting || isSelectedTierLocked}
              className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
            >
              {submitting
                ? 'Redirecting to checkout...'
                : isSelectedTierLocked
                  ? 'Enter access code to continue'
                  : 'Continue to Payment'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
};

export default BookingDialog;
