import { useEffect, useMemo, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
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
import { Plus, Pencil, Trash2, AlertTriangle, Search } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { describeDeleteBlockedError } from '@/lib/friendlyDbError';
import type { Database, EventStatus } from '@/types/database';
import VenueFormDialog from '../components/VenueFormDialog';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];
type VenueWithCount = VenueRow & { site_table_types: { count: number }[] };

// Deterministic so a venue's avatar color stays stable across reloads,
// rather than random and re-shuffling every render.
const AVATAR_COLORS = [
  'bg-orange-500/20 text-orange-400',
  'bg-blue-500/20 text-blue-400',
  'bg-purple-500/20 text-purple-400',
  'bg-teal-500/20 text-teal-400',
  'bg-pink-500/20 text-pink-400',
  'bg-amber-500/20 text-amber-400',
];
const avatarColorFor = (name: string) => AVATAR_COLORS[name.charCodeAt(0) % AVATAR_COLORS.length];

const CmsVenues = () => {
  const { toast } = useToast();
  const [venues, setVenues] = useState<VenueWithCount[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingVenue, setEditingVenue] = useState<VenueRow | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<VenueRow | null>(null);
  const [blocked, setBlocked] = useState<{ venue: VenueRow; referencingLabel: string } | null>(null);
  const [unpublishing, setUnpublishing] = useState(false);
  const [search, setSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState<EventStatus | 'all'>('all');

  const loadVenues = async () => {
    setLoading(true);
    // Embedded count lets the list flag published venues with zero table types -
    // those are invisible on the public VIP Tables page despite being "published".
    const { data } = await supabase
      .from('site_venues')
      .select('*, site_table_types(count)')
      .order('name', { ascending: true });
    setVenues((data as VenueWithCount[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadVenues();
  }, []);

  const filtered = useMemo(
    () =>
      venues
        .filter((v) => statusFilter === 'all' || v.status === statusFilter)
        .filter((v) => !search.trim() || v.name.toLowerCase().includes(search.trim().toLowerCase())),
    [venues, statusFilter, search],
  );
  const publishedCount = venues.filter((v) => v.status === 'published').length;
  const draftCount = venues.filter((v) => v.status === 'draft').length;

  const handleDelete = async () => {
    if (!deleteTarget) return;
    const target = deleteTarget;
    const { error } = await supabase.from('site_venues').delete().eq('id', target.id);
    if (error) {
      const blockedInfo = describeDeleteBlockedError(error);
      if (blockedInfo) {
        setDeleteTarget(null);
        setBlocked({ venue: target, referencingLabel: blockedInfo.referencingLabel });
        return;
      }
      toast({ title: 'Failed to delete venue', description: error.message, variant: 'destructive' });
    } else {
      toast({ title: 'Venue deleted' });
      loadVenues();
    }
    setDeleteTarget(null);
  };

  const handleUnpublish = async () => {
    if (!blocked) return;
    setUnpublishing(true);
    const { error } = await supabase.from('site_venues').update({ status: 'draft' }).eq('id', blocked.venue.id);
    setUnpublishing(false);
    if (error) {
      toast({ title: 'Failed to unpublish venue', description: error.message, variant: 'destructive' });
      return;
    }
    toast({ title: 'Venue unpublished', description: 'It’s hidden from the site but its data is kept.' });
    setBlocked(null);
    loadVenues();
  };

  return (
    <div>
      <div className="mb-1 flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">Venues</h1>
        <Button
          onClick={() => {
            setEditingVenue(null);
            setDialogOpen(true);
          }}
          className="bg-gradient-orange text-black font-bold hover:opacity-90"
        >
          <Plus className="mr-2 h-4 w-4" />
          New Venue
        </Button>
      </div>
      <p className="mb-4 text-sm text-gray-500">
        {venues.length} {venues.length === 1 ? 'venue' : 'venues'} · {publishedCount} published · {draftCount} drafts
      </p>

      <div className="mb-4 flex gap-2">
        <div className="relative flex-1 max-w-sm">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-500" />
          <Input
            placeholder="Search venues"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-8"
          />
        </div>
        <Select value={statusFilter} onValueChange={(v) => setStatusFilter(v as EventStatus | 'all')}>
          <SelectTrigger className="w-40">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">All statuses</SelectItem>
            <SelectItem value="published">Published</SelectItem>
            <SelectItem value="draft">Draft</SelectItem>
          </SelectContent>
        </Select>
      </div>

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Address</TableHead>
                <TableHead>Capacity</TableHead>
                <TableHead>Tables</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((venue) => {
                const tableTypeCount = venue.site_table_types[0]?.count ?? 0;
                const noTableTypesWhilePublished = venue.status === 'published' && tableTypeCount === 0;
                return (
                <TableRow key={venue.id}>
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <span
                        className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-bold ${avatarColorFor(venue.name)}`}
                      >
                        {venue.name.charAt(0).toUpperCase()}
                      </span>
                      <span>{venue.name}</span>
                    </div>
                    {noTableTypesWhilePublished && (
                      <span className="ml-9 mt-0.5 inline-flex items-center gap-1 text-xs font-medium text-amber-500">
                        <AlertTriangle className="h-3.5 w-3.5" />
                        No table types - won't show on VIP Tables
                      </span>
                    )}
                  </TableCell>
                  <TableCell>
                    {venue.address ?? <span className="text-gray-600">Address not set</span>}
                  </TableCell>
                  <TableCell>{venue.capacity ?? '—'}</TableCell>
                  <TableCell>{tableTypeCount || '—'}</TableCell>
                  <TableCell>
                    <Badge variant={venue.status === 'published' ? 'default' : 'secondary'}>
                      {venue.status}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-right">
                    <Button
                      size="icon"
                      variant="ghost"
                      onClick={() => {
                        setEditingVenue(venue);
                        setDialogOpen(true);
                      }}
                    >
                      <Pencil className="h-4 w-4" />
                    </Button>
                    <Button size="icon" variant="ghost" onClick={() => setDeleteTarget(venue)}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </TableCell>
                </TableRow>
                );
              })}
              {filtered.length === 0 && (
                <TableRow>
                  <TableCell colSpan={6} className="text-center text-gray-500">
                    {venues.length === 0 ? 'No venues yet.' : 'No venues match your search.'}
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      )}

      <VenueFormDialog
        venue={editingVenue}
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        onSaved={loadVenues}
      />

      <AlertDialog open={!!deleteTarget} onOpenChange={(open) => !open && setDeleteTarget(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete "{deleteTarget?.name}"?</AlertDialogTitle>
            <AlertDialogDescription>
              This also deletes its table types and time slots. If any bookings reference this venue, deletion will
              be blocked (kept for records) - cancel/refund those first if you really need to remove it. This cannot
              be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={handleDelete}>Delete</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog open={!!blocked} onOpenChange={(open) => !open && setBlocked(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Can't delete "{blocked?.venue.name}"</AlertDialogTitle>
            <AlertDialogDescription className="space-y-2">
              <span className="block">
                This venue still has {blocked?.referencingLabel} linked to it, so it can't be deleted - that history
                is kept on purpose and is never removed automatically.
              </span>
              <span className="block">To proceed, either:</span>
              <span className="block">
                1. Unpublish it instead (hides it from the site, keeps all data), or
                <br />
                2. Cancel/refund the related {blocked?.referencingLabel} first, then delete the venue.
              </span>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Close</AlertDialogCancel>
            {blocked?.venue.status === 'published' && (
              <AlertDialogAction onClick={handleUnpublish} disabled={unpublishing}>
                {unpublishing ? 'Unpublishing...' : 'Unpublish Instead'}
              </AlertDialogAction>
            )}
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

export default CmsVenues;
