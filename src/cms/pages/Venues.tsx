import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
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
import { Plus, Pencil, Trash2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import VenueFormDialog from '../components/VenueFormDialog';

type VenueRow = Database['public']['Tables']['site_venues']['Row'];

const CmsVenues = () => {
  const { toast } = useToast();
  const [venues, setVenues] = useState<VenueRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingVenue, setEditingVenue] = useState<VenueRow | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<VenueRow | null>(null);

  const loadVenues = async () => {
    setLoading(true);
    const { data } = await supabase.from('site_venues').select('*').order('name', { ascending: true });
    setVenues(data ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadVenues();
  }, []);

  const handleDelete = async () => {
    if (!deleteTarget) return;
    const { error } = await supabase.from('site_venues').delete().eq('id', deleteTarget.id);
    if (error) {
      toast({ title: 'Failed to delete venue', description: error.message, variant: 'destructive' });
    } else {
      toast({ title: 'Venue deleted' });
      loadVenues();
    }
    setDeleteTarget(null);
  };

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
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

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Address</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {venues.map((venue) => (
                <TableRow key={venue.id}>
                  <TableCell>{venue.name}</TableCell>
                  <TableCell>{venue.address ?? '-'}</TableCell>
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
              ))}
              {venues.length === 0 && (
                <TableRow>
                  <TableCell colSpan={4} className="text-center text-gray-500">
                    No venues yet.
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
    </div>
  );
};

export default CmsVenues;
