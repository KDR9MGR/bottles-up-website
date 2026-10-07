import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { QRCodeCanvas } from 'qrcode.react';
import { Check, Copy, Download, ExternalLink } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { useToast } from '@/hooks/use-toast';
import { fetchOrgVenues } from '@/lib/account';
import { onboardingPath, type Business, type Workspace } from '@/lib/accountRouting';
import { bookingLink, isLive, linkNote, qrFileName } from '@/lib/bookingLink';
import { SITE_URL } from '@/lib/features';
import { supabase } from '@/lib/supabase';
import { VerificationBanner } from './OwnerSections';

interface VenueLink {
  id: string;
  name: string;
  slug: string | null;
  status: string;
}

// The printed QR code is drawn large and shown small, so the downloaded picture stays sharp on a poster or table card.
const QR_PIXELS = 1024;

const LinkCard = ({ venue }: { venue: VenueLink }) => {
  const { toast } = useToast();
  const canvasHost = useRef<HTMLDivElement>(null);
  const [copied, setCopied] = useState(false);
  const link = bookingLink(SITE_URL, venue);
  const live = isLive(venue.status);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(link);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      // Some browsers refuse clipboard access: the link is in a box the person can select and copy themselves.
      toast({ title: 'Copy it by hand', description: 'Select the link and copy it.' });
    }
  };

  const download = () => {
    const canvas = canvasHost.current?.querySelector('canvas');
    if (!canvas) return;
    const a = document.createElement('a');
    a.href = canvas.toDataURL('image/png');
    a.download = qrFileName(venue.name);
    document.body.appendChild(a);
    a.click();
    a.remove();
  };

  return (
    <article className="rounded-2xl border border-gray-800 bg-gray-900/50 p-5">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-lg font-semibold text-white">{venue.name}</h3>
        <span className="rounded-full border border-gray-700 px-2.5 py-0.5 text-xs text-gray-300">{live ? 'Live' : 'Draft'}</span>
      </header>

      <div className="mt-4 grid gap-6 sm:grid-cols-[1fr_auto]">
        <div className="min-w-0 space-y-3">
          <label htmlFor={`link-${venue.id}`} className="text-sm text-gray-300">Booking link</label>
          <div className="flex gap-2">
            <Input id={`link-${venue.id}`} readOnly value={link} onFocus={(e) => e.currentTarget.select()} className="font-mono text-sm" />
            <Button type="button" variant="outline" onClick={() => void copy()} className="shrink-0 gap-2">
              {copied ? <Check className="h-4 w-4 text-green-400" /> : <Copy className="h-4 w-4" />}
              {copied ? 'Copied' : 'Copy'}
            </Button>
          </div>
          <p className={`text-sm ${live ? 'text-green-300' : 'text-amber-300'}`}>{linkNote(venue.status)}</p>
          {live && (
            <a href={link} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1.5 text-sm font-medium text-primary hover:underline">
              Preview what guests see <ExternalLink className="h-3.5 w-3.5" />
            </a>
          )}
        </div>

        <div className="flex flex-col items-center gap-3">
          <div ref={canvasHost} className="rounded-lg bg-white p-2">
            <QRCodeCanvas value={link} size={QR_PIXELS} level="M" marginSize={1} bgColor="#ffffff" fgColor="#000000" style={{ width: 160, height: 160 }} aria-label={`QR code for the ${venue.name} booking link`} role="img" />
          </div>
          <Button type="button" variant="outline" size="sm" onClick={download} className="gap-2">
            <Download className="h-4 w-4" /> Download QR code
          </Button>
        </div>
      </div>
    </article>
  );
};

/**
 * Booking Link: the address guests use to book at each venue, with a copyable link, a QR code to print, and whether it works
 * yet. It points at the existing public venue page. Short addresses and bookings attributed to this link are not built.
 */
const BookingLinkSection = ({ workspace, business }: { workspace: Workspace; business: Business | undefined }) => {
  const [venues, setVenues] = useState<VenueLink[] | null>(null);
  const [failed, setFailed] = useState(false);

  const load = useCallback(async () => {
    try {
      const mine = await fetchOrgVenues(workspace.orgId);
      if (mine.length === 0) { setVenues([]); return; }
      const { data, error } = await supabase.from('site_venues').select('id, name, slug, status').in('id', mine.map((v) => v.venueId));
      if (error) throw error;
      const byId = new Map((data ?? []).map((r) => [r.id as string, r]));
      setVenues(mine.map((v) => {
        const row = byId.get(v.venueId);
        return { id: v.venueId, name: String(row?.name ?? v.name), slug: typeof row?.slug === 'string' ? row.slug : null, status: String(row?.status ?? v.status) };
      }));
    } catch {
      setFailed(true);
    }
  }, [workspace.orgId]);

  useEffect(() => { void load(); }, [load]);

  return (
    <div>
      <VerificationBanner workspace={workspace} business={business} />
      {failed && <p className="text-sm text-red-300" role="alert">Your venues could not be loaded. Try again in a moment.</p>}
      {!failed && venues === null && <p className="text-sm text-gray-500">Loading your venues…</p>}
      {venues?.length === 0 && (
        <p className="text-sm text-gray-400">
          You have no venues yet, so there is nothing to link to. <Link to={onboardingPath(workspace.orgId)} className="text-primary hover:underline">Add or claim one</Link>.
        </p>
      )}
      <div className="space-y-5">
        {venues?.map((v) => <LinkCard key={v.id} venue={v} />)}
      </div>
      {venues && venues.length > 0 && (
        <p className="mt-6 text-xs text-gray-500">
          Short venue addresses and counting the bookings that came through this link are not available yet.
        </p>
      )}
    </div>
  );
};

export default BookingLinkSection;
