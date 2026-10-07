import { useState } from 'react';
import { Loader2, Star } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Switch } from '@/components/ui/switch';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';
import { listVenueTableTypes, removeVenueTableType, saveVenueTableType } from '@/lib/venueSetupApi';
import {
  describeTablePrice, EMPTY_TABLE_TYPE_FORM, tableTypeForm, tableTypePayload, validateTableTypeForm,
  type TableTypeForm, type TableTypeRow,
} from '@/lib/venueSetupForms';
import NativeSelect from '../components/NativeSelect';
import ConfirmRemove from './ConfirmRemove';
import ImageField from './ImageField';
import { errorMessage, useLoad } from './useLoad';

interface Props {
  orgId: string;
  venueId: string;
  onChanged: () => void;
}

interface DialogProps {
  orgId: string;
  idPrefix: string;
  initial: TableTypeForm;
  title: string;
  busy: boolean;
  onSubmit: (payload: Record<string, unknown>) => void;
  onClose: () => void;
}

const Field = ({ id, label, hint, children }: { id: string; label: string; hint?: string; children: React.ReactNode }) => (
  <div className="space-y-2">
    <Label htmlFor={id} className="text-gray-300">{label}</Label>
    {children}
    {hint && <p className="text-xs text-gray-500">{hint}</p>}
  </div>
);

const TableTypeDialog = ({ orgId, idPrefix, initial, title, busy, onSubmit, onClose }: DialogProps) => {
  const [form, setForm] = useState<TableTypeForm>(initial);
  const [problems, setProblems] = useState<string[]>([]);
  const set = <K extends keyof TableTypeForm>(key: K, value: TableTypeForm[K]) => setForm((f) => ({ ...f, [key]: value }));
  const id = (name: string) => `${idPrefix}-${name}`;

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const found = validateTableTypeForm(form);
    setProblems(found);
    if (found.length === 0) onSubmit(tableTypePayload(form));
  };

  return (
    <Dialog open onOpenChange={(open) => { if (!open && !busy) onClose(); }}>
      <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">{title}</DialogTitle>
          <DialogDescription className="text-gray-400">What guests see and pay when they book this kind of table.</DialogDescription>
        </DialogHeader>
        <form onSubmit={submit} className="space-y-4" noValidate>
          <Field id={id('name')} label="Name">
            <Input id={id('name')} value={form.name} onChange={(e) => set('name', e.target.value)} maxLength={120} placeholder="VIP booth" />
          </Field>
          <Field id={id('description')} label="Description (optional)">
            <Textarea id={id('description')} value={form.description} onChange={(e) => set('description', e.target.value)} rows={2} maxLength={2000} />
          </Field>
          <div className="grid gap-4 sm:grid-cols-3">
            <Field id={id('max')} label="Maximum guests">
              <Input id={id('max')} inputMode="numeric" value={form.maxGuests} onChange={(e) => set('maxGuests', e.target.value)} placeholder="8" />
            </Field>
            <Field id={id('min')} label="Minimum guests" hint="Optional">
              <Input id={id('min')} inputMode="numeric" value={form.minGuests} onChange={(e) => set('minGuests', e.target.value)} />
            </Field>
            <Field id={id('count')} label="Number of tables" hint="How many of this kind you have. 0 stops bookings.">
              <Input id={id('count')} inputMode="numeric" value={form.inventoryCount} onChange={(e) => set('inventoryCount', e.target.value)} />
            </Field>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field id={id('spend')} label="Minimum spend ($)" hint="Leave empty for none.">
              <Input id={id('spend')} inputMode="decimal" value={form.minSpend} onChange={(e) => set('minSpend', e.target.value)} placeholder="1500" />
            </Field>
            <Field id={id('deposit')} label="Deposit ($)" hint="Paid when booking. Leave empty for none.">
              <Input id={id('deposit')} inputMode="decimal" value={form.deposit} onChange={(e) => set('deposit', e.target.value)} placeholder="500" />
            </Field>
          </div>
          <Field id={id('mode')} label="Pricing">
            <NativeSelect id={id('mode')} value={form.pricingMode} onChange={(e) => set('pricingMode', e.target.value === 'hourly' ? 'hourly' : 'flat')}>
              <option value="flat">One price for the night (minimum spend and deposit)</option>
              <option value="hourly">Charged by the hour</option>
            </NativeSelect>
          </Field>
          {form.pricingMode === 'hourly' && (
            <div className="grid gap-4 sm:grid-cols-2">
              <Field id={id('rate')} label="Hourly rate ($)">
                <Input id={id('rate')} inputMode="decimal" value={form.hourlyRate} onChange={(e) => set('hourlyRate', e.target.value)} placeholder="200" />
              </Field>
              <Field id={id('hours')} label="Minimum hours" hint="Empty means 1.">
                <Input id={id('hours')} inputMode="numeric" value={form.minHours} onChange={(e) => set('minHours', e.target.value)} />
              </Field>
            </div>
          )}
          <div className="grid gap-4 sm:grid-cols-2">
            <Field id={id('badge')} label="Badge (optional)" hint='A short label such as "Popular" or "Best view".'>
              <Input id={id('badge')} value={form.badgeLabel} onChange={(e) => set('badgeLabel', e.target.value)} maxLength={40} />
            </Field>
            <div className="flex items-center justify-between gap-3 rounded-lg border border-gray-800 px-3 py-2">
              <Label htmlFor={id('featured')} className="text-gray-300">Feature this table</Label>
              <Switch id={id('featured')} checked={form.isFeatured} onCheckedChange={(v) => set('isFeatured', v)} />
            </div>
          </div>
          <ImageField id={id('image')} label="Photo (optional)" orgId={orgId} value={form.imageUrl} onChange={(url) => set('imageUrl', url)} />
          <p className="text-xs text-gray-500">Where this table sits on the floor plan, its seating, view and amenities are set up by the BottlesUp team for now.</p>
          {problems.length > 0 && (
            <ul className="space-y-1 rounded-lg border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-200" role="alert">
              {problems.map((p) => <li key={p}>{p}</li>)}
            </ul>
          )}
          <div className="flex gap-2">
            <Button type="submit" disabled={busy} className="bg-gradient-orange font-bold text-black hover:opacity-90">
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Save table'}
            </Button>
            <Button type="button" variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
};

