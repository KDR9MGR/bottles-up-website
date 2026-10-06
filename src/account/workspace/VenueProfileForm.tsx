import { useState } from 'react';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';
import { AccountError, updateVenueProfile } from '@/lib/account';
import { uploadBusinessMedia } from '@/lib/uploadBusinessMedia';

export interface VenueProfile {
  id: string;
  name: string;
  description: string | null;
  address: string | null;
  cover_image_url: string | null;
}

/** Edits the public profile of a venue: name, description, address and cover photo. Never its status or owner. */
const VenueProfileForm = ({ orgId, venue, onSaved }: { orgId: string; venue: VenueProfile; onSaved: () => void }) => {
  const { toast } = useToast();
  const [name, setName] = useState(venue.name);
  const [description, setDescription] = useState(venue.description ?? '');
  const [address, setAddress] = useState(venue.address ?? '');
  const [cover, setCover] = useState(venue.cover_image_url ?? '');
  const [saving, setSaving] = useState(false);
  const [uploading, setUploading] = useState(false);

  const onCover = async (file: File | undefined) => {
    if (!file) return;
    setUploading(true);
    try {
      setCover(await uploadBusinessMedia(orgId, file));
    } catch (err) {
      toast({ title: 'Photo not uploaded', description: err instanceof Error ? err.message : 'Try another image.', variant: 'destructive' });
    } finally {
      setUploading(false);
    }
  };

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      await updateVenueProfile(venue.id, { name, description, address, cover_image_url: cover });
      toast({ title: 'Venue profile saved' });
      onSaved();
    } catch (err) {
      toast({ title: 'Could not save', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={save} className="mt-5 space-y-4 border-t border-gray-800 pt-5" noValidate>
      <h4 className="text-sm font-medium text-white">Venue profile</h4>
      <div className="space-y-2">
        <Label htmlFor={`vn-${venue.id}`} className="text-gray-300">Name</Label>
        <Input id={`vn-${venue.id}`} value={name} onChange={(e) => setName(e.target.value)} maxLength={120} required />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`vd-${venue.id}`} className="text-gray-300">Description</Label>
        <Textarea id={`vd-${venue.id}`} value={description} onChange={(e) => setDescription(e.target.value)} rows={3} maxLength={4000} />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`va-${venue.id}`} className="text-gray-300">Address</Label>
        <Input id={`va-${venue.id}`} value={address} onChange={(e) => setAddress(e.target.value)} maxLength={300} />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`vc-${venue.id}`} className="text-gray-300">Cover photo</Label>
        <div className="flex items-center gap-3">
          {cover && <img src={cover} alt="Cover" className="h-14 w-20 rounded-md border border-gray-800 object-cover" />}
          <Input id={`vc-${venue.id}`} type="file" accept="image/jpeg,image/png,image/webp,image/heic,image/heif" onChange={(e) => void onCover(e.target.files?.[0])} disabled={uploading} />
          {uploading && <Loader2 className="h-4 w-4 shrink-0 animate-spin text-gray-400" />}
        </div>
      </div>
      <Button type="submit" disabled={saving} className="bg-gradient-orange font-bold text-black hover:opacity-90">
        {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Save venue profile'}
      </Button>
    </form>
  );
};

export default VenueProfileForm;
