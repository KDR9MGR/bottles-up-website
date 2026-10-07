import { useState } from 'react';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';
import { AccountError, saveBusinessDetails, type BusinessDetails } from '@/lib/account';
import type { BusinessKind } from '@/lib/accountRouting';
import { uploadBusinessMedia, imageProblem } from '@/lib/uploadBusinessMedia';
import { stateInfo, type VerificationState } from '@/lib/verification';

interface Props {
  orgId: string;
  kind: BusinessKind;
  details: BusinessDetails;
  state: VerificationState;
  /** Keys the database says are still missing, to point at the fields. */
  missing: string[];
  onSaved: () => void;
}

const SOCIALS = ['instagram', 'tiktok', 'x', 'facebook', 'youtube'] as const;

const Field = ({ id, label, hint, required, missing, children }: { id: string; label: string; hint?: string; required?: boolean; missing?: boolean; children: React.ReactNode }) => (
  <div className="space-y-2" id={`field-${id}`}>
    <Label htmlFor={id} className="text-gray-300">
      {label} {required && <span className="text-gray-500">(required)</span>}
    </Label>
    {children}
    {missing ? <p className="text-xs text-amber-400">Needed before you can submit.</p> : hint ? <p className="text-xs text-gray-500">{hint}</p> : null}
  </div>
);

/**
 * The business's legal and contact details. Identity fields lock while the business is under review or
 * verified (changing them would change what was reviewed); the public-facing ones stay editable.
 */
