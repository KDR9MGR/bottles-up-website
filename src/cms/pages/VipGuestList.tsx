import { useEffect, useMemo, useState } from 'react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
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
import { Download, Trash2, UserPlus } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { logAudit } from '@/lib/auditLog';
import type { Database } from '@/types/database';

type GuestRow = Database['public']['Tables']['site_vip_guests']['Row'];
type VenueOption = { id: string; name: string };
type EventOption = { id: string; title: string };

const emptyGuestForm = { firstName: '', lastName: '', email: '', venueId: 'none', eventId: 'none' };

const CmsVipGuestList = () => {
  const { toast } = useToast();
  const [guests, setGuests] = useState<GuestRow[]>([]);
  const [venues, setVenues] = useState<VenueOption[]>([]);
  const [events, setEvents] = useState<EventOption[]>([]);
  const [search, setSearch] = useState('');
  const [loading, setLoading] = useState(true);
  const [form, setForm] = useState(emptyGuestForm);
  const [adding, setAdding] = useState(false);
  const [removingId, setRemovingId] = useState<string | null>(null);

  const loadGuests = async () => {
    const { data } = await supabase.from('site_vip_guests').select('*').order('created_at', { ascending: false });
    setGuests(data ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadGuests();
    supabase
      .from('site_venues')
      .select('id, name')
      .order('name')
      .then(({ data }) => setVenues(data ?? []));
    supabase
      .from('site_events')
      .select('id, title')
      .order('title')
      .then(({ data }) => setEvents(data ?? []));
  }, []);

  const venueName = (id: string | null) => venues.find((v) => v.id === id)?.name ?? '-';
  const eventTitle = (id: string | null) => events.find((e) => e.id === id)?.title ?? '-';

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return guests;
    return guests.filter(
      (g) =>
        g.email.toLowerCase().includes(q) ||
        g.first_name.toLowerCase().includes(q) ||
        g.last_name.toLowerCase().includes(q) ||
        venueName(g.venue_id).toLowerCase().includes(q) ||
        eventTitle(g.event_id).toLowerCase().includes(q),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [guests, search, venues, events]);

  const handleAdd = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.firstName.trim() || !form.lastName.trim() || !form.email.trim()) return;

    setAdding(true);
    const { data, error } = await supabase
      .from('site_vip_guests')
      .insert({
        first_name: form.firstName.trim(),
        last_name: form.lastName.trim(),
        email: form.email.trim(),
        venue_id: form.venueId === 'none' ? null : form.venueId,
        event_id: form.eventId === 'none' ? null : form.eventId,
      })
      .select('id')
      .single();
    setAdding(false);

    if (error) {
      toast({ title: 'Failed to add guest', description: error.message, variant: 'destructive' });
      return;
    }

    toast({ title: 'Added to VIP guest list' });
    logAudit({
      action: 'vip_guest.created',
      entityType: 'site_vip_guests',
      entityId: data?.id,
      details: { email: form.email.trim() },
    });
    setForm(emptyGuestForm);
    loadGuests();
  };

  const handleRemove = async (id: string) => {
    const removed = guests.find((g) => g.id === id);
    setRemovingId(id);
    const { error } = await supabase.from('site_vip_guests').delete().eq('id', id);
    setRemovingId(null);

    if (error) {
      toast({ title: 'Failed to remove', description: error.message, variant: 'destructive' });
      return;
    }
    logAudit({ action: 'vip_guest.removed', entityType: 'site_vip_guests', entityId: id, details: { email: removed?.email } });
    loadGuests();
  };

  const exportCsv = () => {
    const header = 'first_name,last_name,email,venue,event,added';
    const rows = filtered.map((g) =>
      [g.first_name, g.last_name, g.email, venueName(g.venue_id), eventTitle(g.event_id), g.created_at]
        .map((v) => `"${String(v).replace(/"/g, '""')}"`)
        .join(','),
    );
    const csv = [header, ...rows].join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `vip-guest-list-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div>
      <div className="mb-2 flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">VIP Guest List ({guests.length})</h1>
        <Button onClick={exportCsv} variant="outline" className="border-orange-500 text-orange-500 hover:bg-orange-500 hover:text-black">
          <Download className="mr-2 h-4 w-4" />
          Export CSV
        </Button>
      </div>
      <p className="mb-6 max-w-xl text-sm text-gray-400">
        Manually add people to a venue or event's VIP guest list - separate from the{' '}
        <span className="text-gray-300">VIP List</span> newsletter signups.
      </p>

      <form onSubmit={handleAdd} className="mb-6 grid gap-3 rounded-lg border border-gray-800 p-4 sm:grid-cols-2 lg:grid-cols-5">
        <Input
          placeholder="First name"
          value={form.firstName}
          onChange={(e) => setForm((p) => ({ ...p, firstName: e.target.value }))}
          required
        />
        <Input
          placeholder="Last name"
          value={form.lastName}
          onChange={(e) => setForm((p) => ({ ...p, lastName: e.target.value }))}
          required
        />
        <Input
          type="email"
          placeholder="Email"
          value={form.email}
          onChange={(e) => setForm((p) => ({ ...p, email: e.target.value }))}
          required
        />
        <Select value={form.venueId} onValueChange={(v) => setForm((p) => ({ ...p, venueId: v }))}>
          <SelectTrigger>
            <SelectValue placeholder="Venue (optional)" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="none">No venue</SelectItem>
            {venues.map((v) => (
              <SelectItem key={v.id} value={v.id}>
                {v.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={form.eventId} onValueChange={(v) => setForm((p) => ({ ...p, eventId: v }))}>
          <SelectTrigger>
            <SelectValue placeholder="Event (optional)" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="none">No event</SelectItem>
            {events.map((e) => (
              <SelectItem key={e.id} value={e.id}>
                {e.title}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Button type="submit" disabled={adding} className="sm:col-span-2 lg:col-span-5 bg-gradient-orange text-black font-bold hover:opacity-90">
          <UserPlus className="mr-2 h-4 w-4" />
          {adding ? 'Adding...' : 'Add to VIP Guest List'}
        </Button>
      </form>

      <Input
        placeholder="Search by name, email, venue, or event..."
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        className="mb-4 max-w-sm"
      />

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Email</TableHead>
                <TableHead>Venue</TableHead>
                <TableHead>Event</TableHead>
                <TableHead>Added</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((g) => (
                <TableRow key={g.id}>
                  <TableCell>{[g.first_name, g.last_name].filter(Boolean).join(' ')}</TableCell>
                  <TableCell>{g.email}</TableCell>
                  <TableCell>{venueName(g.venue_id)}</TableCell>
                  <TableCell>{eventTitle(g.event_id)}</TableCell>
                  <TableCell>{new Date(g.created_at).toLocaleDateString()}</TableCell>
                  <TableCell className="text-right">
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={removingId === g.id}
                      onClick={() => handleRemove(g.id)}
                    >
                      <Trash2 className="mr-1 h-3 w-3" />
                      Remove
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
              {filtered.length === 0 && (
                <TableRow>
                  <TableCell colSpan={6} className="text-center text-gray-500">
                    No VIP guests yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
};

export default CmsVipGuestList;
