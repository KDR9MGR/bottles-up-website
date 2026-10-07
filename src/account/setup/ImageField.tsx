import { useState } from 'react';
import { Loader2 } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { uploadBusinessMedia } from '@/lib/uploadBusinessMedia';

interface Props {
  id: string;
  label: string;
  orgId: string;
  value: string;
  onChange: (url: string) => void;
  /** Wide previews for floor plans; small squares for bottles and tables. */
  wide?: boolean;
  hint?: string;
  /** A floor plan cannot be saved without its image, so there is nothing to remove it to. */
  required?: boolean;
}

/** Uploads a photo into the business's own storage folder and hands back its address. */
const ImageField = ({ id, label, orgId, value, onChange, wide = false, hint, required = false }: Props) => {
  const { toast } = useToast();
  const [uploading, setUploading] = useState(false);

  const pick = async (file: File | undefined) => {
    if (!file) return;
    setUploading(true);
    try {
      onChange(await uploadBusinessMedia(orgId, file));
    } catch (err) {
      toast({ title: 'Photo not uploaded', description: err instanceof Error ? err.message : 'Try another image.', variant: 'destructive' });
    } finally {
      setUploading(false);
    }
  };

  return (
    <div className="space-y-2">
      <Label htmlFor={id} className="text-gray-300">{label}</Label>
      <div className="flex items-center gap-3">
        {value && <img src={value} alt="" className={`${wide ? 'h-16 w-28' : 'h-14 w-14'} shrink-0 rounded-md border border-gray-800 object-cover`} />}
        <Input id={id} type="file" accept="image/jpeg,image/png,image/webp,image/heic,image/heif" onChange={(e) => void pick(e.target.files?.[0])} disabled={uploading} />
        {uploading && <Loader2 className="h-4 w-4 shrink-0 animate-spin text-gray-400" aria-label="Uploading" />}
      </div>
      {hint && <p className="text-xs text-gray-500">{hint}</p>}
      {value && !uploading && !required && (
        <button type="button" onClick={() => onChange('')} className="text-xs text-gray-400 underline hover:text-white">Remove photo</button>
      )}
    </div>
  );
};

export default ImageField;
