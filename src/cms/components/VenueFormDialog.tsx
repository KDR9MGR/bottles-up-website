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
import { Trash2, Plus, MapPin } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { uploadEventMedia } from '@/lib/uploadEventMedia';
import { logAudit } from '@/lib/auditLog';
import { describeDeleteBlockedError } from '@/lib/friendlyDbError';
import FloorPlanEditor, { type TablePlacement } from './FloorPlanEditor';
import type { Database, EventStatus, PricingMode } from '@/types/database';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type TimeSlotRow = Database['public']['Tables']['site_venue_time_slots']['Row'];
type TableTypeRow = Database['public']['Tables']['site_table_types']['Row'];
type FloorRow = Database['public']['Tables']['site_venue_floors']['Row'];

const DAY_LABELS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

interface TimeSlotDraft {
  id?: string;
  dayOfWeek: string; // "0"-"6"
  startTime: string; // "22:00"
  label: string;
}

interface FloorDraft {
  id?: string;
  tempId: string; // stable client-side key; equals `id` once persisted
  label: string;
  imageUrl: string | null;
}

interface TableTypeDraft {
  id?: string;
  name: string;
  description: string;
  maxGuests: string;
  minGuests: string;
  minSpendDollars: string;
  depositDollars: string;
  inventoryCount: string;
  imageUrl: string | null;
  badgeLabel: string;
  isFeatured: boolean;
  pricingMode: PricingMode;
  hourlyRateDollars: string;
  minHours: string;
  floorTempId: string | null;
  posX: number | null;
  posY: number | null;
  width: number | null;
  height: number | null;
}

interface VenueFormDialogProps {
  venue: VenueRow | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}

const emptyTableType: TableTypeDraft = {
  name: '',
  description: '',
  maxGuests: '',
  minGuests: '',
  minSpendDollars: '',
  depositDollars: '',
  inventoryCount: '',
  imageUrl: null,
  badgeLabel: '',
  isFeatured: false,
  pricingMode: 'flat',
  hourlyRateDollars: '',
  minHours: '1',
  floorTempId: null,
  posX: null,
  posY: null,
  width: null,
  height: null,
};

const VENUE_CATEGORIES = ['Nightclub', 'Rooftop', 'Lounge', 'Restaurant', 'Beach Club', 'Patio'];

const emptyForm = {
  name: '',
  slug: '' as string | null,
  description: '',
  address: '',
  status: 'draft' as EventStatus,
  cover_image_url: '' as string | null,
  gallery: [] as string[],
  category: '' as string,
  bookingStartDate: '',
  bookingEndDate: '',
};

