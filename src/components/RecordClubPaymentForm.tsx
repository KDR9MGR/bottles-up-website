import { useState } from 'react';
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
import { Plus, X } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import {
  recordClubPayment,
  uploadReceiptPhoto,
  type ClubPaymentMethod,
  type SplitLeg,
  type SplitLegMethod,
} from '@/lib/clubPayment';

const money = (cents: number, currency = 'CAD') => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;
const dollarsToCents = (v: string) => Math.round((parseFloat(v) || 0) * 100);

interface RecordClubPaymentFormProps {
  bookingId: string;
  balanceDueCents: number;
  currency: string;
  customerName?: string;
  customerEmail?: string;
  onRecorded: (result: { newAmountPaidCents: number; confirmationEmailSent: boolean }) => void;
}

// Bottle Payment Options section 5 (original spec) + BottlesUp Server and
// Pay-at-Club system section 5 (restructured fields) in one place - the
// CMS booking sheet, the door check-in screen, and the staff Open Table
// screen all render this exact same component now instead of three
// separately drifting copies of the same form. Bottle subtotal / discount /
// tax / gratuity are informational line items staff transcribe from the
// venue's own POS receipt - the Final Billed Amount stays independently
// editable rather than a locked computed sum, since the receipt's own
// total is the source of truth, not arithmetic that might not match it to
// the cent (rounding, a line the venue comped, etc).
const RecordClubPaymentForm = ({
  bookingId,
  balanceDueCents,
  currency,
  customerName,
  customerEmail,
  onRecorded,
}: RecordClubPaymentFormProps) => {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [bottleSubtotal, setBottleSubtotal] = useState('');
  const [discount, setDiscount] = useState('');
  const [tax, setTax] = useState('');
  const [gratuity, setGratuity] = useState('');
  const [billedAmount, setBilledAmount] = useState('');
  const [paidAmount, setPaidAmount] = useState('');
  const [paymentMethod, setPaymentMethod] = useState<ClubPaymentMethod>('cash');
  const [splitLegs, setSplitLegs] = useState<SplitLeg[]>([{ method: 'cash', amountCents: 0 }]);
  const [posReference, setPosReference] = useState('');
  const [receiptFile, setReceiptFile] = useState<File | null>(null);
  const [payerName, setPayerName] = useState('');
  const [payerEmail, setPayerEmail] = useState('');
  const [recording, setRecording] = useState(false);

  const suggestedBilledCents =
    dollarsToCents(bottleSubtotal) - dollarsToCents(discount) + dollarsToCents(tax) + dollarsToCents(gratuity);

  const openForm = () => {
    const dollars = (balanceDueCents / 100).toFixed(2);
    setBilledAmount(dollars);
    setPaidAmount(dollars);
    setOpen(true);
  };

  const reset = () => {
    setOpen(false);
    setBottleSubtotal('');
    setDiscount('');
    setTax('');
    setGratuity('');
    setBilledAmount('');
    setPaidAmount('');
    setPaymentMethod('cash');
    setSplitLegs([{ method: 'cash', amountCents: 0 }]);
    setPosReference('');
    setReceiptFile(null);
    setPayerName('');
    setPayerEmail('');
  };

  const updateSplitLeg = (index: number, patch: Partial<SplitLeg>) =>
    setSplitLegs((prev) => prev.map((leg, i) => (i === index ? { ...leg, ...patch } : leg)));
  const addSplitLeg = () => setSplitLegs((prev) => [...prev, { method: 'cash', amountCents: 0 }]);
  const removeSplitLeg = (index: number) => setSplitLegs((prev) => prev.filter((_, i) => i !== index));

  const handleSubmit = async () => {
    if (recording) return;
    const billedCents = dollarsToCents(billedAmount);
    const paidCents = dollarsToCents(paidAmount);
    if (billedCents < 0 || paidCents <= 0) {
      toast({ title: 'Enter a valid amount', variant: 'destructive' });
      return;
    }

    setRecording(true);
    try {
      let receiptPhotoPath: string | null = null;
      if (receiptFile) {
        receiptPhotoPath = await uploadReceiptPhoto(bookingId, receiptFile);
      }
      const splitBreakdown = paymentMethod === 'split' ? splitLegs.filter((leg) => leg.amountCents > 0) : null;

      const { newAmountPaidCents, confirmationEmailSent } = await recordClubPayment({
        bookingId,
        billedAmountCents: billedCents,
        amountPaidCents: paidCents,
        paymentMethod,
        splitBreakdown,
        posReference: posReference.trim() || null,
        receiptPhotoPath,
        payerName: payerName.trim() || null,
        payerEmail: payerEmail.trim() || null,
        bottleSubtotalCents: dollarsToCents(bottleSubtotal),
        discountCents: dollarsToCents(discount),
        taxCents: dollarsToCents(tax),
        gratuityCents: dollarsToCents(gratuity),
      });

      toast({
        title: 'Payment recorded',
        description: `Paid so far: ${money(newAmountPaidCents, currency)}${confirmationEmailSent ? '' : ' - could not email the customer'}`,
      });
      reset();
      onRecorded({ newAmountPaidCents, confirmationEmailSent });
    } catch (err) {
      toast({
        title: 'Failed to record payment',
        description: err instanceof Error ? err.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setRecording(false);
    }
  };

  if (!open) {
    return (
      <Button variant="outline" className="w-full border-orange-500/40 text-orange-400 hover:bg-orange-500/10" onClick={openForm}>
        Record Club Payment
      </Button>
    );
  }

  return (
    <div className="space-y-3">
      <Label className="text-sm text-white">Record Club Payment</Label>

      <div className="grid grid-cols-2 gap-2">
        <div className="space-y-1">
          <Label className="text-xs">Bottle subtotal</Label>
          <Input type="number" min="0" step="0.01" value={bottleSubtotal} onChange={(e) => setBottleSubtotal(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label className="text-xs">Discount (if any)</Label>
          <Input type="number" min="0" step="0.01" value={discount} onChange={(e) => setDiscount(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label className="text-xs">Tax</Label>
          <Input type="number" min="0" step="0.01" value={tax} onChange={(e) => setTax(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label className="text-xs">Gratuity</Label>
          <Input type="number" min="0" step="0.01" value={gratuity} onChange={(e) => setGratuity(e.target.value)} />
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <div className="space-y-1">
          <div className="flex items-center justify-between">
            <Label className="text-xs">Final billed amount</Label>
            {suggestedBilledCents > 0 && (
              <button
                type="button"
                className="text-[10px] text-gray-500 underline hover:text-gray-300"
                onClick={() => setBilledAmount((suggestedBilledCents / 100).toFixed(2))}
              >
                use {money(suggestedBilledCents, currency)}
              </button>
            )}
          </div>
          <Input type="number" min="0" step="0.01" value={billedAmount} onChange={(e) => setBilledAmount(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label className="text-xs">Amount received</Label>
          <Input type="number" min="0" step="0.01" value={paidAmount} onChange={(e) => setPaidAmount(e.target.value)} />
        </div>
      </div>

      <div className="space-y-1">
        <Label className="text-xs">Payment method</Label>
        <Select value={paymentMethod} onValueChange={(v) => setPaymentMethod(v as ClubPaymentMethod)}>
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="cash">Cash</SelectItem>
            <SelectItem value="debit">Debit</SelectItem>
            <SelectItem value="credit">Credit</SelectItem>
            <SelectItem value="split">Split payment</SelectItem>
          </SelectContent>
        </Select>
      </div>

      {paymentMethod === 'split' && (
        <div className="space-y-2">
          {splitLegs.map((leg, i) => (
            <div key={i} className="flex items-center gap-2">
              <Select value={leg.method} onValueChange={(v) => updateSplitLeg(i, { method: v as SplitLegMethod })}>
                <SelectTrigger className="w-28">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="cash">Cash</SelectItem>
                  <SelectItem value="debit">Debit</SelectItem>
                  <SelectItem value="credit">Credit</SelectItem>
                </SelectContent>
              </Select>
              <Input
                type="number"
                min="0"
                step="0.01"
                placeholder="Amount"
                value={leg.amountCents ? (leg.amountCents / 100).toString() : ''}
                onChange={(e) => updateSplitLeg(i, { amountCents: dollarsToCents(e.target.value) })}
              />
              {splitLegs.length > 1 && (
                <Button type="button" variant="ghost" size="icon" onClick={() => removeSplitLeg(i)}>
                  <X className="h-4 w-4" />
                </Button>
              )}
            </div>
          ))}
          <Button type="button" variant="outline" size="sm" className="border-gray-700" onClick={addSplitLeg}>
            <Plus className="mr-1 h-3 w-3" /> Add method
          </Button>
        </div>
      )}

      <div className="space-y-1">
        <Label className="text-xs">POS receipt / reference number (optional)</Label>
        <Input value={posReference} onChange={(e) => setPosReference(e.target.value)} />
      </div>

      <div className="space-y-1">
        <Label className="text-xs">Receipt photo (optional)</Label>
        <Input type="file" accept="image/*" onChange={(e) => setReceiptFile(e.target.files?.[0] ?? null)} />
      </div>

      <div className="grid grid-cols-2 gap-2">
        <div className="space-y-1">
          <Label className="text-xs">Paid by (optional{customerName ? ` - if not ${customerName}` : ''})</Label>
          <Input placeholder="Payer name" value={payerName} onChange={(e) => setPayerName(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label className="text-xs">Payer email (optional)</Label>
          <Input type="email" placeholder="Payer email" value={payerEmail} onChange={(e) => setPayerEmail(e.target.value)} />
        </div>
      </div>
      {payerName.trim() && (
        <p className="text-[11px] text-gray-500">
          Split payments: this confirmation email goes to {payerEmail.trim() || 'the payer'}{customerEmail ? `, not ${customerEmail}` : ''}.
        </p>
      )}

      <div className="flex gap-2">
        <Button variant="outline" className="flex-1 border-gray-700" onClick={reset}>
          Cancel
        </Button>
        <Button
          className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90"
          disabled={recording}
          onClick={handleSubmit}
        >
          {recording ? 'Saving...' : 'Record Payment'}
        </Button>
      </div>
    </div>
  );
};

export default RecordClubPaymentForm;
