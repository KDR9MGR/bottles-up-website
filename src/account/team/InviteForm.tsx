import { useCallback, useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { AccountError, createShift, emailInvitation, inviteMember, invitableRoles, listShifts } from '@/lib/account';
import { ROLE_LABEL, isWorkspaceRole } from '@/lib/roleNavigation';
import { buildInvitePayload, describeAccess, invitationLink, localInputToIso, validateInvite, type InviteForm as Form, type Shift } from '@/lib/team';
import NativeSelect from '../components/NativeSelect';
import type { IssuedInvite } from './InviteResult';

interface Props {
  orgId: string;
  businessName: string;
  venues: { venueId: string; name: string }[];
  onIssued: (invite: IssuedInvite) => void;
  onClose: () => void;
}

const roleName = (role: string) => (isWorkspaceRole(role) ? ROLE_LABEL[role] : role);

/**
 * Invite someone to a club. The roles offered come from the database (invitable_roles), so a manager is never shown
 * "Manager" and nobody is offered something the server would refuse. Access can be ongoing or temporary, and can be
 * tied to a shift.
 */
const InviteForm = ({ orgId, businessName, venues, onIssued, onClose }: Props) => {
  const { toast } = useToast();
  const [form, setForm] = useState<Form>({
    email: '', role: '', venueId: venues[0]?.venueId ?? '', temporary: false, start: '', end: '', shiftId: '',
  });
  const [roles, setRoles] = useState<string[] | null>(null);
  const [shifts, setShifts] = useState<Shift[]>([]);
  const [problems, setProblems] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [newShift, setNewShift] = useState<{ name: string; start: string; end: string } | null>(null);

  const set = <K extends keyof Form>(key: K, value: Form[K]) => setForm((f) => ({ ...f, [key]: value }));

  // What may be offered depends on the club: reload roles and shifts when it changes.
  useEffect(() => {
    if (!form.venueId) return;
    let cancelled = false;
    setRoles(null);
    Promise.all([invitableRoles(orgId, form.venueId), listShifts(form.venueId).catch(() => [] as Shift[])]).then(([r, s]) => {
      if (cancelled) return;
      setRoles(r);
      setShifts(s);
      setForm((f) => ({ ...f, role: r.includes(f.role) ? f.role : r[0] ?? '', shiftId: s.some((x) => x.shiftId === f.shiftId) ? f.shiftId : '' }));
    }).catch(() => { if (!cancelled) setRoles([]); });
    return () => { cancelled = true; };
  }, [orgId, form.venueId]);

  const addShift = useCallback(async () => {
    if (!newShift) return;
    const start = localInputToIso(newShift.start);
    const end = localInputToIso(newShift.end);
    if (!newShift.name.trim() || !start || !end || new Date(end) <= new Date(start)) {
      toast({ title: 'Give the shift a name, a start and a later end', variant: 'destructive' });
      return;
    }
    try {
      const id = await createShift(form.venueId, newShift.name.trim(), start, end);
      setShifts(await listShifts(form.venueId));
      set('shiftId', id);
      setNewShift(null);
    } catch (err) {
      toast({ title: 'Could not create the shift', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    }
  }, [newShift, form.venueId, toast]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const found = validateInvite(form);
    setProblems(found);
    if (found.length > 0) return;
    setBusy(true);
    try {
      const payload = buildInvitePayload(form);
      const { invitationId, token } = await inviteMember(orgId, payload);
      const outcome = await emailInvitation(invitationId, token);
      onIssued({
        email: payload.email,
        roleLabel: roleName(payload.role),
        businessName,
        link: invitationLink(window.location.origin, token),
        outcome,
      });
    } catch (err) {
      toast({ title: 'Could not create the invitation', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setBusy(false);
    }
  };

  const noRoles = roles !== null && roles.length === 0;

  return (
    <form onSubmit={submit} noValidate aria-label="Invite someone" className="mb-6 space-y-4 rounded-xl border border-gray-800 bg-gray-900/60 p-4 sm:p-5">
      <h2 className="text-base font-semibold text-white">Invite someone</h2>

      {problems.length > 0 && (
        <ul role="alert" className="list-disc space-y-1 rounded-lg border border-amber-500/40 bg-amber-500/10 p-3 pl-7 text-sm text-amber-200">
          {problems.map((p) => <li key={p}>{p}</li>)}
        </ul>
      )}

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-2 sm:col-span-2">
          <Label htmlFor="inv-email" className="text-gray-300">Email</Label>
          <Input id="inv-email" type="email" value={form.email} onChange={(e) => set('email', e.target.value)} autoComplete="off" />
          <p className="text-xs text-gray-500">They must sign in with this address to accept.</p>
        </div>
        {venues.length > 1 && (
          <div className="space-y-2">
            <Label htmlFor="inv-venue" className="text-gray-300">Club</Label>
            <NativeSelect id="inv-venue" value={form.venueId} onChange={(e) => set('venueId', e.target.value)}>
              {venues.map((v) => <option key={v.venueId} value={v.venueId}>{v.name}</option>)}
            </NativeSelect>
          </div>
        )}
        <div className="space-y-2">
          <Label htmlFor="inv-role" className="text-gray-300">Role</Label>
          <NativeSelect id="inv-role" value={form.role} onChange={(e) => set('role', e.target.value)} disabled={roles === null || noRoles}>
            {roles === null && <option value="">Loading…</option>}
            {noRoles && <option value="">No roles available</option>}
            {roles?.map((r) => <option key={r} value={r}>{roleName(r)}</option>)}
          </NativeSelect>
          {noRoles && <p className="text-xs text-amber-300">You cannot appoint anyone at this club.</p>}
        </div>
      </div>

      <fieldset className="space-y-3">
        <legend className="text-sm text-gray-300">Access</legend>
        <div className="flex flex-wrap gap-4 text-sm text-gray-300">
          <label className="flex items-center gap-2"><input type="radio" name="inv-access" checked={!form.temporary} onChange={() => set('temporary', false)} /> Ongoing until removed</label>
          <label className="flex items-center gap-2"><input type="radio" name="inv-access" checked={form.temporary} onChange={() => set('temporary', true)} /> Temporary</label>
        </div>
        {form.temporary && (
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="inv-start" className="text-gray-300">Starts</Label>
              <Input id="inv-start" type="datetime-local" value={form.start} onChange={(e) => set('start', e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="inv-end" className="text-gray-300">Ends</Label>
              <Input id="inv-end" type="datetime-local" value={form.end} onChange={(e) => set('end', e.target.value)} />
            </div>
            <p className="text-xs text-gray-500 sm:col-span-2">Their access stops on its own at the end time. Times are in your device's time zone.</p>
          </div>
        )}
      </fieldset>

      <div className="space-y-2">
        <Label htmlFor="inv-shift" className="text-gray-300">Shift <span className="text-gray-500">(optional)</span></Label>
        <NativeSelect id="inv-shift" value={form.shiftId} onChange={(e) => set('shiftId', e.target.value)}>
          <option value="">No shift</option>
          {shifts.map((s) => <option key={s.shiftId} value={s.shiftId}>{s.name} ({describeAccess(s.startsAt, s.endsAt)})</option>)}
        </NativeSelect>
        {!newShift ? (
          <button type="button" className="text-xs text-primary hover:underline" onClick={() => setNewShift({ name: '', start: '', end: '' })}>Create a new shift</button>
        ) : (
          <div className="space-y-3 rounded-lg border border-gray-800 bg-black/40 p-3">
            <Input aria-label="Shift name" placeholder="Shift name, for example Friday doors" value={newShift.name} onChange={(e) => setNewShift({ ...newShift, name: e.target.value })} maxLength={80} />
            <div className="grid gap-3 sm:grid-cols-2">
              <Input aria-label="Shift starts" type="datetime-local" value={newShift.start} onChange={(e) => setNewShift({ ...newShift, start: e.target.value })} />
              <Input aria-label="Shift ends" type="datetime-local" value={newShift.end} onChange={(e) => setNewShift({ ...newShift, end: e.target.value })} />
            </div>
            <div className="flex gap-2">
              <Button type="button" size="sm" onClick={() => void addShift()} className="bg-gradient-orange font-bold text-black hover:opacity-90">Add shift</Button>
              <Button type="button" size="sm" variant="ghost" onClick={() => setNewShift(null)} className="text-gray-400">Cancel</Button>
            </div>
          </div>
        )}
      </div>

      <div className="flex gap-3">
        <Button type="submit" disabled={busy || roles === null || noRoles} className="bg-gradient-orange font-bold text-black hover:opacity-90">
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Send invitation'}
        </Button>
        <Button type="button" variant="ghost" onClick={onClose} disabled={busy} className="text-gray-400 hover:bg-white/5 hover:text-white">Cancel</Button>
      </div>
    </form>
  );
};

export default InviteForm;
