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
import DateTimePicker from './DateTimePicker';

type EventRow = Database['public']['Tables']['site_events']['Row'];
type TierRow = Database['public']['Tables']['site_ticket_tiers']['Row'];

interface TierDraft {
  id?: string;
  name: string;
  priceDollars: string;
  capacity: string;
}

interface EventFormDialogProps {
  event: EventRow | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}

const emptyForm = {
  title: '',
  description: '',
  venue_name: '',
  address: '',
  start_date: '',
  end_date: '',
  category: '',
  status: 'draft' as EventStatus,
  cover_image_url: '' as string | null,
  banner_image_url: '' as string | null,
  gallery: [] as string[],
  slug: '' as string | null,
};

const toDatetimeLocal = (iso: string | null) => (iso ? iso.slice(0, 16) : '');

const EventFormDialog = ({ event, open, onOpenChange, onSaved }: EventFormDialogProps) => {
  const { toast } = useToast();
  const [form, setForm] = useState(emptyForm);
  const [tiers, setTiers] = useState<TierDraft[]>([]);
  const [originalTierIds, setOriginalTierIds] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [uploadingCover, setUploadingCover] = useState(false);
  const [uploadingBanner, setUploadingBanner] = useState(false);
  const [uploadingGallery, setUploadingGallery] = useState(false);

  useEffect(() => {
    if (!open) return;

    if (event) {
      setForm({
        title: event.title,
        description: event.description,
        venue_name: event.venue_name,
        address: event.address ?? '',
        start_date: toDatetimeLocal(event.start_date),
        end_date: toDatetimeLocal(event.end_date),
        category: event.category ?? '',
        status: event.status,
        cover_image_url: event.cover_image_url,
        banner_image_url: event.banner_image_url ?? '',
        gallery: event.gallery ?? [],
        slug: event.slug ?? '',
      });

      supabase
        .from('site_ticket_tiers')
        .select('*')
        .eq('event_id', event.id)
        .then(({ data }) => {
          const rows = (data ?? []) as TierRow[];
          setTiers(
            rows.map((t) => ({
              id: t.id,
              name: t.name,
              priceDollars: (t.price_cents / 100).toString(),
              capacity: t.capacity.toString(),
            })),
          );
          setOriginalTierIds(rows.map((t) => t.id));
        });
    } else {
      setForm(emptyForm);
      setTiers([{ name: 'General Admission', priceDollars: '', capacity: '' }]);
      setOriginalTierIds([]);
    }
  }, [event, open]);

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

  const handleBannerUpload = async (file: File) => {
    setUploadingBanner(true);
    try {
      const url = await uploadEventMedia(file);
      updateField('banner_image_url', url);
    } catch (error) {
      toast({ title: 'Upload failed', description: String(error), variant: 'destructive' });
    } finally {
      setUploadingBanner(false);
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

  const addTier = () => setTiers((prev) => [...prev, { name: '', priceDollars: '', capacity: '' }]);
  const removeTier = (index: number) => setTiers((prev) => prev.filter((_, i) => i !== index));
  const updateTier = (index: number, patch: Partial<TierDraft>) =>
    setTiers((prev) => prev.map((t, i) => (i === index ? { ...t, ...patch } : t)));

  const handleSave = async () => {
    if (!form.title || !form.description || !form.venue_name || !form.start_date) {
      toast({ title: 'Missing required fields', description: 'Title, description, venue, and start date are required.', variant: 'destructive' });
      return;
    }

    setSaving(true);
    try {
      const totalCapacity = tiers.reduce((sum, t) => sum + (parseInt(t.capacity, 10) || 0), 0);
      // slug is intentionally omitted - a DB trigger (set_event_slug) generates it
      // from the title on insert and leaves it untouched on update.
      const payload: Database['public']['Tables']['site_events']['Insert'] = {
        title: form.title,
        description: form.description,
        venue_name: form.venue_name,
        address: form.address || null,
        start_date: new Date(form.start_date).toISOString(),
        end_date: form.end_date ? new Date(form.end_date).toISOString() : null,
        category: form.category || null,
        status: form.status,
        cover_image_url: form.cover_image_url,
        banner_image_url: form.banner_image_url || null,
        gallery: form.gallery,
        capacity: totalCapacity || null,
      };

      let eventId = event?.id;
      if (event) {
        const { error } = await supabase.from('site_events').update(payload).eq('id', event.id);
        if (error) throw error;
      } else {
        const { data, error } = await supabase.from('site_events').insert(payload).select('id').single();
        if (error) throw error;
        if (!data?.id) throw new Error('Failed to create event');
        eventId = data.id;
      }

      const keptIds = new Set(tiers.filter((t) => t.id).map((t) => t.id!));
      const removedIds = originalTierIds.filter((id) => !keptIds.has(id));
      if (removedIds.length > 0) {
        const { error } = await supabase.from('site_ticket_tiers').delete().in('id', removedIds);
        if (error) throw error;
      }

      for (const tier of tiers) {
        if (!tier.name || !tier.priceDollars || !tier.capacity) continue;
        const tierPayload: Database['public']['Tables']['site_ticket_tiers']['Insert'] = {
          event_id: eventId!,
          name: tier.name,
          price_cents: Math.round(parseFloat(tier.priceDollars) * 100),
          capacity: parseInt(tier.capacity, 10),
        };
        if (tier.id) {
          const { error } = await supabase.from('site_ticket_tiers').update(tierPayload).eq('id', tier.id);
          if (error) throw error;
        } else {
          const { error } = await supabase.from('site_ticket_tiers').insert(tierPayload);
          if (error) throw error;
        }
      }

      toast({ title: event ? 'Event updated' : 'Event created' });
      logAudit({
        action: event ? 'event.updated' : 'event.created',
        entityType: 'site_events',
        entityId: eventId,
        details: { title: form.title },
      });
      onSaved();
      onOpenChange(false);
    } catch (error) {
      toast({ title: 'Failed to save event', description: String(error), variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">{event ? 'Edit Event' : 'New Event'}</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-2">
            <Label>Title</Label>
            <Input value={form.title} onChange={(e) => updateField('title', e.target.value)} />
          </div>

          {event && (
            <p className="text-xs text-gray-500">
              URL slug: <span className="font-mono text-gray-400">{form.slug || '(generating...)'}</span> — generated automatically from the title.
            </p>
          )}

          <div className="space-y-2">
            <Label>Description</Label>
            <Textarea value={form.description} onChange={(e) => updateField('description', e.target.value)} rows={3} />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Venue Name</Label>
              <Input value={form.venue_name} onChange={(e) => updateField('venue_name', e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>Address</Label>
              <Input value={form.address} onChange={(e) => updateField('address', e.target.value)} />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Start Date/Time</Label>
              <DateTimePicker value={form.start_date} onChange={(v) => updateField('start_date', v)} placeholder="Select start date & time" />
            </div>
            <div className="space-y-2">
              <Label>End Date/Time (optional)</Label>
              <DateTimePicker value={form.end_date} onChange={(v) => updateField('end_date', v)} placeholder="Select end date & time" />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Category</Label>
              <Input value={form.category} onChange={(e) => updateField('category', e.target.value)} placeholder="e.g. Rooftop, Club, VIP" />
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
              <p className="text-xs text-gray-500">Shown as the thumbnail on the homepage event card.</p>
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
              <Label>Banner Image</Label>
              <p className="text-xs text-gray-500">Wide hero image shown at the top of the event detail page.</p>
            </div>
            <div className="flex items-center gap-4">
              {form.banner_image_url ? (
                <img src={form.banner_image_url} alt="Banner" className="h-20 w-32 rounded object-cover" />
              ) : (
                <div className="flex h-20 w-32 items-center justify-center rounded border border-dashed border-gray-700 text-[10px] text-gray-600">
                  No image yet
                </div>
              )}
              <div className="space-y-2">
                <Button type="button" variant="outline" size="sm" disabled={uploadingBanner} asChild>
                  <label className="cursor-pointer">
                    {uploadingBanner ? 'Uploading...' : 'Upload Banner Image'}
                    <input
                      type="file"
                      accept="image/*"
                      className="hidden"
                      onChange={(e) => e.target.files?.[0] && handleBannerUpload(e.target.files[0])}
                    />
                  </label>
                </Button>
                {form.banner_image_url && (
                  <button
                    type="button"
                    className="block text-xs text-gray-500 hover:text-red-400"
                    onClick={() => updateField('banner_image_url', null)}
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
              <p className="text-xs text-gray-500">Extra photos shown further down the event detail page.</p>
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

          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <Label>Ticket Tiers</Label>
              <Button type="button" size="sm" variant="outline" onClick={addTier}>
                <Plus className="mr-1 h-3 w-3" />
                Add Tier
              </Button>
            </div>
            {tiers.map((tier, i) => (
              <div key={i} className="grid grid-cols-[1fr_100px_100px_auto] gap-2">
                <Input
                  placeholder="Name (e.g. GA, VIP)"
                  value={tier.name}
                  onChange={(e) => updateTier(i, { name: e.target.value })}
                />
                <Input
                  placeholder="Price $"
                  type="number"
                  min="0"
                  step="0.01"
                  value={tier.priceDollars}
                  onChange={(e) => updateTier(i, { priceDollars: e.target.value })}
                />
                <Input
                  placeholder="Capacity"
                  type="number"
                  min="0"
                  value={tier.capacity}
                  onChange={(e) => updateTier(i, { capacity: e.target.value })}
                />
                <Button type="button" size="icon" variant="ghost" onClick={() => removeTier(i)}>
                  <Trash2 className="h-4 w-4" />
                </Button>
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
            disabled={saving || uploadingCover || uploadingBanner || uploadingGallery}
            className="bg-gradient-orange text-black font-bold hover:opacity-90"
          >
            {saving ? 'Saving...' : 'Save Event'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default EventFormDialog;
