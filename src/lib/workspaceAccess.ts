// Whether a workspace page may be shown to this person, and which section it should show. Pure, so the
// rule that matters most (a revoked or expired assignment never opens an operational screen) is tested
// without a browser. The database remains the real gate; this decides what the page does with its answer.

import type { AccountSnapshot, Workspace } from './accountRouting';
import { hasSection, landingSection, workspacePath } from './roleNavigation';

export type WorkspaceView =
  | { kind: 'signed_out' }
  /** The person does not (or no longer does) hold this workspace. */
  | { kind: 'no_access' }
  /** They hold it, but the address names a section their role does not have: send them to their own landing. */
  | { kind: 'redirect'; to: string }
  | { kind: 'show'; workspace: Workspace; section: string };

export function resolveWorkspaceView(snapshot: AccountSnapshot, membershipId: string, section: string | undefined): WorkspaceView {
  if (!snapshot.signedIn) return { kind: 'signed_out' };
  const workspace = snapshot.workspaces.find((w) => w.membershipId === membershipId);
  if (!workspace) return { kind: 'no_access' };
  if (!section || !hasSection(workspace.role, section)) {
    return { kind: 'redirect', to: workspacePath(workspace.membershipId, landingSection(workspace.role)) };
  }
  return { kind: 'show', workspace, section };
}