const VenueFormDialog = ({ venue, open, onOpenChange, onSaved }: VenueFormDialogProps) => {
  const { toast } = useToast();
  const [form, setForm] = useState(emptyForm);
  const [slots, setSlots] = useState<TimeSlotDraft[]>([]);
  const [originalSlotIds, setOriginalSlotIds] = useState<string[]>([]);
  const [floors, setFloors] = useState<FloorDraft[]>([]);
  const [originalFloorIds, setOriginalFloorIds] = useState<string[]>([]);
  const [tableTypes, setTableTypes] = useState<TableTypeDraft[]>([]);
  const [originalTableTypeIds, setOriginalTableTypeIds] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [uploadingCover, setUploadingCover] = useState(false);
  const [uploadingGallery, setUploadingGallery] = useState(false);
  const [uploadingTableImage, setUploadingTableImage] = useState<number | null>(null);
  const [uploadingFloorImage, setUploadingFloorImage] = useState<number | null>(null);
  const [placementIndex, setPlacementIndex] = useState<number | null>(null);

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
        category: venue.category ?? '',
        bookingStartDate: venue.booking_start_date ?? '',
        bookingEndDate: venue.booking_end_date ?? '',
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
        .from('site_venue_floors')
        .select('*')
        .eq('venue_id', venue.id)
        .order('sort_order', { ascending: true })
        .then(({ data }) => {
          const rows = (data ?? []) as FloorRow[];
          setFloors(rows.map((f) => ({ id: f.id, tempId: f.id, label: f.label, imageUrl: f.image_url })));
          setOriginalFloorIds(rows.map((f) => f.id));
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
              minGuests: t.min_guests?.toString() ?? '',
              minSpendDollars: (t.min_spend_cents / 100).toString(),
              depositDollars: (t.deposit_cents / 100).toString(),
              inventoryCount: t.inventory_count.toString(),
              imageUrl: t.image_url,
              badgeLabel: t.badge_label ?? '',
              isFeatured: t.is_featured,
              pricingMode: t.pricing_mode,
              hourlyRateDollars: t.hourly_rate_cents ? (t.hourly_rate_cents / 100).toString() : '',
              minHours: t.min_hours?.toString() ?? '1',
              floorTempId: t.floor_id,
              posX: t.pos_x,
              posY: t.pos_y,
              width: t.width,
              height: t.height,
            })),
          );
          setOriginalTableTypeIds(rows.map((t) => t.id));
        });
    } else {
      setForm(emptyForm);
      setSlots([{ dayOfWeek: '5', startTime: '22:00', label: '' }]);
      setOriginalSlotIds([]);
      setFloors([]);
      setOriginalFloorIds([]);
      setTableTypes([{ ...emptyTableType }]);
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

  const addFloor = () => setFloors((prev) => [...prev, { tempId: crypto.randomUUID(), label: '', imageUrl: null }]);
  const removeFloor = (tempId: string) => {
    setFloors((prev) => prev.filter((f) => f.tempId !== tempId));
    // Tables positioned on a removed floor go back to being plain (unpositioned) cards.
    setTableTypes((prev) =>
      prev.map((t) => (t.floorTempId === tempId ? { ...t, floorTempId: null, posX: null, posY: null, width: null, height: null } : t)),
    );
  };
  const updateFloor = (tempId: string, patch: Partial<FloorDraft>) =>
    setFloors((prev) => prev.map((f) => (f.tempId === tempId ? { ...f, ...patch } : f)));

  const handleFloorImageUpload = async (index: number, file: File) => {
    setUploadingFloorImage(index);
    try {
      const url = await uploadEventMedia(file);
      updateFloor(floors[index].tempId, { imageUrl: url });
    } catch (error) {
      toast({ title: 'Upload failed', description: String(error), variant: 'destructive' });
    } finally {
      setUploadingFloorImage(null);
    }
  };

  const addTableType = () => setTableTypes((prev) => [...prev, { ...emptyTableType }]);
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

    // A table type row counts as "started" once the admin has entered anything
    // into it. Those must be complete before saving - previously an incomplete
    // row (e.g. name filled in but max guests left blank) was silently dropped
    // with no feedback, so the venue would save as "published" with zero
    // bookable tables and never appear on the public VIP Tables page.
    const incompleteIndex = tableTypes.findIndex((t) => {
      const started =
        t.name || t.description || t.maxGuests || t.minSpendDollars || t.depositDollars || t.inventoryCount || t.badgeLabel || t.imageUrl;
      return started && (!t.name || !t.maxGuests || !t.inventoryCount);
    });
    if (incompleteIndex !== -1) {
      toast({
        title: `Table type #${incompleteIndex + 1} is incomplete`,
        description: 'Name, max guests, and # of tables available are required for every table type you start filling in.',
        variant: 'destructive',
      });
      return;
    }

    const hourlyMissingRate = tableTypes.findIndex(
      (t) => t.name && t.pricingMode === 'hourly' && !t.hourlyRateDollars,
    );
    if (hourlyMissingRate !== -1) {
      toast({
        title: `Table type #${hourlyMissingRate + 1} needs an hourly rate`,
        description: 'Set an hourly rate for every table type priced by the hour.',
        variant: 'destructive',
      });
      return;
    }

    const completeTableTypeCount = tableTypes.filter((t) => t.name && t.maxGuests && t.inventoryCount).length;
    if (form.status === 'published' && completeTableTypeCount === 0) {
      toast({
        title: 'No table types to publish',
        description: "This venue has no complete table types, so it won't appear on the VIP Tables page. Add at least one table type, or save it as Draft instead.",
        variant: 'destructive',
      });
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
        category: form.category || null,
        booking_start_date: form.bookingStartDate || null,
        booking_end_date: form.bookingEndDate || null,
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

      // Floors must be saved before table types, since a table type's floor_id
      // references a floor row that may only just now be getting created.
      const keptFloorIds = new Set(floors.filter((f) => f.id).map((f) => f.id!));
      const removedFloorIds = originalFloorIds.filter((id) => !keptFloorIds.has(id));
      if (removedFloorIds.length > 0) {
        const { error } = await supabase.from('site_venue_floors').delete().in('id', removedFloorIds);
        if (error) throw error;
      }
      const tempIdToFloorId = new Map<string, string>();
      for (const [index, floor] of floors.entries()) {
        if (!floor.label || !floor.imageUrl) continue;
        const floorPayload: Database['public']['Tables']['site_venue_floors']['Insert'] = {
          venue_id: venueId!,
          label: floor.label,
          image_url: floor.imageUrl,
          sort_order: index,
        };
        if (floor.id) {
          const { error } = await supabase.from('site_venue_floors').update(floorPayload).eq('id', floor.id);
          if (error) throw error;
          tempIdToFloorId.set(floor.tempId, floor.id);
        } else {
          const { data, error } = await supabase.from('site_venue_floors').insert(floorPayload).select('id').single();
          if (error) throw error;
          if (data?.id) tempIdToFloorId.set(floor.tempId, data.id);
        }
      }

      const keptTableTypeIds = new Set(tableTypes.filter((t) => t.id).map((t) => t.id!));
      const removedTableTypeIds = originalTableTypeIds.filter((id) => !keptTableTypeIds.has(id));
      if (removedTableTypeIds.length > 0) {
        const { error } = await supabase.from('site_table_types').delete().in('id', removedTableTypeIds);
        if (error) {
          const blocked = describeDeleteBlockedError(error);
          if (blocked) {
            toast({
              title: "Can't remove that table type",
              description: `It has existing ${blocked.referencingLabel} attached to it, so it wasn't deleted - everything else you changed was saved. Reopen this venue to edit or reprice it instead of removing it.`,
              variant: 'destructive',
            });
            setSaving(false);
            onSaved();
            onOpenChange(false);
            return;
          }
          throw error;
        }
      }
      for (const [index, tableType] of tableTypes.entries()) {
        if (!tableType.name || !tableType.maxGuests || !tableType.inventoryCount) continue;
        const resolvedFloorId = tableType.floorTempId ? (tempIdToFloorId.get(tableType.floorTempId) ?? null) : null;
        const isPositioned = !!resolvedFloorId && tableType.posX !== null;
        const tableTypePayload: Database['public']['Tables']['site_table_types']['Insert'] = {
          venue_id: venueId!,
          name: tableType.name,
          description: tableType.description || null,
          max_guests: parseInt(tableType.maxGuests, 10),
          min_guests: tableType.minGuests ? parseInt(tableType.minGuests, 10) : null,
          min_spend_cents: Math.round((parseFloat(tableType.minSpendDollars) || 0) * 100),
          deposit_cents: Math.round((parseFloat(tableType.depositDollars) || 0) * 100),
          inventory_count: parseInt(tableType.inventoryCount, 10),
          image_url: tableType.imageUrl,
          badge_label: tableType.badgeLabel || null,
          is_featured: tableType.isFeatured,
          pricing_mode: tableType.pricingMode,
          hourly_rate_cents:
            tableType.pricingMode === 'hourly' ? Math.round((parseFloat(tableType.hourlyRateDollars) || 0) * 100) : null,
          min_hours: tableType.pricingMode === 'hourly' ? parseInt(tableType.minHours, 10) || 1 : null,
          floor_id: isPositioned ? resolvedFloorId : null,
          pos_x: isPositioned ? tableType.posX : null,
          pos_y: isPositioned ? tableType.posY : null,
          width: isPositioned ? tableType.width : null,
          height: isPositioned ? tableType.height : null,
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

  const floorOptions = floors
    .filter((f): f is FloorDraft & { imageUrl: string } => !!f.imageUrl)
    .map((f) => ({ id: f.tempId, label: f.label || 'Untitled floor', imageUrl: f.imageUrl }));

  const placementTableType = placementIndex !== null ? tableTypes[placementIndex] : null;

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

          <div className="space-y-2">
            <Label>Category (optional)</Label>
            <Select value={form.category} onValueChange={(v) => updateField('category', v)}>
              <SelectTrigger>
                <SelectValue placeholder="None" />
              </SelectTrigger>
              <SelectContent>
                {VENUE_CATEGORIES.map((c) => (
                  <SelectItem key={c} value={c}>
                    {c}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-xs text-gray-500">Used to group this venue under Nightclubs/Rooftops/etc. on the public Venues page.</p>
          </div>

          <div className="space-y-2 rounded-lg border border-gray-800 p-4">
            <div>
              <Label>Booking Window (optional)</Label>
              <p className="text-xs text-gray-500">
                Restricts which dates customers can book, on top of the time slots below. Leave blank for no limit.
              </p>
            </div>
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1">
                <Label className="text-xs text-gray-500">Start date</Label>
                <Input type="date" value={form.bookingStartDate} onChange={(e) => updateField('bookingStartDate', e.target.value)} />
              </div>
              <div className="space-y-1">
                <Label className="text-xs text-gray-500">End date</Label>
                <Input type="date" value={form.bookingEndDate} onChange={(e) => updateField('bookingEndDate', e.target.value)} />
              </div>
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
                <Label>Floors</Label>
                <p className="text-xs text-gray-500">
                  Upload a floor plan image per level (e.g. "Downstairs", "Upstairs") to place tables on below.
                </p>
              </div>
              <Button type="button" size="sm" variant="outline" onClick={addFloor}>
                <Plus className="mr-1 h-3 w-3" />
                Add Floor
              </Button>
            </div>
            {floors.map((floor, i) => (
              <div key={floor.tempId} className="flex items-center gap-3 rounded-lg border border-gray-800 p-3">
                {floor.imageUrl ? (
                  <img src={floor.imageUrl} alt={floor.label} className="h-16 w-16 shrink-0 rounded object-cover" />
                ) : (
                  <div className="flex h-16 w-16 shrink-0 items-center justify-center rounded border border-dashed border-gray-700 text-[9px] text-gray-600">
                    No image
                  </div>
                )}
                <Input
                  placeholder="Label (e.g. Downstairs)"
                  value={floor.label}
                  onChange={(e) => updateFloor(floor.tempId, { label: e.target.value })}
                  className="flex-1"
                />
                <Button type="button" variant="outline" size="sm" disabled={uploadingFloorImage === i} asChild>
                  <label className="cursor-pointer">
                    {uploadingFloorImage === i ? 'Uploading...' : floor.imageUrl ? 'Replace Image' : 'Upload Image'}
                    <input
                      type="file"
                      accept="image/*"
                      className="hidden"
                      onChange={(e) => e.target.files?.[0] && handleFloorImageUpload(i, e.target.files[0])}
                    />
                  </label>
                </Button>
                <Button type="button" size="icon" variant="ghost" onClick={() => removeFloor(floor.tempId)}>
                  <Trash2 className="h-4 w-4" />
                </Button>
              </div>
            ))}
            {floors.length === 0 && (
              <p className="text-xs text-gray-600">No floors yet - tables will show as plain cards without a visual layout.</p>
            )}
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
            {tableTypes.map((tableType, i) => {
              const placedFloor = floorOptions.find((f) => f.id === tableType.floorTempId);
              return (
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
                        <Label className="text-xs text-gray-500">Min guests</Label>
                        <Input
                          type="number"
                          min="0"
                          placeholder="Optional"
                          value={tableType.minGuests}
                          onChange={(e) => updateTableType(i, { minGuests: e.target.value })}
                        />
                      </div>
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
                        <Label className="text-xs text-gray-500"># of tables available</Label>
                        <Input
                          type="number"
                          min="0"
                          value={tableType.inventoryCount}
                          onChange={(e) => updateTableType(i, { inventoryCount: e.target.value })}
                        />
                      </div>
                    </div>

                    <div className="rounded-lg border border-gray-800 p-2">
                      <div className="mb-2 flex items-center gap-2">
                        <Label className="text-xs text-gray-500">Pricing</Label>
                        <Select
                          value={tableType.pricingMode}
                          onValueChange={(v) => updateTableType(i, { pricingMode: v as PricingMode })}
                        >
                          <SelectTrigger className="h-8 w-28 text-xs">
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            <SelectItem value="flat">Flat deposit</SelectItem>
                            <SelectItem value="hourly">Hourly</SelectItem>
                          </SelectContent>
                        </Select>
                      </div>
                      {tableType.pricingMode === 'flat' ? (
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
                      ) : (
                        <div className="grid grid-cols-2 gap-2">
                          <div className="space-y-1">
                            <Label className="text-xs text-gray-500">Hourly rate $</Label>
                            <Input
                              type="number"
                              min="0"
                              step="0.01"
                              value={tableType.hourlyRateDollars}
                              onChange={(e) => updateTableType(i, { hourlyRateDollars: e.target.value })}
                            />
                          </div>
                          <div className="space-y-1">
                            <Label className="text-xs text-gray-500">Min hours</Label>
                            <Input
                              type="number"
                              min="1"
                              value={tableType.minHours}
                              onChange={(e) => updateTableType(i, { minHours: e.target.value })}
                            />
                          </div>
                        </div>
                      )}
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

                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() => setPlacementIndex(i)}
                      className="w-full"
                    >
                      <MapPin className="mr-1.5 h-3.5 w-3.5" />
                      {placedFloor ? `Positioned on ${placedFloor.label}` : 'Place on floor plan (optional)'}
                    </Button>
                  </div>
                  <Button type="button" size="icon" variant="ghost" onClick={() => removeTableType(i)}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              </div>
              );
            })}
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            onClick={handleSave}
            disabled={saving || uploadingCover || uploadingGallery || uploadingTableImage !== null || uploadingFloorImage !== null}
            className="bg-gradient-orange text-black font-bold hover:opacity-90"
          >
            {saving ? 'Saving...' : 'Save Venue'}
          </Button>
        </DialogFooter>
      </DialogContent>

      {placementTableType && (
        <FloorPlanEditor
          open={placementIndex !== null}
          onOpenChange={(o) => !o && setPlacementIndex(null)}
          tableName={placementTableType.name || 'this table'}
          floors={floorOptions}
          initialPlacement={
            placementTableType.floorTempId && placementTableType.posX !== null
              ? {
                  floorId: placementTableType.floorTempId,
                  posX: placementTableType.posX,
                  posY: placementTableType.posY!,
                  width: placementTableType.width!,
                  height: placementTableType.height!,
                }
              : null
          }
          onSave={(placement: TablePlacement) => {
            if (placementIndex === null) return;
            updateTableType(placementIndex, {
              floorTempId: placement.floorId,
              posX: placement.posX,
              posY: placement.posY,
              width: placement.width,
              height: placement.height,
            });
          }}
          onClear={() => {
            if (placementIndex === null) return;
            updateTableType(placementIndex, { floorTempId: null, posX: null, posY: null, width: null, height: null });
          }}
        />
      )}
    </Dialog>
  );
};

export default VenueFormDialog;
