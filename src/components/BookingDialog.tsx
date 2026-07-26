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
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { EventWithTiers } from './PopularEvents';

interface BookingDialogProps {
  event: EventWithTiers | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const BookingDialog = ({ event, open, onOpenChange }: BookingDialogProps) => {
  const { toast } = useToast();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [confirmEmail, setConfirmEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [tierId, setTierId] = useState('');
  const [quantity, setQuantity] = useState('1');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (event && event.ticket_tiers.length > 0) {
      setTierId(event.ticket_tiers[0].id);
    }
    setName('');
    setEmail('');
    setConfirmEmail('');
    setPhone('');
    setQuantity('1');
  }, [event]);

  if (!event) return null;

  const selectedTier = event.ticket_tiers.find((t) => t.id === tierId);
  const qty = parseInt(quantity, 10) || 0;
  const total = selectedTier ? (selectedTier.price_cents * qty) / 100 : 0;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name || !email || !tierId || qty < 1) {
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
                  {event.ticket_tiers.map((tier) => (
                    <SelectItem key={tier.id} value={tier.id}>
                      {tier.name} - ${(tier.price_cents / 100).toFixed(2)}
                    </SelectItem>
                  ))}
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

          <div className="text-right text-lg font-semibold text-white">
            Total: ${total.toFixed(2)}
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

export default BookingDialog;