const BusinessDetailsForm = ({ orgId, kind, details, state, missing, onSaved }: Props) => {
  const { toast } = useToast();
  const locked = !stateInfo(state).canEditDetails;
  const [v, setV] = useState({
    legal_name: details.legal_name ?? '',
    representative_name: details.representative_name ?? '',
    representative_role: details.representative_role ?? '',
    representative_phone: details.representative_phone ?? '',
    contact_email: details.contact_email ?? '',
    contact_phone: details.contact_phone ?? '',
    address: details.address ?? '',
    city: details.city ?? '',
    website: details.website ?? '',
    description: details.description ?? '',
    logo_url: details.logo_url ?? '',
  });
  const [social, setSocial] = useState<Record<string, string>>(details.social_links ?? {});
  const [confirmed, setConfirmed] = useState(details.representative_confirmed_at != null);
  const [saving, setSaving] = useState(false);
  const [uploading, setUploading] = useState(false);

  const set = (key: keyof typeof v) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setV((prev) => ({ ...prev, [key]: e.target.value }));
  const isMissing = (key: string) => missing.includes(key);

  const onLogo = async (file: File | undefined) => {
    if (!file) return;
    setUploading(true);
    try {
      const url = await uploadBusinessMedia(orgId, file);
      setV((prev) => ({ ...prev, logo_url: url }));
    } catch (err) {
      toast({ title: 'Logo not uploaded', description: err instanceof Error ? err.message : imageProblem(file) ?? 'Try another image.', variant: 'destructive' });
    } finally {
      setUploading(false);
    }
  };

  const save = async () => {
    setSaving(true);
    try {
      const open = { description: v.description, website: v.website, logo_url: v.logo_url, social_links: social };
      const identity = {
        legal_name: v.legal_name,
        representative_name: v.representative_name,
        representative_role: v.representative_role,
        representative_phone: v.representative_phone,
        contact_email: v.contact_email,
        contact_phone: v.contact_phone,
        address: v.address,
        city: v.city,
        representative_confirmed: confirmed,
      };
      await saveBusinessDetails(orgId, locked ? open : { ...identity, ...open });
      toast({ title: 'Saved' });
      onSaved();
    } catch (err) {
      toast({ title: 'Could not save', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={(e) => { e.preventDefault(); void save(); }} className="space-y-5" noValidate>
      {locked && (
        <p className="rounded-lg border border-gray-800 bg-black/40 p-3 text-sm text-gray-400">
          Your business details are locked while they are {state === 'verified' ? 'verified' : 'under review'}. You can still update your description, website, logo and social links.
        </p>
      )}
      <div className="grid gap-5 sm:grid-cols-2">
        <Field id="legal_name" label="Legal business name" required missing={isMissing('legal_name')}>
          <Input id="legal_name" value={v.legal_name} onChange={set('legal_name')} disabled={locked} maxLength={200} />
        </Field>
        <Field id="representative_name" label="Representative name" required missing={isMissing('representative_name')}>
          <Input id="representative_name" value={v.representative_name} onChange={set('representative_name')} disabled={locked} />
        </Field>
        <Field id="representative_role" label="Their role" hint="For example Owner or General Manager.">
          <Input id="representative_role" value={v.representative_role} onChange={set('representative_role')} disabled={locked} />
        </Field>
        <Field id="representative_phone" label="Representative phone" required missing={isMissing('representative_phone')}>
          <Input id="representative_phone" type="tel" value={v.representative_phone} onChange={set('representative_phone')} disabled={locked} autoComplete="tel" />
        </Field>
        <Field id="contact_email" label="Business contact email" required missing={isMissing('contact_email')}>
          <Input id="contact_email" type="email" value={v.contact_email} onChange={set('contact_email')} disabled={locked} />
        </Field>
        <Field id="contact_phone" label="Business phone">
          <Input id="contact_phone" type="tel" value={v.contact_phone} onChange={set('contact_phone')} disabled={locked} />
        </Field>
        <Field id="address" label="Business address" required missing={isMissing('address')}>
          <Input id="address" value={v.address} onChange={set('address')} disabled={locked} maxLength={300} />
        </Field>
        <Field id="city" label="City">
          <Input id="city" value={v.city} onChange={set('city')} disabled={locked} />
        </Field>
      </div>

      <Field
        id="description"
        label={kind === 'organizer' ? 'About your events' : 'About your business'}
        required={kind === 'organizer'}
        missing={isMissing('description')}
        hint="Shown to guests."
      >
        <Textarea id="description" value={v.description} onChange={set('description')} rows={3} maxLength={2000} />
      </Field>

      <div className="grid gap-5 sm:grid-cols-2">
        <Field id="website" label="Website" hint="Starting with https://">
          <Input id="website" type="url" value={v.website} onChange={set('website')} />
        </Field>
        <Field id="logo" label="Logo" hint="JPEG, PNG or WebP, up to 5 MB.">
          <div className="flex items-center gap-3">
            {v.logo_url && <img src={v.logo_url} alt="Current logo" className="h-10 w-10 rounded-md border border-gray-800 object-cover" />}
            <Input id="logo" type="file" accept="image/jpeg,image/png,image/webp,image/heic,image/heif" onChange={(e) => void onLogo(e.target.files?.[0])} disabled={uploading} />
            {uploading && <Loader2 className="h-4 w-4 shrink-0 animate-spin text-gray-400" />}
          </div>
        </Field>
      </div>

      <fieldset className="space-y-3">
        <legend className="text-sm text-gray-300">Social links <span className="text-gray-500">(optional)</span></legend>
        <div className="grid gap-3 sm:grid-cols-2">
          {SOCIALS.map((k) => (
            <Input
              key={k}
              aria-label={k}
              placeholder={k === 'x' ? 'X @handle' : `${k[0].toUpperCase()}${k.slice(1)} @handle`}
              value={social[k] ?? ''}
              onChange={(e) => setSocial((prev) => ({ ...prev, [k]: e.target.value }))}
              maxLength={200}
            />
          ))}
        </div>
      </fieldset>

      <div id="field-representative_confirmed" className="flex items-start gap-3 rounded-lg border border-gray-800 bg-black/40 p-3">
        <Checkbox id="confirm" checked={confirmed} onCheckedChange={(c) => setConfirmed(c === true)} disabled={locked} className="mt-0.5" />
        <Label htmlFor="confirm" className="text-sm font-normal text-gray-300">
          I am 18 or older and I am allowed to represent this business.
          {isMissing('representative_confirmed') && <span className="mt-1 block text-xs text-amber-400">Needed before you can submit.</span>}
        </Label>
      </div>

      <div className="flex flex-wrap gap-3">
        <Button type="submit" disabled={saving} className="bg-gradient-orange font-bold text-black hover:opacity-90">
          {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Save draft'}
        </Button>
      </div>
    </form>
  );
};

export default BusinessDetailsForm;
