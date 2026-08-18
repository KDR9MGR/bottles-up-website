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
import { Switch } from '@/components/ui/switch';
import { Checkbox } from '@/components/ui/checkbox';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

type PromoCodeRow = Database['public']['Tables']['promo_codes']['Row'];
type VenueOption = { id: string; name: string };

interface Props {
  promoCode: PromoCodeRow | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}

const toDateInputValue = (iso: string | null) => (iso ? iso.slice(0, 10) : '');

const PromoCodeFormDialog = ({ promoCode, open, onOpenChange, onSaved }: Props) => {
  const { toast } = useToast();
  const [venues, setVenues] = useState<VenueOption[]>([]);
  const [saving, setSaving] = useState(false);

  const [code, setCode] = useState('');
  const [description, setDescription] = useState('');
  const [discountType, setDiscountType] = useState<'percentage' | 'fixed_amount'>('percentage');
  const [discountValue, setDiscountValue] = useState('');
  const [appliesTo, setAppliesTo] = useState<'both' | 'tickets' | 'tables'>('both');
  const [maxUses, setMaxUses] = useState('');
  const [minPurchase, setMinPurchase] = useState('');
  const [startsAt, setStartsAt] = useState('');
  const [expiresAt, setExpiresAt] = useState('');
  const [isActive, setIsActive] = useState(true);
  const [selectedVenueIds, setSelectedVenueIds] = useState<Set<string>>(new Set());

  useEffect(() => {
    if (!open) return;
    supabase
      .from('site_venues')
      .select('id, name')
      .order('name', { ascending: true })
      .then(({ data }) => setVenues(data ?? []));
  }, [open]);

  useEffect(() => {
    if (!open) return;

    if (promoCode) {
      setCode(promoCode.code);
      setDescription(promoCode.description ?? '');
      setDiscountType(promoCode.discount_type as 'percentage' | 'fixed_amount');
      setDiscountValue(
        promoCode.discount_type === 'fixed_amount'
          ? (promoCode.discount_value / 100).toString()
          : promoCode.discount_value.toString(),
      );
      setAppliesTo(promoCode.applies_to as 'both' | 'tickets' | 'tables');
      setMaxUses(promoCode.max_uses?.toString() ?? '');
      setMinPurchase(promoCode.min_purchase_cents ? (promoCode.min_purchase_cents / 100).toString() : '');
      setStartsAt(toDateInputValue(promoCode.starts_at));
      setExpiresAt(toDateInputValue(promoCode.expires_at));
      setIsActive(promoCode.is_active);

      supabase
        .from('promo_code_venues')
        .select('venue_id')
        .eq('promo_code_id', promoCode.id)
        .then(({ data }) => setSelectedVenueIds(new Set((data ?? []).map((r) => r.venue_id))));
    } else {
      setCode('');
      setDescription('');
      setDiscountType('percentage');
      setDiscountValue('');
      setAppliesTo('both');
      setMaxUses('');
      setMinPurchase('');
      setStartsAt('');
      setExpiresAt('');
      setIsActive(true);
      setSelectedVenueIds(new Set());
    }
  }, [promoCode, open]);

  const toggleVenue = (id: string) =>
    setSelectedVenueIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const normalizedCode = code.trim().toUpperCase();
    const value = parseFloat(discountValue);

    if (!normalizedCode || !/^[A-Z0-9_-]+$/.test(normalizedCode)) {
      toast({ title: 'Enter a valid code', description: 'Letters, numbers, dashes, and underscores only.', variant: 'destructive' });
      return;
    }
    if (!Number.isFinite(value) || value <= 0) {
      toast({ title: 'Enter a discount value greater than 0', variant: 'destructive' });
      return;
    }
    if (discountType === 'percentage' && value > 100) {
      toast({ title: 'Percentage discount can\'t exceed 100', variant: 'destructive' });
      return;
    }

    setSaving(true);
    try {
      const payload = {
        code: normalizedCode,
        description: description.trim() || null,
        discount_type: discountType,
        discount_value: discountType === 'fixed_amount' ? Math.round(value * 100) : value,
        applies_to: appliesTo,
        max_uses: maxUses ? parseInt(maxUses, 10) : null,
        min_purchase_cents: minPurchase ? Math.round(parseFloat(minPurchase) * 100) : null,
        starts_at: startsAt ? new Date(`${startsAt}T00:00:00`).toISOString() : null,
        expires_at: expiresAt ? new Date(`${expiresAt}T23:59:59`).toISOString() : null,
        is_active: isActive,
      };

      let promoCodeId = promoCode?.id;

      if (promoCode) {
        const { error } = await supabase.from('promo_codes').update(payload).eq('id', promoCode.id);
        if (error) throw error;
      } else {
        const { data, error } = await supabase.from('promo_codes').insert(payload).select('id').single();
        if (error) throw error;
        promoCodeId = data.id;
      }

      // Replace the venue linkage wholesale - simplest correct way to sync a
      // checkbox list against a join table without diffing add/remove sets.
      await supabase.from('promo_code_venues').delete().eq('promo_code_id', promoCodeId);
      if (selectedVenueIds.size > 0) {
        const { error: venuesError } = await supabase.from('promo_code_venues').insert(
          Array.from(selectedVenueIds).map((venue_id) => ({ promo_code_id: promoCodeId, venue_id })),
        );
        if (venuesError) throw venuesError;
      }

      toast({ title: promoCode ? 'Promo code updated' : 'Promo code created' });
      onOpenChange(false);
      onSaved();
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Please try again.';
      const friendly = message.includes('duplicate key') ? 'That code already exists.' : message;
      toast({ title: 'Failed to save promo code', description: friendly, variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">{promoCode ? 'Edit Promo Code' : 'New Promo Code'}</DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label>Code</Label>
            <Input
              value={code}
              onChange={(e) => setCode(e.target.value.toUpperCase())}
              placeholder="SUMMER20"
              className="font-mono uppercase"
              required
            />
          </div>

          <div className="space-y-2">
            <Label>Description (internal only)</Label>
            <Input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Summer promo for regulars" />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Discount Type</Label>
              <Select value={discountType} onValueChange={(v) => setDiscountType(v as typeof discountType)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="percentage">Percentage off</SelectItem>
                  <SelectItem value="fixed_amount">Fixed amount off</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label>{discountType === 'percentage' ? 'Percent off' : 'Amount off ($)'}</Label>
              <Input
                type="number"
                min="0"
                step={discountType === 'percentage' ? '1' : '0.01'}
                max={discountType === 'percentage' ? '100' : undefined}
                value={discountValue}
                onChange={(e) => setDiscountValue(e.target.value)}
                placeholder={discountType === 'percentage' ? '20' : '10.00'}
                required
              />
            </div>
          </div>

          <div className="space-y-2">
            <Label>Applies To</Label>
            <Select value={appliesTo} onValueChange={(v) => setAppliesTo(v as typeof appliesTo)}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="both">Event tickets &amp; VIP tables</SelectItem>
                <SelectItem value="tickets">Event tickets only</SelectItem>
                <SelectItem value="tables">VIP tables only</SelectItem>
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label>Venues</Label>
            <div className="max-h-40 space-y-2 overflow-y-auto rounded-lg border border-gray-800 p-3">
              {venues.length === 0 ? (
                <p className="text-sm text-gray-500">No venues yet.</p>
              ) : (
                venues.map((venue) => (
                  <label key={venue.id} className="flex items-center gap-2 text-sm text-gray-300">
                    <Checkbox
                      checked={selectedVenueIds.has(venue.id)}
                      onCheckedChange={() => toggleVenue(venue.id)}
                    />
                    {venue.name}
                  </label>
                ))
              )}
            </div>
            <p className="text-xs text-gray-500">Leave all unchecked to apply this code at every venue.</p>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Max Uses (optional)</Label>
              <Input type="number" min="1" value={maxUses} onChange={(e) => setMaxUses(e.target.value)} placeholder="Unlimited" />
            </div>
            <div className="space-y-2">
              <Label>Min Purchase $ (optional)</Label>
              <Input type="number" min="0" step="0.01" value={minPurchase} onChange={(e) => setMinPurchase(e.target.value)} placeholder="None" />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Starts (optional)</Label>
              <Input type="date" value={startsAt} onChange={(e) => setStartsAt(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>Expires (optional)</Label>
              <Input type="date" value={expiresAt} onChange={(e) => setExpiresAt(e.target.value)} />
            </div>
          </div>

          <div className="flex items-center justify-between rounded-lg border border-gray-800 p-3">
            <div>
              <Label>Active</Label>
              <p className="text-xs text-gray-500">Inactive codes are rejected at checkout immediately.</p>
            </div>
            <Switch checked={isActive} onCheckedChange={setIsActive} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={saving} className="w-full bg-gradient-orange text-black font-bold hover:opacity-90">
              {saving ? 'Saving...' : promoCode ? 'Save Changes' : 'Create Promo Code'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
};

export default PromoCodeFormDialog;
