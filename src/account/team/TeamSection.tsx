import { useCallback, useEffect, useState } from 'react';
import { Loader2, UserPlus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter,
  AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { useToast } from '@/hooks/use-toast';
import {
  AccountError, cancelInvitation, emailInvitation, fetchOrgVenues, listTeam, listTeamInvitations, removeMember, sendNewLink,
} from '@/lib/account';
import type { Workspace } from '@/lib/accountRouting';
import { ROLE_LABEL, isWorkspaceRole } from '@/lib/roleNavigation';
import {
  canCancelInvitation, canRemoveMember, canSendNewLink, describeAccess, describeScope, displayName, INVITATION_STATE, invitationLink,
  MEMBER_STATE, splitTeam, type TeamInvitation, type TeamMember, type Tone,
} from '@/lib/team';
import InviteForm from './InviteForm';
import InviteResult, { type IssuedInvite } from './InviteResult';

const TONE: Record<Tone, string> = {
  success: 'border-green-500/40 bg-green-500/10 text-green-300',
  info: 'border-blue-500/40 bg-blue-500/10 text-blue-300',
  warning: 'border-amber-500/40 bg-amber-500/10 text-amber-300',
  neutral: 'border-gray-700 bg-gray-800 text-gray-300',
};

const Badge = ({ tone, children }: { tone: Tone; children: React.ReactNode }) => (
  <span className={`inline-flex shrink-0 items-center rounded-full border px-2.5 py-0.5 text-xs font-medium ${TONE[tone]}`}>{children}</span>
);

const roleName = (role: string) => (isWorkspaceRole(role) ? ROLE_LABEL[role] : role);

type Confirm = { kind: 'remove'; member: TeamMember } | { kind: 'cancel'; invitation: TeamInvitation };

/**
 * Team: who works for the business, who has been invited and in what state, and the actions to invite, send a new
 * link, cancel, or remove access. What each person sees, and what they may do, is decided by the database: an owner
 * sees everyone, a manager only the staff of their own club.
 */
const TeamSection = ({ workspace }: { workspace: Workspace }) => {
  const { toast } = useToast();
  const orgId = workspace.orgId;
  const [venues, setVenues] = useState<{ venueId: string; name: string }[] | null>(null);
  const [members, setMembers] = useState<TeamMember[] | null>(null);
  const [invitations, setInvitations] = useState<TeamInvitation[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [inviting, setInviting] = useState(false);
  const [issued, setIssued] = useState<IssuedInvite | null>(null);
  const [confirm, setConfirm] = useState<Confirm | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [v, m, i] = await Promise.all([fetchOrgVenues(orgId), listTeam(orgId), listTeamInvitations(orgId)]);
      setVenues(v);
      setMembers(m);
      setInvitations(i);
      setError(null);
    } catch (err) {
      setError(err instanceof AccountError ? err.message : 'Could not load your team.');
    }
  }, [orgId]);

  useEffect(() => { void load(); }, [load]);

  const fail = (title: string, err: unknown) =>
    toast({ title, description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });

  const newLink = async (inv: TeamInvitation) => {
    setBusyId(inv.invitationId);
    try {
      const { token } = await sendNewLink(inv.invitationId);
      const outcome = await emailInvitation(inv.invitationId, token);
      setIssued({ email: inv.email, roleLabel: roleName(inv.role), businessName: workspace.orgName, link: invitationLink(window.location.origin, token), outcome });
      setInviting(false);
      await load();
    } catch (err) {
      fail('Could not create a new link', err);
    } finally {
      setBusyId(null);
    }
  };

  const runConfirmed = async () => {
    if (!confirm) return;
    const action = confirm;
    setConfirm(null);
    try {
      if (action.kind === 'remove') {
        await removeMember(action.member.membershipId);
        toast({ title: 'Access removed' });
      } else {
        await cancelInvitation(action.invitation.invitationId);
        toast({ title: 'Invitation cancelled' });
      }
      await load();
    } catch (err) {
      fail(action.kind === 'remove' ? 'Could not remove access' : 'Could not cancel the invitation', err);
    }
  };

  if (error) return <p role="alert" className="rounded-lg border border-red-500/40 bg-red-500/10 p-4 text-sm text-red-200">{error}</p>;
  if (members === null || invitations === null || venues === null) return <p className="text-sm text-gray-500" role="status">Loading your team…</p>;

  const { current, history } = splitTeam(members);
  const waiting = invitations.filter((i) => i.state === 'pending' || i.state === 'expired');
  const earlier = invitations.filter((i) => i.state === 'accepted' || i.state === 'revoked');

  return (
    <div>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-xl text-sm text-gray-400">Appoint managers and staff, give temporary access for a night or a shift, and remove access at any time.</p>
        <Button
          onClick={() => { setInviting(true); setIssued(null); }}
          disabled={inviting || venues.length === 0}
          className="bg-gradient-orange font-bold text-black hover:opacity-90"
        >
          <UserPlus className="mr-2 h-4 w-4" /> Invite someone
        </Button>
      </div>
      {venues.length === 0 && <p className="mb-6 text-sm text-amber-300">Add a venue first. People are invited to work at a club.</p>}

      {issued && <InviteResult invite={issued} onClose={() => setIssued(null)} />}
      {inviting && (
        <InviteForm
          orgId={orgId}
          businessName={workspace.orgName}
          venues={venues}
          onIssued={(invite) => { setIssued(invite); setInviting(false); void load(); }}
          onClose={() => setInviting(false)}
        />
      )}

      <section aria-labelledby="team-waiting" className="mb-8">
        <h2 id="team-waiting" className="mb-3 text-sm font-medium uppercase tracking-wide text-gray-500">Invitations waiting ({waiting.length})</h2>
        {waiting.length === 0 && <p className="text-sm text-gray-500">No invitations are waiting.</p>}
        <ul className="space-y-2">
          {waiting.map((inv) => (
            <li key={inv.invitationId} className="rounded-xl border border-gray-800 bg-gray-900/50 p-4">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-white">{inv.email}</p>
                  <p className="text-xs text-gray-400">{roleName(inv.role)} · {describeScope(inv.venueName, inv.eventTitle, inv.shiftName)}</p>
                </div>
                <Badge tone={INVITATION_STATE[inv.state].tone}>{INVITATION_STATE[inv.state].label}</Badge>
              </div>
              <p className="mt-2 text-xs text-gray-500">
                Access: {describeAccess(inv.accessStartAt, inv.accessEndAt)} · {inv.state === 'expired' ? 'Link expired' : `Link works until ${new Date(inv.expiresAt).toLocaleDateString()}`}
                {inv.emailsSent > 0 && ` · Emailed ${inv.emailsSent} time${inv.emailsSent === 1 ? '' : 's'}`}
              </p>
              <div className="mt-3 flex flex-wrap gap-2">
                {canSendNewLink(inv.state) && (
                  <Button size="sm" variant="outline" disabled={busyId === inv.invitationId} onClick={() => void newLink(inv)} className="border-gray-700 text-white hover:bg-gray-900">
                    {busyId === inv.invitationId ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Send a new link'}
                  </Button>
                )}
                {canCancelInvitation(inv.state) && (
                  <Button size="sm" variant="ghost" onClick={() => setConfirm({ kind: 'cancel', invitation: inv })} className="text-gray-400 hover:bg-white/5 hover:text-white">Cancel invitation</Button>
                )}
              </div>
            </li>
          ))}
        </ul>
      </section>

      <section aria-labelledby="team-members" className="mb-8">
        <h2 id="team-members" className="mb-3 text-sm font-medium uppercase tracking-wide text-gray-500">Team ({current.length})</h2>
        {current.length === 0 && <p className="text-sm text-gray-500">Nobody is on the team yet.</p>}
        <ul className="space-y-2">
          {current.map((m) => (
            <li key={m.membershipId} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-gray-800 bg-gray-900/50 p-4">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium text-white">{displayName(m.name, m.email)}</p>
                {m.name && m.email && <p className="truncate text-xs text-gray-500">{m.email}</p>}
                <p className="text-xs text-gray-400">{roleName(m.role)} · {describeScope(m.venueName, m.eventTitle, m.shiftName)}</p>
                <p className="text-xs text-gray-500">Access: {describeAccess(m.accessStartAt, m.accessEndAt)}</p>
              </div>
              <div className="flex items-center gap-3">
                <Badge tone={MEMBER_STATE[m.state].tone}>{MEMBER_STATE[m.state].label}</Badge>
                {canRemoveMember(m.role, m.state) && (
                  <Button size="sm" variant="ghost" onClick={() => setConfirm({ kind: 'remove', member: m })} className="text-gray-400 hover:bg-white/5 hover:text-red-300">Remove</Button>
                )}
              </div>
            </li>
          ))}
        </ul>
      </section>

      {(history.length > 0 || earlier.length > 0) && (
        <details className="rounded-xl border border-gray-800 p-4">
          <summary className="cursor-pointer text-sm text-gray-400">History ({history.length + earlier.length})</summary>
          <ul className="mt-3 space-y-2 text-sm">
            {history.map((m) => (
              <li key={m.membershipId} className="flex flex-wrap items-center justify-between gap-2 text-gray-400">
                <span>{displayName(m.name, m.email)} · {roleName(m.role)} · {describeScope(m.venueName, m.eventTitle, m.shiftName)}</span>
                <Badge tone={MEMBER_STATE[m.state].tone}>{MEMBER_STATE[m.state].label}</Badge>
              </li>
            ))}
            {earlier.map((i) => (
              <li key={i.invitationId} className="flex flex-wrap items-center justify-between gap-2 text-gray-400">
                <span>Invitation to {i.email} · {roleName(i.role)}</span>
                <Badge tone={INVITATION_STATE[i.state].tone}>{INVITATION_STATE[i.state].label}</Badge>
              </li>
            ))}
          </ul>
        </details>
      )}

      <AlertDialog open={confirm !== null} onOpenChange={(open) => { if (!open) setConfirm(null); }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {confirm?.kind === 'remove' ? `Remove ${displayName(confirm.member.name, confirm.member.email)}?` : `Cancel the invitation to ${confirm?.kind === 'cancel' ? confirm.invitation.email : ''}?`}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {confirm?.kind === 'remove'
                ? 'They lose access immediately. This is recorded, and you can invite them again later.'
                : 'The link stops working. You can invite them again later.'}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Keep</AlertDialogCancel>
            <AlertDialogAction onClick={() => void runConfirmed()}>{confirm?.kind === 'remove' ? 'Remove access' : 'Cancel invitation'}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

export default TeamSection;
