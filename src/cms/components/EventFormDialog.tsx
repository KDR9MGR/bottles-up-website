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
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
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
  isNonTransferable: boolean;
  requiresAccessCode: boolean;
  accessCodeInput: string;
  // Whether this tier already had the gate on when the form loaded - lets save
  // validation tell "newly gated, needs a code" apart from "already gated,
  // blank input just means keep the existing code".
  wasGatedOnLoad: boolean;
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
  show_ticket_count: true,
  venue_id: 'none' as string,
};

// Converts a stored UTC timestamp to the value a <input type="datetime-local">
// (and DateTimePicker, which treats its string as browser-local wall-clock time)
// expects. This MUST go through Date's local getters, not a raw slice of the ISO
// string - slicing "2026-08-27T02:00:00+00:00" gives "2026-08-27T02:00" even when
// that instant is 10pm on the 26th in Toronto, so the form silently shows the wrong
// day. Worse, saving that unedited value back re-encodes it as 2am *local* time,
// pushing the stored UTC timestamp forward every single save - which is exactly the
// "date keeps drifting" bug this replaces.
// Once tickets are sold, an event's date shouldn't be able to quietly shift right
// before people are due to show up - this is the threshold for locking it outright.
const DATE_LOCK_WINDOW_DAYS = 7;

const daysUntil = (iso: string) => (new Date(iso).getTime() - Date.now()) / (1000 * 60 * 60 * 24);

const toDatetimeLocal = (iso: string | null) => {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const pad = (n: number) => n.toString().padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
};

