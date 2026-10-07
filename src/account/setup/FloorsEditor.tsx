import { useState } from 'react';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { listVenueFloors, removeVenueFloor, saveVenueFloor } from '@/lib/venueSetupApi';
import { validateFloorForm, type FloorRow } from '@/lib/venueSetupForms';
import ConfirmRemove from './ConfirmRemove';
import ImageField from './ImageField';
import { errorMessage, useLoad } from './useLoad';

interface Props {
  orgId: string;
  venueId: string;
  onChanged: () => void;
}

interface FloorFormProps {
  orgId: string;
  idPrefix: string;
  initial: { label: string; imageUrl: string };
  submitLabel: string;
  busy: boolean;
  onSubmit: (label: string, imageUrl: string) => void;
  onCancel?: () => void;
}

const FloorForm = ({ orgId, idPrefix, initial, submitLabel, busy, onSubmit, onCancel }: FloorFormProps) => {
  const [label, setLabel] = useState(initial.label);
  const [imageUrl, setImageUrl] = useState(initial.imageUrl);
  const [problems, setProblems] = useState<string[]>([]);

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const found = validateFloorForm(label, imageUrl);
    setProblems(found);
    if (found.length === 0) onSubmit(label, imageUrl);
  };

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor={`${idPrefix}-label`} className="text-gray-300">Floor name</Label>
        <Input id={`${idPrefix}-label`} value={label} onChange={(e) => setLabel(e.target.value)} maxLength={60} placeholder="Main room" />
      </div>
      <ImageField id={`${idPrefix}-image`} label="Floor plan image" orgId={orgId} value={imageUrl} onChange={setImageUrl} wide required hint="A top-down picture or drawing of the room. JPEG, PNG or WebP, up to 5 MB." />
      {problems.length > 0 && (
        <ul className="space-y-1 text-sm text-red-300" role="alert">
          {problems.map((p) => <li key={p}>{p}</li>)}
        </ul>
      )}
      <div className="flex gap-2">
        <Button type="submit" disabled={busy} className="bg-gradient-orange font-bold text-black hover:opacity-90">
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : submitLabel}
        </Button>
        {onCancel && <Button type="button" variant="ghost" onClick={onCancel} disabled={busy}>Cancel</Button>}
      </div>
    </form>
  );
};

/**
 * The floor plan pictures of a venue (main room, terrace, VIP lounge). Guests see them when choosing a table. Where each
 * table sits on a floor is arranged by the BottlesUp team for now; removing a floor leaves its tables, just unplaced.
 */
const FloorsEditor = ({ orgId, venueId, onChanged }: Props) => {
  const { toast } = useToast();
  const { data: floors, error, reload } = useLoad(() => listVenueFloors(venueId), venueId);
  const [editing, setEditing] = useState<string | null>(null);
  const [removing, setRemoving] = useState<FloorRow | null>(null);
  const [busy, setBusy] = useState(false);

  const save = async (floorId: string | null, label: string, imageUrl: string) => {
    setBusy(true);
    try {
      await saveVenueFloor(venueId, floorId, label, imageUrl);
      toast({ title: floorId ? 'Floor saved' : 'Floor added' });
      setEditing(null);
      await reload();
      onChanged();
    } catch (err) {
      toast({ title: 'Could not save the floor', description: errorMessage(err), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const confirmRemove = async () => {
    if (!removing) return;
    setBusy(true);
    try {
      await removeVenueFloor(venueId, removing.floorId);
      toast({ title: 'Floor removed' });
      setRemoving(null);
      await reload();
      onChanged();
    } catch (err) {
      toast({ title: 'Could not remove the floor', description: errorMessage(err), variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  if (error) return <p className="text-sm text-red-300" role="alert">{error}</p>;
  if (!floors) return <p className="text-sm text-gray-500">Loading floors…</p>;

  return (
    <div className="space-y-6">
      <p className="text-sm text-gray-400">Upload a picture of each room guests can book a table in.</p>

      {floors.length === 0 && <p className="rounded-xl border border-dashed border-gray-800 p-6 text-center text-sm text-gray-400">No floors yet. Add your first one below.</p>}

      <ul className="space-y-3">
        {floors.map((f) => (
          <li key={f.floorId} className="rounded-xl border border-gray-800 p-4">
            {editing === f.floorId ? (
              <FloorForm orgId={orgId} idPrefix={`floor-${f.floorId}`} initial={{ label: f.label, imageUrl: f.imageUrl }} submitLabel="Save floor" busy={busy} onSubmit={(l, i) => void save(f.floorId, l, i)} onCancel={() => setEditing(null)} />
            ) : (
              <div className="flex flex-wrap items-center gap-4">
                <img src={f.imageUrl} alt={`${f.label} floor plan`} className="h-20 w-32 rounded-md border border-gray-800 object-cover" />
                <div className="min-w-[12rem] flex-1">
                  <p className="font-medium text-white">{f.label}</p>
                  <p className="text-xs text-gray-500">{f.tableCount === 0 ? 'No tables placed on it yet' : `${f.tableCount} ${f.tableCount === 1 ? 'table type' : 'table types'} placed on it`}</p>
                </div>
                <div className="flex gap-2">
                  <Button type="button" variant="outline" size="sm" onClick={() => setEditing(f.floorId)}>Edit</Button>
                  <Button type="button" variant="ghost" size="sm" className="text-red-400 hover:text-red-300" onClick={() => setRemoving(f)}>Remove</Button>
                </div>
              </div>
            )}
          </li>
        ))}
      </ul>

      <div className="rounded-xl border border-gray-800 bg-black/30 p-4">
        <h4 className="mb-4 text-sm font-medium text-white">Add a floor</h4>
        <FloorForm key={floors.length} orgId={orgId} idPrefix={`new-floor-${venueId}`} initial={{ label: '', imageUrl: '' }} submitLabel="Add floor" busy={busy} onSubmit={(l, i) => void save(null, l, i)} />
      </div>

      <ConfirmRemove
        open={removing !== null}
        title={`Remove ${removing?.label ?? 'this floor'}?`}
        description={removing && removing.tableCount > 0
          ? `${removing.tableCount} table ${removing.tableCount === 1 ? 'type is' : 'types are'} placed on this floor. They stay, but are no longer placed on a floor plan.`
          : 'Guests will no longer see this floor plan.'}
        busy={busy}
        onConfirm={() => void confirmRemove()}
        onClose={() => setRemoving(null)}
      />
    </div>
  );
};

export default FloorsEditor;
