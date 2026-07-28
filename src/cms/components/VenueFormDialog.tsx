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
import { Textarea } from '@/components/ui/textarea';
import { Switch } from '@/components/ui/switch';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Trash2, Plus } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { uploadEventMedia } from '@/lib/uploadEventMedia';
import { logAudit } from '@/lib/auditLog';
import type { Database, EventStatus } from '@/types/database';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];

const DAY_LABELS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

interface TimeSlotDraft {
  id?: string;
  dayOfWeek: string; // "0"-"6"
  startTime: string; // "22:00"
  label: string;
}

interface TableTypeDraft {
  id?: string;
  name: string;
  description: string;
  maxGuests: string;
  minSpendDollars: string;
  depositDollars: string;
  inventoryCount: string;
  imageUrl: string | null;
  badgeLabel: string;
  isFeatured: boolean;
}

interface VenueFormDialogProps {
  venue: VenueRow | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}

const emptyForm = {
  name: '',
  slug: '' as string | null,
  description: '',
  address: '',
  status: 'draft' as EventStatus,
  cover_image_url: '' as string | null,
  gallery: [] as string[],
};

const VenueFormDialog = ({ venue, open, onOpenChange, onSaved }: VenueFormDialogProps) => {
  const { toast } = useToast();
  const [form, setForm] = useState(emptyForm);
  const [slots, setSlots] = useState<TimeSlotDraft[]>([]);
  const [originalSlotIds, setOriginalSlotIds] = useState<string[]>([]);
  const [tableTypes, setTableTypes] = useState<TableTypeDraft[]>([]);
  const [originalTableTypeIds, setOriginalTableTypeIds] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [uploadingCover, setUploadingCover] = useState(false);
  const [uploadingGallery, setUploadingGallery] = useState(false);
  const [uploadingTableImage, setUploadingTableImage] = useState<number | null>(null);

  useEffect(() => {
    if (!open) return;

    if (venue) {
      setForm({
        name: venue.name,
        slug: venue.slug ?? '',
        description: venue.description ?? '',
        address: venue.address ?? '',
        status: venue.status,
        cover_image_url: venue.cover_image_url,
        gallery: venue.gallery ?? [],
      });

      supabase
        .from('site_venue_time_slots')
        .select('*')
        .eq('venue_id', venue.id)
        .then(({ data }) => {
          const rows = (data ?? []) as TimeSlotRow[];
          setSlots(
            rows.map((s) => ({
              id: s.id,
              dayOfWeek: s.day_of_week.toString(),
              startTime: s.start_time.slice(0, 5),
              label: s.label ?? '',
            })),
          );
          setOriginalSlotIds(rows.map((s) => s.id));
        });

      supabase
        .from('site_table_types')
        .select('*')
        .eq('venue_id', venue.id)
        .order('sort_order', { ascending: true })
        .then(({ data }) => {
          const rows = (data ?? []) as TableTypeRow[];
          setTableTypes(
            rows.map((t) => ({
              id: t.id,
              name: t.name,
              description: t.description ?? '',
              maxGuests: t.max_guests.toString(),
              minSpendDollars: (t.min_spend_cents / 100).toString(),
              depositDollars: (t.deposit_cents / 100).toString(),
              inventoryCount: t.inventory_count.toString(),
              imageUrl: t.image_url,
              badgeLabel: t.badge_label ?? '',
              isFeatured: t.is_featured,
            })),
          );
          setOriginalTableTypeIds(rows.map((t) => t.id));
        });
    } else {
      setForm(emptyForm);
      setSlots([{ dayOfWeek: '5', startTime: '22:00', label: '' }]);
      setOriginalSlotIds([]);
      setTableTypes([
        { name: '', description: '', maxGuests: '', minSpendDollars: '', depositDollars: '', inventoryCount: '', imageUrl: null, badgeLabel: '', isFeatured: false },
      ]);
      setOriginalTableTypeIds([]);
    }
  }, [venue, open]);

  const updateField = <K extends keyof typeof form>(key: K, value: (typeof form)[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  const handleCoverUpload = async (file: File) => {
    setUploadingCover(true);
    try {
      const url = await uploadEventMedia(file);
      updateField('cover_image_url', url);
    } catch (error) {
      toast({ title: 'Upload failed', description: String(error), variant: 'destructive' });
    } finally {
      setUploadingCover(false);
    }
  };

  const handleGalleryUpload = async (files: FileList) => {
    setUploadingGallery(true);
    try {
      const urls = await Promise.all(Array.from(files).map(uploadEventMedia));
      setForm((prev) => ({ ...prev, gallery: [...prev.gallery, ...urls] }));
    } catch (error) {
      toast({ title: 'Upload failed', description: String(error), variant: 'destructive' });
    } finally {
      setUploadingGallery(false);
    }
  };

  const addSlot = () => setSlots((prev) => [...prev, { dayOfWeek: '5', startTime: '22:00', label: '' }]);
  const removeSlot = (index: number) => setSlots((prev) => prev.filter((_, i) => i !== index));
  const updateSlot = (index: number, patch: Partial<TimeSlotDraft>) =>
    setSlots((prev) => prev.map((s, i) => (i === index ? { ...s, ...patch } : s)));

  const addTableType = () =>
    setTableTypes((prev) => [
      ...prev,
      { name: '', description: '', maxGuests: '', minSpendDollars: '', depositDollars: '', inventoryCount: '', imageUrl: null, badgeLabel: '', isFeatured: false },
    ]);
  const removeTableType = (index: number) => setTableTypes((prev) => prev.filter((_, i) => i !== index));
  const updateTableType = (index: number, patch: Partial<TableTypeDraft>) =>
    setTableTypes((prev) => prev.map((t, i) => (i === index ? { ...t, ...patch } : t)));

  const handleTableImageUpload = async (index: number, file: File) => {
    setUploadingTableImage(index);
    try {
      const url = await uploadEventMedia(file);
      updateTableType(index, { imageUrl: url });
    } catch (error) {
      toast({ title: 'Upload failed', description: String(error), variant: 'destructive' });
    } finally {
      setUploadingTableImage(null);
    }
  };

  const handleSave = async () => {
    if (!form.name) {
      toast({ title: 'Missing required fields', description: 'Venue name is required.', variant: 'destructive' });
      return;
    }

    setSaving(true);
    try {
      // slug is intentionally omitted - a DB trigger (set_venue_slug) generates it
      // from the name on insert and leaves it untouched on update.
      const payload: Database['public']['Tables']['site_venues']['Insert'] = {
        name: form.name,
        description: form.description || null,
        address: form.address || null,
        status: form.status,
        cover_image_url: form.cover_image_url,
        gallery: form.gallery,
      };

      let venueId = venue?.id;
      if (venue) {
        const { error } = await supabase.from('site_venues').update(payload).eq('id', venue.id);
        if (error) throw error;
      } else {
        const { data, error } = await supabase.from('site_venues').insert(payload).select('id').single();
        if (error) throw error;
        if (!data?.id) throw new Error('Failed to create venue');
        venueId = data.id;
      }

      const keptSlotIds = new Set(slots.filter((s) => s.id).map((s) => s.id!));
      const removedSlotIds = originalSlotIds.filter((id) => !keptSlotIds.has(id));
      if (removedSlotIds.length > 0) {
        const { error } = await supabase.from('site_venue_time_slots').delete().in('id', removedSlotIds);
        if (error) throw error;
      }
      for (const slot of slots) {
        if (!slot.startTime) continue;
        const slotPayload: Database['public']['Tables']['site_venue_time_slots']['Insert'] = {
          venue_id: venueId!,
          day_of_week: parseInt(slot.dayOfWeek, 10),
          start_time: slot.startTime,
          label: slot.label || null,
        };
        if (slot.id) {
          const { error } = await supabase.from('site_venue_time_slots').update(slotPayload).eq('id', slot.id);
          if (error) throw error;
        } else {
          const { error } = await supabase.from('site_venue_time_slots').insert(slotPayload);
          if (error) throw error;
        }
      }

      const keptTableTypeIds = new Set(tableTypes.filter((t) => t.id).map((t) => t.id!));
      const removedTableTypeIds = originalTableTypeIds.filter((id) => !keptTableTypeIds.has(id));
      if (removedTableTypeIds.length > 0) {
        const { error } = await supabase.from('site_table_types').delete().in('id', removedTableTypeIds);
        if (error) throw error;
      }
      for (const [index, tableType] of tableTypes.entries()) {
        if (!tableType.name || !tableType.maxGuests || !tableType.inventoryCount) continue;
        const tableTypePayload: Database['public']['Tables']['site_table_types']['Insert'] = {
          venue_id: venueId!,
          name: tableType.name,
          description: tableType.description || null,
          max_guests: parseInt(tableType.maxGuests, 10),
          min_spend_cents: Math.round((parseFloat(tableType.minSpendDollars) || 0) * 100),
          deposit_cents: Math.round((parseFloat(tableType.depositDollars) || 0) * 100),
          inventory_count: parseInt(tableType.inventoryCount, 10),
          image_url: tableType.imageUrl,
          badge_label: tableType.badgeLabel || null,
          is_featured: tableType.isFeatured,
          sort_order: index,
        };
        if (tableType.id) {
          const { error } = await supabase.from('site_table_types').update(tableTypePayload).eq('id', tableType.id);
          if (error) throw error;
        } else {
          const { error } = await supabase.from('site_table_types').insert(tableTypePayload);
          if (error) throw error;
        }
      }

      toast({ title: venue ? 'Venue updated' : 'Venue created' });
      logAudit({
        action: venue ? 'venue.updated' : 'venue.created',
        entityType: 'site_venues',
        entityId: venueId,
        details: { name: form.name },
      });
      onSaved();
      onOpenChange(false);
    } catch (error) {
      toast({ title: 'Failed to save venue', description: String(error), variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">{venue ? 'Edit Venue' : 'New Venue'}</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-2">
            <Label>Name</Label>
            <Input value={form.name} onChange={(e) => updateField('name', e.target.value)} />
          </div>

          {venue && (
            <p className="text-xs text-gray-500">
              URL slug: <span className="font-mono text-gray-400">{form.slug || '(generating...)'}</span> — generated automatically from the name.
            </p>
          )}

          <div className="space-y-2">
            <Label>Description</Label>
            <Textarea value={form.description} onChange={(e) => updateField('description', e.target.value)} rows={3} />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Address</Label>
              <Input value={form.address} onChange={(e) => updateField('address', e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>Status</Label>
              <Select value={form.status} onValueChange={(v) => updateField('status', v as EventStatus)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="draft">Draft</SelectItem>
                  <SelectItem value="published">Published</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="space-y-3 rounded-lg border border-gray-800 p-4">
            <div>
              <Label>Cover Image</Label>
              <p className="text-xs text-gray-500">Shown as the thumbnail on the VIP Tables page.</p>
            </div>
            <div className="flex items-center gap-4">
              {form.cover_image_url ? (
                <img src={form.cover_image_url} alt="Cover" className="h-20 w-20 rounded object-cover" />
              ) : (
                <div className="flex h-20 w-20 items-center justify-center rounded border border-dashed border-gray-700 text-[10px] text-gray-600">
                  No image yet
                </div>
              )}
              <div className="space-y-2">
                <Button type="button" variant="outline" size="sm" disabled={uploadingCover} asChild>
                  <label className="cursor-pointer">
                    {uploadingCover ? 'Uploading...' : 'Upload Cover Image'}
                    <input
                      type="file"
                      accept="image/*"
                      className="hidden"
                      onChange={(e) => e.target.files?.[0] && handleCoverUpload(e.target.files[0])}
                    />
                  </label>
                </Button>
                {form.cover_image_url && (
                  <button
                    type="button"
                    className="block text-xs text-gray-500 hover:text-red-400"
                    onClick={() => updateField('cover_image_url', null)}
                  >
                    Remove
                  </button>
                )}
              </div>
            </div>
          </div>

          <div className="space-y-3 rounded-lg border border-gray-800 p-4">
            <div>
              <Label>Gallery</Label>
              <p className="text-xs text-gray-500">Extra photos of the venue.</p>
            </div>
            {form.gallery.length > 0 ? (
              <div className="flex flex-wrap gap-2">
                {form.gallery.map((url) => (
                  <div key={url} className="relative">
                    <img src={url} alt="Gallery" className="h-16 w-16 rounded object-cover" />
                    <button
                      type="button"
                      onClick={() => setForm((prev) => ({ ...prev, gallery: prev.gallery.filter((g) => g !== url) }))}
                      className="absolute -right-1 -top-1 rounded-full bg-black p-0.5 text-white"
                    >
                      <Trash2 className="h-3 w-3" />
                    </button>
                  </div>
                ))}
              </div>
            ) : (
              <div className="flex h-16 items-center rounded border border-dashed border-gray-700 px-3 text-xs text-gray-600">
                No gallery images yet
              </div>
            )}
            <Button type="button" variant="outline" size="sm" disabled={uploadingGallery} asChild>
              <label className="cursor-pointer">
                {uploadingGallery ? 'Uploading...' : 'Add Gallery Images'}
                <input
                  type="file"
                  accept="image/*"
                  multiple
                  className="hidden"
                  onChange={(e) => e.target.files && handleGalleryUpload(e.target.files)}
                />
              </label>
            </Button>
          </div>

          <div className="space-y-2 rounded-lg border border-gray-800 p-4">
            <div className="flex items-center justify-between">
              <div>
                <Label>Time Slots</Label>
                <p className="text-xs text-gray-500">Which nights + arrival times this venue takes bookings for.</p>
              </div>
              <Button type="button" size="sm" variant="outline" onClick={addSlot}>
                <Plus className="mr-1 h-3 w-3" />
                Add Slot
              </Button>
            </div>
            {slots.map((slot, i) => (
              <div key={i} className="grid grid-cols-[1fr_110px_1fr_auto] gap-2">
                <Select value={slot.dayOfWeek} onValueChange={(v) => updateSlot(i, { dayOfWeek: v })}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {DAY_LABELS.map((day, idx) => (
                      <SelectItem key={idx} value={idx.toString()}>
                        {day}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Input
                  type="time"
                  value={slot.startTime}
                  onChange={(e) => updateSlot(i, { startTime: e.target.value })}
                />
                <Input
                  placeholder="Label (optional, e.g. Prime)"
                  value={slot.label}
                  onChange={(e) => updateSlot(i, { label: e.target.value })}
                />
                <Button type="button" size="icon" variant="ghost" onClick={() => removeSlot(i)}>
                  <Trash2 className="h-4 w-4" />
                </Button>
              </div>
            ))}
          </div>

          <div className="space-y-3 rounded-lg border border-gray-800 p-4">
            <div className="flex items-center justify-between">
              <div>
                <Label>Table Types</Label>
                <p className="text-xs text-gray-500">Silver/Gold/Platinum-style categories, each with its own inventory.</p>
              </div>
              <Button type="button" size="sm" variant="outline" onClick={addTableType}>
                <Plus className="mr-1 h-3 w-3" />
                Add Table Type
              </Button>
            </div>
            {tableTypes.map((tableType, i) => (
              <div key={i} className="space-y-2 rounded-lg border border-gray-800 p-3">
                <div className="flex items-start gap-3">
                  {tableType.imageUrl ? (
                    <img src={tableType.imageUrl} alt="Table" className="h-16 w-16 shrink-0 rounded object-cover" />
                  ) : (
                    <div className="flex h-16 w-16 shrink-0 items-center justify-center rounded border border-dashed border-gray-700 text-[9px] text-gray-600">
                      No image
                    </div>
                  )}
                  <div className="flex-1 space-y-2">
                    <div className="grid grid-cols-2 gap-2">
                      <Input
                        placeholder="Name (e.g. Gold Table)"
                        value={tableType.name}
                        onChange={(e) => updateTableType(i, { name: e.target.value })}
                      />
                      <Button type="button" variant="outline" size="sm" disabled={uploadingTableImage === i} asChild>
                        <label className="cursor-pointer">
                          {uploadingTableImage === i ? 'Uploading...' : 'Upload Image'}
                          <input
                            type="file"
                            accept="image/*"
                            className="hidden"
                            onChange={(e) => e.target.files?.[0] && handleTableImageUpload(i, e.target.files[0])}
                          />
                        </label>
                      </Button>
                    </div>
                    <Input
                      placeholder="Description (optional, e.g. 2 premium bottles included)"
                      value={tableType.description}
                      onChange={(e) => updateTableType(i, { description: e.target.value })}
                    />
                    <div className="grid grid-cols-4 gap-2">
                      <div className="space-y-1">
                        <Label className="text-xs text-gray-500">Max guests</Label>
                        <Input
                          type="number"
                          min="1"
                          value={tableType.maxGuests}
                          onChange={(e) => updateTableType(i, { maxGuests: e.target.value })}
                        />
                      </div>
                      <div className="space-y-1">
                        <Label className="text-xs text-gray-500">Min spend $</Label>
                        <Input
                          type="number"
                          min="0"
                          step="0.01"
                          value={tableType.minSpendDollars}
                          onChange={(e) => updateTableType(i, { minSpendDollars: e.target.value })}
                        />
                      </div>
                      <div className="space-y-1">
                        <Label className="text-xs text-gray-500">Deposit $</Label>
                        <Input
                          type="number"
                          min="0"
                          step="0.01"
                          value={tableType.depositDollars}
                          onChange={(e) => updateTableType(i, { depositDollars: e.target.value })}
                        />
                      </div>
                      <div className="space-y-1">
                        <Label className="text-xs text-gray-500"># of tables available</Label>
                        <Input
                          type="number"
                          min="0"
                          value={tableType.inventoryCount}
                          onChange={(e) => updateTableType(i, { inventoryCount: e.target.value })}
                        />
                      </div>
                    </div>
                    <div className="flex items-center gap-3">
                      <div className="flex-1 space-y-1">
                        <Label className="text-xs text-gray-500">Badge (optional, e.g. "Most Popular", "Best View")</Label>
                        <Input
                          placeholder="Badge label"
                          value={tableType.badgeLabel}
                          onChange={(e) => updateTableType(i, { badgeLabel: e.target.value })}
                        />
                      </div>
                      <div className="flex items-center gap-2 pt-4">
                        <Switch
                          checked={tableType.isFeatured}
                          onCheckedChange={(checked) => updateTableType(i, { isFeatured: checked })}
                        />
                        <Label className="text-xs text-gray-400">Featured (highlighted card)</Label>
                      </div>
                    </div>
                  </div>
                  <Button type="button" size="icon" variant="ghost" onClick={() => removeTableType(i)}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              </div>
            ))}
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            onClick={handleSave}
            disabled={saving || uploadingCover || uploadingGallery || uploadingTableImage !== null}
            className="bg-gradient-orange text-black font-bold hover:opacity-90"
          >
            {saving ? 'Saving...' : 'Save Venue'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default VenueFormDialog;
