import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { logAudit } from '@/lib/auditLog';
import { SITE_CONTENT_DEFAULTS, type SiteContent } from '@/lib/siteContentDefaults';

const CmsContent = () => {
  const { toast } = useToast();
  const [form, setForm] = useState<SiteContent>(SITE_CONTENT_DEFAULTS);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    supabase
      .from('site_content')
      .select('*')
      .eq('id', 1)
      .maybeSingle()
      .then(({ data }) => {
        if (data) setForm(data);
        setLoading(false);
      });
  }, []);

  const field = (key: keyof SiteContent) => ({
    value: form[key] ?? '',
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
      setForm((prev) => ({ ...prev, [key]: e.target.value })),
  });

  const handleSave = async () => {
    setSaving(true);
    const { id, updated_at, ...updates } = form;
    const { error } = await supabase.from('site_content').update(updates).eq('id', 1);
    setSaving(false);

    if (error) {
      toast({ title: 'Failed to save', description: error.message, variant: 'destructive' });
    } else {
      toast({ title: 'Site content saved' });
      logAudit({ action: 'site_content.updated', entityType: 'site_content', entityId: '1' });
    }
  };

  if (loading) {
    return <div className="text-gray-400">Loading...</div>;
  }

  return (
    <div className="max-w-2xl space-y-6">
      <h1 className="text-2xl font-bold text-white">Site Content</h1>

      <Card className="border-gray-800 bg-gray-900/50">
        <CardHeader>
          <CardTitle className="text-white">Contact Info</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label className="text-gray-300">Contact Email</Label>
            <Input {...field('contact_email')} type="email" />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Contact Phone</Label>
            <Input {...field('contact_phone')} />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Address</Label>
            <Input {...field('address')} />
          </div>
        </CardContent>
      </Card>

      <Card className="border-gray-800 bg-gray-900/50">
        <CardHeader>
          <CardTitle className="text-white">Social Links</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label className="text-gray-300">Instagram</Label>
            <Input {...field('social_instagram')} placeholder="https://instagram.com/..." />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Twitter / X</Label>
            <Input {...field('social_twitter')} placeholder="https://twitter.com/..." />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Facebook</Label>
            <Input {...field('social_facebook')} placeholder="https://facebook.com/..." />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">LinkedIn</Label>
            <Input {...field('social_linkedin')} placeholder="https://linkedin.com/company/..." />
          </div>
        </CardContent>
      </Card>

      <Card className="border-gray-800 bg-gray-900/50">
        <CardHeader>
          <CardTitle className="text-white">Copy</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label className="text-gray-300">Footer Tagline</Label>
            <Textarea {...field('footer_tagline')} rows={3} />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Hero Headline (optional override)</Label>
            <Input {...field('hero_headline')} />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Hero Subtext (optional override)</Label>
            <Textarea {...field('hero_subtext')} rows={3} />
          </div>
        </CardContent>
      </Card>

      <Card className="border-gray-800 bg-gray-900/50">
        <CardHeader>
          <CardTitle className="text-white">Payments</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label className="text-gray-300">Payment Mode</Label>
            <Select
              value={form.payments_mode ?? 'test'}
              onValueChange={(value) => setForm((prev) => ({ ...prev, payments_mode: value as SiteContent['payments_mode'] }))}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="test">Test</SelectItem>
                <SelectItem value="live">Live</SelectItem>
              </SelectContent>
            </Select>
          </div>
        </CardContent>
      </Card>

      <Button
        onClick={handleSave}
        disabled={saving}
        className="bg-gradient-orange text-black font-bold hover:opacity-90"
      >
        {saving ? 'Saving...' : 'Save Changes'}
      </Button>
    </div>
  );
};

export default CmsContent;