/** The kinds of table guests can book (VIP booth, dance floor table...), each with its own capacity and price. */
const TableTypesEditor = ({ orgId, venueId, onChanged }: Props) => {
  const { toast } = useToast();
  const { data: types, error, reload } = useLoad(() => listVenueTableTypes(venueId), venueId);
  const [editing, setEditing] = useState<TableTypeRow | 'new' | null>(null);
  const [removing, setRemoving] = useState<TableTypeRow | null>(null);
  const [busy, setBusy] = useState(false);

  const save = async (typeId: string | null, payload: Record<string, unknown>) => {
    setBusy(true);
    try {
      await saveVenueTableType(venueId, typeId, payload);
      toast({ title: typeId ? 'Table saved' : 'Table added' });
      setEditing(null);
      await reload();
      onChanged();
    } catch (err) {
      toast({ title: 'Could not save the table', description: errorMessage(err), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const confirmRemove = async () => {
    if (!removing) return;
    setBusy(true);
    try {
      await removeVenueTableType(venueId, removing.typeId);
      toast({ title: 'Table removed' });
      setRemoving(null);
      await reload();
      onChanged();
    } catch (err) {
      toast({ title: 'Could not remove the table', description: errorMessage(err), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  if (error) return <p className="text-sm text-red-300" role="alert">{error}</p>;
  if (!types) return <p className="text-sm text-gray-500">Loading tables…</p>;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-gray-400">Each kind of table has its own capacity, minimum spend and deposit.</p>
        <Button type="button" onClick={() => setEditing('new')} className="bg-gradient-orange font-bold text-black hover:opacity-90">Add a table</Button>
      </div>

      {types.length === 0 && <p className="rounded-xl border border-dashed border-gray-800 p-6 text-center text-sm text-gray-400">No tables yet. Add the first kind of table guests can book.</p>}

      <ul className="space-y-3">
        {types.map((t) => (
          <li key={t.typeId} className="rounded-xl border border-gray-800 p-4">
            <div className="flex flex-wrap items-start gap-4">
              {t.imageUrl && <img src={t.imageUrl} alt="" className="h-16 w-16 shrink-0 rounded-md border border-gray-800 object-cover" />}
              <div className="min-w-[12rem] flex-1">
                <p className="flex flex-wrap items-center gap-2 font-medium text-white">
                  {t.name}
                  {t.isFeatured && <Star className="h-4 w-4 fill-amber-400 text-amber-400" aria-label="Featured" />}
                  {t.badgeLabel && <span className="rounded-full border border-gray-700 px-2 py-0.5 text-xs font-normal text-gray-300">{t.badgeLabel}</span>}
                </p>
                <p className="mt-0.5 text-sm text-gray-300">{describeTablePrice(t)}</p>
                <p className="mt-0.5 text-xs text-gray-500">
                  {t.minGuests ? `${t.minGuests} to ${t.maxGuests}` : `Up to ${t.maxGuests}`} guests · {t.inventoryCount === 0 ? 'none available to book' : `${t.inventoryCount} ${t.inventoryCount === 1 ? 'table' : 'tables'}`}
                  {t.floorId ? ' · placed on a floor plan' : ''}
                  {t.bookingCount > 0 ? ` · ${t.bookingCount} ${t.bookingCount === 1 ? 'booking' : 'bookings'}` : ''}
                </p>
              </div>
              <div className="flex gap-2">
                <Button type="button" variant="outline" size="sm" onClick={() => setEditing(t)}>Edit</Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="text-red-400 hover:text-red-300"
                  disabled={t.bookingCount > 0}
                  title={t.bookingCount > 0 ? 'It has bookings, so it cannot be removed. Set the number of tables to 0 to stop new bookings.' : undefined}
                  onClick={() => setRemoving(t)}
                >
                  Remove
                </Button>
              </div>
            </div>
          </li>
        ))}
      </ul>

      {editing && (
        <TableTypeDialog
          key={editing === 'new' ? 'new' : editing.typeId}
          orgId={orgId}
          idPrefix={`tt-${editing === 'new' ? 'new' : editing.typeId}`}
          initial={editing === 'new' ? EMPTY_TABLE_TYPE_FORM : tableTypeForm(editing)}
          title={editing === 'new' ? 'Add a table' : `Edit ${editing.name}`}
          busy={busy}
          onSubmit={(payload) => void save(editing === 'new' ? null : editing.typeId, payload)}
          onClose={() => setEditing(null)}
        />
      )}

      <ConfirmRemove
        open={removing !== null}
        title={`Remove ${removing?.name ?? 'this table'}?`}
        description="Guests will no longer be able to book it. This cannot be undone."
        busy={busy}
        onConfirm={() => void confirmRemove()}
        onClose={() => setRemoving(null)}
      />
    </div>
  );
};

export default TableTypesEditor;
