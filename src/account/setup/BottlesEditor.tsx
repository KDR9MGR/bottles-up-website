import { useState } from 'react';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Switch } from '@/components/ui/switch';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';
import { listVenueBottles, removeVenueBottle, saveVenueBottle } from '@/lib/venueSetupApi';
import {
  bottleForm, bottlePayload, bottleStatus, EMPTY_BOTTLE_FORM, formatMoney, validateBottleForm,
  type BottleForm, type BottleRow,
} from '@/lib/venueSetupForms';
import ConfirmRemove from './ConfirmRemove';
import ImageField from './ImageField';
import { errorMessage, useLoad } from './useLoad';

interface Props {
  orgId: string;
  venueId: string;
  onChanged: () => void;
}

const Field = ({ id, label, hint, children }: { id: string; label: string; hint?: string; children: React.ReactNode }) => (
  <div className="space-y-2">
    <Label htmlFor={id} className="text-gray-300">{label}</Label>
    {children}
    {hint && <p className="text-xs text-gray-500">{hint}</p>}
  </div>
);

interface DialogProps {
  orgId: string;
  idPrefix: string;
  initial: BottleForm;
  title: string;
  busy: boolean;
  onSubmit: (payload: Record<string, unknown>) => void;
  onClose: () => void;
}

const BottleDialog = ({ orgId, idPrefix, initial, title, busy, onSubmit, onClose }: DialogProps) => {
  const [form, setForm] = useState<BottleForm>(initial);
  const [problems, setProblems] = useState<string[]>([]);
  const set = <K extends keyof BottleForm>(key: K, value: BottleForm[K]) => setForm((f) => ({ ...f, [key]: value }));
  const id = (name: string) => `${idPrefix}-${name}`;

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const found = validateBottleForm(form);
    setProblems(found);
    if (found.length === 0) onSubmit(bottlePayload(form));
  };

  return (
    <Dialog open onOpenChange={(open) => { if (!open && !busy) onClose(); }}>
      <DialogContent className="max-h-[90vh] max-w-xl overflow-y-auto border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">{title}</DialogTitle>
          <DialogDescription className="text-gray-400">A bottle guests can pre-order for their table or add at the club.</DialogDescription>
        </DialogHeader>
        <form onSubmit={submit} className="space-y-4" noValidate>
          <Field id={id('name')} label="Name">
            <Input id={id('name')} value={form.name} onChange={(e) => set('name', e.target.value)} maxLength={120} placeholder="Grey Goose" />
          </Field>
          <div className="grid gap-4 sm:grid-cols-3">
            <Field id={id('price')} label="Price ($)">
              <Input id={id('price')} inputMode="decimal" value={form.price} onChange={(e) => set('price', e.target.value)} placeholder="195" />
            </Field>
            <Field id={id('size')} label="Size" hint="Optional">
              <Input id={id('size')} value={form.size} onChange={(e) => set('size', e.target.value)} maxLength={40} placeholder="750ml" />
            </Field>
            <Field id={id('category')} label="Category" hint="Optional">
              <Input id={id('category')} value={form.category} onChange={(e) => set('category', e.target.value)} maxLength={40} placeholder="Vodka" />
            </Field>
          </div>
          <Field id={id('description')} label="Description (optional)">
            <Textarea id={id('description')} value={form.description} onChange={(e) => set('description', e.target.value)} rows={2} maxLength={1000} />
          </Field>
          <Field id={id('stock')} label="Stock (optional)" hint="Leave empty if you do not count bottles. Guests cannot order more than you have.">
            <Input id={id('stock')} inputMode="numeric" value={form.stock} onChange={(e) => set('stock', e.target.value)} />
          </Field>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="flex items-center justify-between gap-3 rounded-lg border border-gray-800 px-3 py-2">
              <Label htmlFor={id('available')} className="text-gray-300">On the menu</Label>
              <Switch id={id('available')} checked={form.isAvailable} onCheckedChange={(v) => set('isAvailable', v)} />
            </div>
            <div className="flex items-center justify-between gap-3 rounded-lg border border-gray-800 px-3 py-2">
              <Label htmlFor={id('soldout')} className="text-gray-300">Sold out</Label>
              <Switch id={id('soldout')} checked={form.isSoldOut} onCheckedChange={(v) => set('isSoldOut', v)} />
            </div>
          </div>
          <ImageField id={id('image')} label="Photo (optional)" orgId={orgId} value={form.imageUrl} onChange={(url) => set('imageUrl', url)} />
          {problems.length > 0 && (
            <ul className="space-y-1 rounded-lg border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-200" role="alert">
              {problems.map((p) => <li key={p}>{p}</li>)}
            </ul>
          )}
          <div className="flex gap-2">
            <Button type="submit" disabled={busy} className="bg-gradient-orange font-bold text-black hover:opacity-90">
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Save bottle'}
            </Button>
            <Button type="button" variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
};

const STATUS_STYLE: Record<ReturnType<typeof bottleStatus>, { label: string; className: string }> = {
  available: { label: 'On menu', className: 'border-green-500/40 text-green-300' },
  sold_out: { label: 'Sold out', className: 'border-amber-500/40 text-amber-300' },
  off_menu: { label: 'Off the menu', className: 'border-gray-700 text-gray-400' },
};