const EventFormDialog = ({ event, open, onOpenChange, onSaved }: EventFormDialogProps) => {
  const { toast } = useToast();
  const [form, setForm] = useState(emptyForm);
  const [tiers, setTiers] = useState<TierDraft[]>([]);
  const [originalTierIds, setOriginalTierIds] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [uploadingCover, setUploadingCover] = useState(false);
  const [uploadingBanner, setUploadingBanner] = useState(false);
  const [uploadingGallery, setUploadingGallery] = useState(false);
  const [dateChangeConfirmOpen, setDateChangeConfirmOpen] = useState(false);
  const [paidOrderCount, setPaidOrderCount] = useState(0);
  const [venueOptions, setVenueOptions] = useState<{ id: string; name: string }[]>([]);

  useEffect(() => {
    supabase
      .from('site_venues')
      .select('id, name')
      .order('name')
      .then(({ data }) => setVenueOptions(data ?? []));
  }, []);

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
        show_ticket_count: event.show_ticket_count,
        venue_id: event.venue_id ?? 'none',
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
              isNonTransferable: t.is_non_transferable,
              requiresAccessCode: t.requires_access_code,
              accessCodeInput: '',
              wasGatedOnLoad: t.requires_access_code,
            })),
          );
          setOriginalTierIds(rows.map((t) => t.id));
        });

      supabase
        .from('site_orders')
        .select('id', { count: 'exact', head: true })
        .eq('event_id', event.id)
        .eq('status', 'paid')
        .then(({ count }) => setPaidOrderCount(count ?? 0));
    } else {
      setForm(emptyForm);
      setTiers([{ name: 'General Admission', priceDollars: '', capacity: '', isNonTransferable: false, requiresAccessCode: false, accessCodeInput: '', wasGatedOnLoad: false }]);
      setOriginalTierIds([]);
      setPaidOrderCount(0);
    }
  }, [event, open]);

  const isDateLocked = !!event && paidOrderCount > 0 && daysUntil(event.start_date) <= DATE_LOCK_WINDOW_DAYS;

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

  const addTier = () =>
    setTiers((prev) => [
      ...prev,
      { name: '', priceDollars: '', capacity: '', isNonTransferable: false, requiresAccessCode: false, accessCodeInput: '', wasGatedOnLoad: false },
    ]);
  const removeTier = (index: number) => setTiers((prev) => prev.filter((_, i) => i !== index));
  const updateTier = (index: number, patch: Partial<TierDraft>) =>
    setTiers((prev) => prev.map((t, i) => (i === index ? { ...t, ...patch } : t)));

  const handleSave = async () => {
    if (!form.title || !form.description || !form.venue_name || !form.start_date) {
      toast({ title: 'Missing required fields', description: 'Title, description, venue, and start date are required.', variant: 'destructive' });
      return;
    }

    const newlyGatedWithoutCode = tiers.find(
      (t) => t.requiresAccessCode && !t.wasGatedOnLoad && !t.accessCodeInput.trim(),
    );
    if (newlyGatedWithoutCode) {
      toast({
        title: 'Access code required',
        description: `Set an access code for "${newlyGatedWithoutCode.name || 'the gated tier'}" - otherwise nobody will be able to unlock it.`,
        variant: 'destructive',
      });
      return;
    }

    // Prevention: an event's date silently changing after tickets already went out
    // is exactly the incident this guards against - if the date is actually moving
    // and people have already paid for the old one, make the admin confirm rather
    // than let it slip through as a side effect of an unrelated edit. Once the event
    // is inside the lock window the field itself is disabled, but this is a defense-
    // in-depth check in case that state changed mid-session.
    if (event && paidOrderCount > 0) {
      // Compare actual instants, not raw strings - Postgres and toISOString() format
      // timestamps differently even for the exact same moment, so a string compare
      // here would "detect" a date change on every save and nag needlessly.
      const dateActuallyChanged = new Date(form.start_date).getTime() !== new Date(event.start_date).getTime();
      if (dateActuallyChanged) {
        if (isDateLocked) {
          toast({
            title: 'Date is locked',
            description: `This event has paid tickets and starts within ${DATE_LOCK_WINDOW_DAYS} days, so the date can't be changed here. Contact affected customers directly if it truly has to move.`,
            variant: 'destructive',
          });
          return;
        }
        setDateChangeConfirmOpen(true);
        return;
      }
    }

    await performSave();
  };

  const performSave = async () => {
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
        show_ticket_count: form.show_ticket_count,
        venue_id: form.venue_id === 'none' ? null : form.venue_id,
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
          is_non_transferable: tier.isNonTransferable,
          requires_access_code: tier.requiresAccessCode,
        };
        let savedTierId = tier.id;
        if (tier.id) {
          const { error } = await supabase.from('site_ticket_tiers').update(tierPayload).eq('id', tier.id);
          if (error) throw error;
        } else {
          const { data, error } = await supabase.from('site_ticket_tiers').insert(tierPayload).select('id').single();
          if (error) throw error;
          savedTierId = data?.id;
        }

        // The access code itself is write-only (hashed server-side, never
        // read back) - only touch it when the admin actually typed something.
        // Leaving the field blank on an existing gated tier keeps its old code.
        if (tier.requiresAccessCode && tier.accessCodeInput.trim() && savedTierId) {
          const { data: sessionData } = await supabase.auth.getSession();
          const token = sessionData.session?.access_token;
          const { error: codeError } = await supabase.functions.invoke('set-tier-access-code', {
            body: { tier_id: savedTierId, code: tier.accessCodeInput.trim() },
            headers: token ? { Authorization: `Bearer ${token}` } : undefined,
          });
          if (codeError) throw codeError;
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

          <div className="space-y-2">
            <Label>Linked VIP Tables Venue (optional)</Label>
            <p className="text-xs text-gray-500">
              If this event is at a venue that also has VIP tables set up, link it here - "Browse VIP Tables" on the
              event page will then go straight to that venue's table selection instead of the general listing.
            </p>
            <Select value={form.venue_id} onValueChange={(v) => updateField('venue_id', v)}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="none">Not linked</SelectItem>
                {venueOptions.map((v) => (
                  <SelectItem key={v.id} value={v.id}>
                    {v.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Start Date/Time</Label>
              <DateTimePicker
                value={form.start_date}
                onChange={(v) => updateField('start_date', v)}
                placeholder="Select start date & time"
                disabled={isDateLocked}
              />
              {isDateLocked && (
                <p className="text-xs text-orange-400">
                  Locked: {paidOrderCount} {paidOrderCount === 1 ? 'ticket has' : 'tickets have'} been sold and this
                  event starts within {DATE_LOCK_WINDOW_DAYS} days.
                </p>
              )}
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

          <div className="flex items-center justify-between rounded-lg border border-gray-800 p-4">
            <div>
              <Label>Show ticket count</Label>
              <p className="text-xs text-gray-500">
                Show "X left" / "Sold out" under each ticket tier on the public event page. Turn off to hide the
                count while still selling tickets.
              </p>
            </div>
            <Switch
              checked={form.show_ticket_count}
              onCheckedChange={(checked) => updateField('show_ticket_count', checked)}
            />
          </div>

          <div className="space-y-3 rounded-lg border border-gray-800 p-4">
            <div>
              <Label>Cover Image</Label>
              <p className="text-xs text-gray-500">
                Shown as the thumbnail on event cards. Works with any aspect ratio - portrait flyers show in full
                below, not cropped.
              </p>
            </div>
            {form.cover_image_url ? (
              <div className="flex justify-center overflow-hidden rounded-lg border border-gray-800 bg-black/40 p-2">
                <img src={form.cover_image_url} alt="Cover" className="max-h-72 w-auto rounded object-contain" />
              </div>
            ) : (
              <div className="flex h-24 items-center justify-center rounded border border-dashed border-gray-700 text-xs text-gray-600">
                No image yet
              </div>
            )}
            <div className="flex items-center gap-3">
              <Button type="button" variant="outline" size="sm" disabled={uploadingCover} asChild>
                <label className="cursor-pointer">
                  {uploadingCover ? 'Uploading...' : form.cover_image_url ? 'Replace Cover Image' : 'Upload Cover Image'}
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
                  className="text-xs text-gray-500 hover:text-red-400"
                  onClick={() => updateField('cover_image_url', null)}
                >
                  Remove
                </button>
              )}
            </div>
          </div>

          <div className="space-y-3 rounded-lg border border-gray-800 p-4">
            <div>
              <Label>Banner Image</Label>
              <p className="text-xs text-gray-500">Wide hero image shown at the top of the event detail page.</p>
            </div>
            {form.banner_image_url ? (
              <div className="flex justify-center overflow-hidden rounded-lg border border-gray-800 bg-black/40 p-2">
                <img src={form.banner_image_url} alt="Banner" className="max-h-72 w-auto rounded object-contain" />
              </div>
            ) : (
              <div className="flex h-24 items-center justify-center rounded border border-dashed border-gray-700 text-xs text-gray-600">
                No image yet
              </div>
            )}
            <div className="flex items-center gap-3">
              <Button type="button" variant="outline" size="sm" disabled={uploadingBanner} asChild>
                <label className="cursor-pointer">
                  {uploadingBanner ? 'Uploading...' : form.banner_image_url ? 'Replace Banner Image' : 'Upload Banner Image'}
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
                  className="text-xs text-gray-500 hover:text-red-400"
                  onClick={() => updateField('banner_image_url', null)}
                >
                  Remove
                </button>
              )}
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
              <div key={i} className="space-y-1.5 rounded-md border border-border/50 p-2">
                <div className="grid grid-cols-[1fr_100px_100px_auto] gap-2">
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
                <div className="flex items-center gap-2 pl-1">
                  <Switch
                    checked={tier.isNonTransferable}
                    onCheckedChange={(checked) => updateTier(i, { isNonTransferable: checked })}
                  />
                  <Label className="text-xs text-muted-foreground font-normal">
                    Non-transferable (requires email entry code at the door)
                  </Label>
                </div>
                <div className="flex items-center gap-2 pl-1">
                  <Switch
                    checked={tier.requiresAccessCode}
                    onCheckedChange={(checked) => updateTier(i, { requiresAccessCode: checked })}
                  />
                  <Label className="text-xs text-muted-foreground font-normal">
                    Requires access code to purchase (price hidden until unlocked)
                  </Label>
                </div>
                {tier.requiresAccessCode && (
                  <Input
                    placeholder={tier.wasGatedOnLoad ? 'Leave blank to keep the existing code' : 'Set access code (e.g. MEMBERS26)'}
                    value={tier.accessCodeInput}
                    onChange={(e) => updateTier(i, { accessCodeInput: e.target.value })}
                    className="font-mono"
                  />
                )}
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

      <AlertDialog open={dateChangeConfirmOpen} onOpenChange={setDateChangeConfirmOpen}>
        <AlertDialogContent className="border-gray-800 bg-gray-950">
          <AlertDialogHeader>
            <AlertDialogTitle className="text-white">Change the date on a sold event?</AlertDialogTitle>
            <AlertDialogDescription>
              {paidOrderCount} {paidOrderCount === 1 ? 'ticket has' : 'tickets have'} already been sold for this
              event's current date. Changing it won't automatically notify those customers or resend their
              tickets - you may want to email them separately. Continue anyway?
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                setDateChangeConfirmOpen(false);
                performSave();
              }}
              className="bg-gradient-orange text-black font-bold hover:opacity-90"
            >
              Change Date Anyway
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Dialog>
  );
};

export default EventFormDialog;
