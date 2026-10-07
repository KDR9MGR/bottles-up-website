import { describe, expect, it } from 'vitest';
import { resolveWorkspaceView } from './workspaceAccess';
import { EMPTY_SNAPSHOT, type AccountSnapshot, type Workspace } from './accountRouting';

const ws = (over: Partial<Workspace> = {}): Workspace => ({
  membershipId: 'm1', orgId: 'o1', orgName: 'Club Co', orgKind: 'venue_owner', role: 'owner',
  venueId: null, venueName: null, eventId: null, eventTitle: null, shiftId: null, shiftName: null, accessEndAt: null, ...over,
});
const snap = (workspaces: Workspace[]): AccountSnapshot => ({ ...EMPTY_SNAPSHOT, signedIn: true, workspaces });

describe('resolveWorkspaceView', () => {
  it('a signed-out visitor gets the sign-in route, never a workspace', () => {
    expect(resolveWorkspaceView(EMPTY_SNAPSHOT, 'm1', 'overview')).toEqual({ kind: 'signed_out' });
  });

  it('shows a workspace the person holds, on a section their role has', () => {
    const v = resolveWorkspaceView(snap([ws()]), 'm1', 'payments');
    expect(v).toMatchObject({ kind: 'show', section: 'payments' });
  });

  it('a workspace the person does not hold shows "no access", even if the id is real for someone else', () => {
    expect(resolveWorkspaceView(snap([ws({ membershipId: 'other' })]), 'm1', 'overview')).toEqual({ kind: 'no_access' });
    expect(resolveWorkspaceView(snap([]), 'm1', 'overview')).toEqual({ kind: 'no_access' });
  });

  it('a revoked or expired assignment (absent from the active list) opens nothing operational', () => {
    // my_workspaces() only returns active, in-window, in-shift memberships; an ended one is simply gone.
    for (const role of ['server', 'door', 'security', 'verifier', 'manager'] as const) {
      expect(resolveWorkspaceView(snap([]), 'm-ended', 'tables')).toEqual({ kind: 'no_access' });
      expect(role).toBeTruthy();
    }
  });

  it('sends a role to its own landing when the address names a section it does not have', () => {
    expect(resolveWorkspaceView(snap([ws({ role: 'door' })]), 'm1', 'payments')).toEqual({ kind: 'redirect', to: '/w/m1/scan' });
    expect(resolveWorkspaceView(snap([ws({ role: 'server' })]), 'm1', 'reports')).toEqual({ kind: 'redirect', to: '/w/m1/tables' });
    expect(resolveWorkspaceView(snap([ws({ role: 'owner' })]), 'm1', 'nonsense')).toEqual({ kind: 'redirect', to: '/w/m1/overview' });
  });

  it('a missing section also lands on the role\'s own first section', () => {
    expect(resolveWorkspaceView(snap([ws({ role: 'verifier' })]), 'm1', undefined)).toEqual({ kind: 'redirect', to: '/w/m1/review' });
  });

  it('one person holding two workspaces gets each one only on its own id', () => {
    const s = snap([ws({ membershipId: 'a', role: 'owner' }), ws({ membershipId: 'b', role: 'door' })]);
    expect(resolveWorkspaceView(s, 'a', 'payments').kind).toBe('show');
    expect(resolveWorkspaceView(s, 'b', 'payments')).toEqual({ kind: 'redirect', to: '/w/b/scan' });
  });
});
