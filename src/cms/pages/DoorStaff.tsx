import { useEffect, useState } from 'react';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Switch } from '@/components/ui/switch';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogTrigger,
} from '@/components/ui/dialog';
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
import { Plus, Trash2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { logAudit } from '@/lib/auditLog';
import { STAFF_ROLE_LABELS } from '@/lib/staffDashboard';
import type { Database, StaffRole } from '@/types/database';

type DoorStaffRow = Database['public']['Tables']['door_staff']['Row'] & {
  site_events: { title: string } | null;
};

const emptyForm = {
  name: '',
  email: '',
  role: 'server' as StaffRole,
  eventId: 'none',
  assignedTables: '',
  accessStart: '',
  accessEnd: '',
  canRecordPayments: false,
};

// BottlesUp Server and Pay-at-Club system, section 1: "Change the current
// Door Staff page to Team & Staff." Everything downstream (server
// dashboard, table view, payment recording) depends on roles/assignments/
// permissions existing here first - this is the foundation slice.
const CmsDoorStaff = () => {
  const { toast } = useToast();
  const [staff, setStaff] = useState<DoorStaffRow[]>([]);
  const [events, setEvents] = useState<{ id: string; title: string }[]>([]);
  const [scanCounts, setScanCounts] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [form, setForm] = useState(emptyForm);
  const [adding, setAdding] = useState(false);
  const [removingId, setRemovingId] = useState<string | null>(null);

  const loadStaff = async () => {
    setLoading(true);
    const [{ data }, { data: checkins }] = await Promise.all([
      supabase.from('door_staff').select('*, site_events(title)'),
      supabase
        .from('site_orders')
        .select('checked_in_by, checked_in_at')
        .not('checked_in_by', 'is', null)
        .not('checked_in_at', 'is', null),
    ]);

    const counts: Record<string, number> = {};
    (checkins ?? []).forEach((row) => {
      if (!row.checked_in_by) return;
      counts[row.checked_in_by] = (counts[row.checked_in_by] ?? 0) + 1;
    });

    setScanCounts(counts);
    setStaff((data as DoorStaffRow[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadStaff();
    supabase.from('site_events').select('id, title').order('created_at', { ascending: false }).then(({ data }) => setEvents(data ?? []));
  }, []);

  const handleAdd = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.email.trim()) return;

    setAdding(true);
    const { data, error } = await supabase.functions.invoke('manage-door-staff', {
      body: {
        email: form.email.trim(),
        name: form.name.trim() || null,
        role: form.role,
        event_id: form.eventId === 'none' ? null : form.eventId,
        assigned_tables: form.assignedTables.trim() || null,
        access_start_at: form.accessStart ? new Date(form.accessStart).toISOString() : null,
        access_end_at: form.accessEnd ? new Date(form.accessEnd).toISOString() : null,
        can_record_payments: form.canRecordPayments,
      },
    });
    setAdding(false);

    if (error || data?.error) {
      toast({
        title: 'Failed to add team member',
        description: data?.error ?? error?.message,
        variant: 'destructive',
      });
      return;
    }

    toast({
      title: 'Team member added',
      description: data?.email_sent ? 'Invitation email sent.' : 'Could not send the invitation email - share the sign-in link directly.',
    });
    setForm(emptyForm);
    setDialogOpen(false);
    loadStaff();
  };

  const handleRemove = async (id: string) => {
    const removedEmail = staff.find((s) => s.id === id)?.email ?? 'unknown';
    setRemovingId(id);
    const { error } = await supabase.from('door_staff').delete().eq('id', id);
    setRemovingId(null);

    if (error) {
      toast({ title: 'Failed to remove', description: error.message, variant: 'destructive' });
      return;
    }
    logAudit({ action: 'door_staff.removed', entityType: 'door_staff', entityId: id, details: { email: removedEmail } });
    loadStaff();
  };

  return (
    <div>
      <div className="mb-2 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-bold text-white">Team &amp; Staff ({staff.length})</h1>
        <Dialog open={dialogOpen} onOpenChange={(open) => { setDialogOpen(open); if (!open) setForm(emptyForm); }}>
          <DialogTrigger asChild>
            <Button className="bg-gradient-orange text-black font-bold hover:opacity-90">
              <Plus className="mr-2 h-4 w-4" /> Add Staff
            </Button>
          </DialogTrigger>
          <DialogContent className="border-gray-800 bg-gray-950">
            <DialogHeader>
              <DialogTitle className="text-white">Add Staff</DialogTitle>
            </DialogHeader>
            <form onSubmit={handleAdd} className="space-y-3">
              <div className="grid grid-cols-2 gap-2">
                <div className="space-y-1">
                  <Label className="text-xs">Name</Label>
                  <Input value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} />
                </div>
                <div className="space-y-1">
                  <Label className="text-xs">Email</Label>
                  <Input type="email" required value={form.email} onChange={(e) => setForm((f) => ({ ...f, email: e.target.value }))} />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-2">
                <div className="space-y-1">
                  <Label className="text-xs">Role</Label>
                  <Select value={form.role} onValueChange={(v) => setForm((f) => ({ ...f, role: v as StaffRole }))}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {(Object.keys(STAFF_ROLE_LABELS) as StaffRole[]).map((r) => (
                        <SelectItem key={r} value={r}>{STAFF_ROLE_LABELS[r]}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label className="text-xs">Event (optional)</Label>
                  <Select value={form.eventId} onValueChange={(v) => setForm((f) => ({ ...f, eventId: v }))}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="none">No specific event</SelectItem>
                      {events.map((ev) => (
                        <SelectItem key={ev.id} value={ev.id}>{ev.title}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>

              <div className="space-y-1">
                <Label className="text-xs">Assigned tables or section (optional)</Label>
                <Input
                  placeholder="e.g. Booths 1-4, VIP section"
                  value={form.assignedTables}
                  onChange={(e) => setForm((f) => ({ ...f, assignedTables: e.target.value }))}
                />
              </div>

              <div className="grid grid-cols-2 gap-2">
                <div className="space-y-1">
                  <Label className="text-xs">Access starts (optional)</Label>
                  <Input type="datetime-local" value={form.accessStart} onChange={(e) => setForm((f) => ({ ...f, accessStart: e.target.value }))} />
                </div>
                <div className="space-y-1">
                  <Label className="text-xs">Access ends (optional)</Label>
                  <Input type="datetime-local" value={form.accessEnd} onChange={(e) => setForm((f) => ({ ...f, accessEnd: e.target.value }))} />
                </div>
              </div>

              <div className="flex items-center justify-between rounded-lg border border-gray-800 p-3">
                <Label className="text-sm">Permission to record club payments</Label>
                <Switch checked={form.canRecordPayments} onCheckedChange={(v) => setForm((f) => ({ ...f, canRecordPayments: v }))} />
              </div>

              <DialogFooter>
                <Button type="submit" disabled={adding} className="w-full bg-gradient-orange text-black font-bold hover:opacity-90">
                  {adding ? 'Adding...' : 'Add Staff'}
                </Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      </div>
      <p className="mb-6 max-w-xl text-sm text-gray-400">
        People who can sign in at <span className="font-mono">/staff/login</span> for check-in, table service, and
        club payment recording, scoped to whatever role and permissions they're given here.
      </p>

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name / Email</TableHead>
                <TableHead>Role</TableHead>
                <TableHead>Event</TableHead>
                <TableHead>Tables/Section</TableHead>
                <TableHead>Access Window</TableHead>
                <TableHead>Payments</TableHead>
                <TableHead>Scans</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {staff.map((row) => (
                <TableRow key={row.id}>
                  <TableCell>
                    <div>{row.name ?? row.email}</div>
                    {row.name && <div className="text-xs text-gray-500">{row.email}</div>}
                  </TableCell>
                  <TableCell>
                    <Badge variant="outline" className="border-gray-700">{STAFF_ROLE_LABELS[row.role] ?? row.role}</Badge>
                  </TableCell>
                  <TableCell className="text-xs text-gray-400">{row.site_events?.title ?? '-'}</TableCell>
                  <TableCell className="max-w-[140px] text-xs text-gray-400">{row.assigned_tables ?? '-'}</TableCell>
                  <TableCell className="text-xs text-gray-500">
                    {row.access_start_at || row.access_end_at
                      ? `${row.access_start_at ? new Date(row.access_start_at).toLocaleString() : 'now'} - ${row.access_end_at ? new Date(row.access_end_at).toLocaleString() : 'open'}`
                      : 'Always'}
                  </TableCell>
                  <TableCell>
                    {row.can_record_payments ? (
                      <Badge variant="outline" className="border-green-600 text-green-400">Yes</Badge>
                    ) : (
                      <Badge variant="outline" className="border-gray-700 text-gray-500">No</Badge>
                    )}
                  </TableCell>
                  <TableCell>{scanCounts[row.id] ?? 0}</TableCell>
                  <TableCell className="text-right">
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={removingId === row.id}
                      onClick={() => handleRemove(row.id)}
                    >
                      <Trash2 className="mr-1 h-3 w-3" />
                      Remove
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
              {staff.length === 0 && (
                <TableRow>
                  <TableCell colSpan={8} className="text-center text-gray-500">
                    No team members yet.
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

export default CmsDoorStaff;
