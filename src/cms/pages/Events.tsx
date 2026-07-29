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
import { describeDeleteBlockedError } from '@/lib/friendlyDbError';
import type { Database } from '@/types/database';
import EventFormDialog from '../components/EventFormDialog';

type EventRow = Database['public']['Tables']['site_events']['Row'];

const CmsEvents = () => {
  const { toast } = useToast();
  const [events, setEvents] = useState<EventRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingEvent, setEditingEvent] = useState<EventRow | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<EventRow | null>(null);
  const [blocked, setBlocked] = useState<{ event: EventRow; referencingLabel: string } | null>(null);
  const [unpublishing, setUnpublishing] = useState(false);

  const loadEvents = async () => {
    setLoading(true);
    const { data } = await supabase.from('site_events').select('*').order('start_date', { ascending: true });
    setEvents(data ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadEvents();
  }, []);

  const handleDelete = async () => {
    if (!deleteTarget) return;
    const target = deleteTarget;
    const { error } = await supabase.from('site_events').delete().eq('id', target.id);
    if (error) {
      const blockedInfo = describeDeleteBlockedError(error);
      if (blockedInfo) {
        setDeleteTarget(null);
        setBlocked({ event: target, referencingLabel: blockedInfo.referencingLabel });
        return;
      }
      toast({ title: 'Failed to delete event', description: error.message, variant: 'destructive' });
    } else {
      toast({ title: 'Event deleted' });
      loadEvents();
    }
    setDeleteTarget(null);
  };

  const handleUnpublish = async () => {
    if (!blocked) return;
    setUnpublishing(true);
    const { error } = await supabase.from('site_events').update({ status: 'draft' }).eq('id', blocked.event.id);
    setUnpublishing(false);
    if (error) {
      toast({ title: 'Failed to unpublish event', description: error.message, variant: 'destructive' });
      return;
    }
    toast({ title: 'Event unpublished', description: 'It’s hidden from the site but its data is kept.' });
    setBlocked(null);
    loadEvents();
  };

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">Events</h1>
        <Button
          onClick={() => {
            setEditingEvent(null);
            setDialogOpen(true);
          }}
          className="bg-gradient-orange text-black font-bold hover:opacity-90"
        >
          <Plus className="mr-2 h-4 w-4" />
          New Event
        </Button>
      </div>

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Title</TableHead>
                <TableHead>Venue</TableHead>
                <TableHead>Date</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {events.map((event) => (
                <TableRow key={event.id}>
                  <TableCell>{event.title}</TableCell>
                  <TableCell>{event.venue_name}</TableCell>
                  <TableCell>{new Date(event.start_date).toLocaleString()}</TableCell>
                  <TableCell>
                    <Badge variant={event.status === 'published' ? 'default' : 'secondary'}>
                      {event.status}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-right">
                    <Button
                      size="icon"
                      variant="ghost"
                      onClick={() => {
                        setEditingEvent(event);
                        setDialogOpen(true);
                      }}
                    >
                      <Pencil className="h-4 w-4" />
                    </Button>
                    <Button size="icon" variant="ghost" onClick={() => setDeleteTarget(event)}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
              {events.length === 0 && (
                <TableRow>
                  <TableCell colSpan={5} className="text-center text-gray-500">
                    No events yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      )}

      <EventFormDialog
        event={editingEvent}
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        onSaved={loadEvents}
      />

      <AlertDialog open={!!deleteTarget} onOpenChange={(open) => !open && setDeleteTarget(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete "{deleteTarget?.title}"?</AlertDialogTitle>
            <AlertDialogDescription>
              This also deletes its ticket tiers. If any orders reference this event, deletion will be blocked (kept for records) - cancel/refund those first if you really need to remove it. This cannot be undone.
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
            <AlertDialogTitle>Can't delete "{blocked?.event.title}"</AlertDialogTitle>
            <AlertDialogDescription className="space-y-2">
              <span className="block">
                This event still has {blocked?.referencingLabel} linked to it, so it can't be deleted - that history
                is kept on purpose and is never removed automatically.
              </span>
              <span className="block">To proceed, either:</span>
              <span className="block">
                1. Unpublish it instead (hides it from the site, keeps all data), or
                <br />
                2. Cancel/refund the related {blocked?.referencingLabel} first, then delete the event.
              </span>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Close</AlertDialogCancel>
            {blocked?.event.status === 'published' && (
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

export default CmsEvents;