/** The bottles guests can order. Taking one off the menu or marking it sold out is one tap, without opening the form. */
const BottlesEditor = ({ orgId, venueId, onChanged }: Props) => {
  const { toast } = useToast();
  const { data: bottles, error, reload } = useLoad(() => listVenueBottles(venueId), venueId);
  const [editing, setEditing] = useState<BottleRow | 'new' | null>(null);
  const [removing, setRemoving] = useState<BottleRow | null>(null);
  const [busy, setBusy] = useState(false);

  const save = async (bottleId: string | null, payload: Record<string, unknown>, quiet = false) => {
    setBusy(true);
    try {
      await saveVenueBottle(venueId, bottleId, payload);
      if (!quiet) toast({ title: bottleId ? 'Bottle saved' : 'Bottle added' });
      setEditing(null);
      await reload();
      onChanged();
    } catch (err) {
      toast({ title: 'Could not save the bottle', description: errorMessage(err), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const confirmRemove = async () => {
    if (!removing) return;
    setBusy(true);
    try {
      await removeVenueBottle(venueId, removing.bottleId);
      toast({ title: 'Bottle removed' });
      setRemoving(null);
      await reload();
      onChanged();
    } catch (err) {
      toast({ title: 'Could not remove the bottle', description: errorMessage(err), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  if (error) return <p className="text-sm text-red-300" role="alert">{error}</p>;
  if (!bottles) return <p className="text-sm text-gray-500">Loading the bottle menu…</p>;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-gray-400">Bottles guests can order for their table.</p>
        <Button type="button" onClick={() => setEditing('new')} className="bg-gradient-orange font-bold text-black hover:opacity-90">Add a bottle</Button>
      </div>

      {bottles.length === 0 && <p className="rounded-xl border border-dashed border-gray-800 p-6 text-center text-sm text-gray-400">No bottles yet. Add the first one to start your menu.</p>}

      <ul className="space-y-3">
        {bottles.map((b) => {
          const status = STATUS_STYLE[bottleStatus(b)];
          return (
            <li key={b.bottleId} className="rounded-xl border border-gray-800 p-4">
              <div className="flex flex-wrap items-start gap-4">
                {b.imageUrl && <img src={b.imageUrl} alt="" className="h-16 w-16 shrink-0 rounded-md border border-gray-800 object-cover" />}
                <div className="min-w-[12rem] flex-1">
                  <p className="flex flex-wrap items-center gap-2 font-medium text-white">
                    {b.name}
                    {b.size && <span className="text-sm font-normal text-gray-400">{b.size}</span>}
                    <span className={`rounded-full border px-2 py-0.5 text-xs font-normal ${status.className}`}>{status.label}</span>
                  </p>
                  <p className="mt-0.5 text-sm text-gray-300">
                    {formatMoney(b.priceCents)}{b.category ? ` · ${b.category}` : ''}{b.stockQuantity !== null ? ` · ${b.stockQuantity} in stock` : ''}
                  </p>
                </div>
                <div className="flex items-center gap-4">
                  <label className="flex items-center gap-2 text-xs text-gray-400">
                    On menu
                    <Switch checked={b.isAvailable} disabled={busy} aria-label={`${b.name} on the menu`} onCheckedChange={(v) => void save(b.bottleId, { is_available: v }, true)} />
                  </label>
                  <label className="flex items-center gap-2 text-xs text-gray-400">
                    Sold out
                    <Switch checked={b.isSoldOut} disabled={busy} aria-label={`${b.name} sold out`} onCheckedChange={(v) => void save(b.bottleId, { is_sold_out: v }, true)} />
                  </label>
                  <div className="flex gap-2">
                    <Button type="button" variant="outline" size="sm" onClick={() => setEditing(b)}>Edit</Button>
                    <Button type="button" variant="ghost" size="sm" className="text-red-400 hover:text-red-300" onClick={() => setRemoving(b)}>Remove</Button>
                  </div>
                </div>
              </div>
            </li>
          );
        })}
      </ul>

      {editing && (
        <BottleDialog
          key={editing === 'new' ? 'new' : editing.bottleId}
          orgId={orgId}
          idPrefix={`bt-${editing === 'new' ? 'new' : editing.bottleId}`}
          initial={editing === 'new' ? EMPTY_BOTTLE_FORM : bottleForm(editing)}
          title={editing === 'new' ? 'Add a bottle' : `Edit ${editing.name}`}
          busy={busy}
          onSubmit={(payload) => void save(editing === 'new' ? null : editing.bottleId, payload)}
          onClose={() => setEditing(null)}
        />
      )}

      <ConfirmRemove
        open={removing !== null}
        title={`Remove ${removing?.name ?? 'this bottle'}?`}
        description="It leaves the menu. Past orders keep the name and price they were bought at."
        busy={busy}
        onConfirm={() => void confirmRemove()}
        onClose={() => setRemoving(null)}
      />
    </div>
  );
};

export default BottlesEditor;
