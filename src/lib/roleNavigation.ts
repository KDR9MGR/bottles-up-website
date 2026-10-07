// Which sections each role sees (client brief, sections 4 and 5). A role gets only its own
// screens; this list decides what the workspace shell shows and where a role lands. It does
// NOT grant access: the database decides that (RLS and the permission functions). Hiding a
// menu item is never the security boundary.

export type WorkspaceRole = 'owner' | 'manager' | 'organizer' | 'server' | 'door' | 'security' | 'verifier';

export const WORKSPACE_ROLES: readonly WorkspaceRole[] = [
  'owner', 'manager', 'organizer', 'server', 'door', 'security', 'verifier',
];

export interface NavSection {
  id: string;
  label: string;
}

export const ROLE_LABEL: Record<WorkspaceRole, string> = {
  owner: 'Venue Owner',
  manager: 'Manager',
  organizer: 'Event Organizer',
  server: 'Bottle Server',
  door: 'Door Staff',
  security: 'Security',
  verifier: 'Payment Verifier',
};

// Owner: the desktop sidebar from section 4. Everyone else: the primary navigation from
// section 5 (compact on a phone, the same entries in the sidebar on desktop).
const SECTIONS: Record<WorkspaceRole, NavSection[]> = {
  owner: [
    { id: 'overview', label: 'Overview' },
    { id: 'venues', label: 'My Venues' },
    { id: 'tonight', label: 'Tonight' },
    { id: 'events', label: 'Events & Organizers' },
    { id: 'tables', label: 'Tables & Bookings' },
    { id: 'bottle-orders', label: 'Bottle Orders' },
    { id: 'payments', label: 'Payments' },
    { id: 'discounts', label: 'Discounts' },
    { id: 'complimentary', label: 'Complimentary' },
    { id: 'vip', label: 'VIP Guests' },
    { id: 'inventory', label: 'Inventory' },
    { id: 'team', label: 'Team' },
    { id: 'chat', label: 'Chat' },
    { id: 'booking-link', label: 'Booking Link' },
    { id: 'reports', label: 'Reports' },
    { id: 'settings', label: 'Settings' },
  ],
  manager: [
    { id: 'tonight', label: 'Tonight' },
    { id: 'floor', label: 'Floor' },
    { id: 'orders', label: 'Orders' },
    { id: 'team', label: 'Team' },
    { id: 'more', label: 'More' },
  ],
  organizer: [
    { id: 'home', label: 'Home' },
    { id: 'events', label: 'Events' },
    { id: 'guests', label: 'Guests' },
    { id: 'chat', label: 'Chat' },
    { id: 'more', label: 'More' },
  ],
  server: [
    { id: 'tables', label: 'My Tables' },
    { id: 'orders', label: 'Orders' },
    { id: 'scan', label: 'Scan' },
    { id: 'requests', label: 'Requests' },
    { id: 'chat', label: 'Chat' },
  ],
  door: [
    { id: 'scan', label: 'Scan' },
    { id: 'guests', label: 'Guests' },
    { id: 'door-sale', label: 'Door Sale' },
    { id: 'chat', label: 'Chat' },
  ],
  security: [
    { id: 'alerts', label: 'Alerts' },
    { id: 'tasks', label: 'Tasks' },
    { id: 'chat', label: 'Chat' },
    { id: 'incidents', label: 'Incidents' },
  ],
  verifier: [
    { id: 'review', label: 'Review' },
    { id: 'cash', label: 'Cash' },
    { id: 'exceptions', label: 'Exceptions' },
    { id: 'summary', label: 'Summary' },
  ],
};

export function isWorkspaceRole(value: unknown): value is WorkspaceRole {
  return typeof value === 'string' && (WORKSPACE_ROLES as readonly string[]).includes(value);
}

export function sectionsFor(role: WorkspaceRole): NavSection[] {
  return SECTIONS[role];
}

/** Where a role lands inside its workspace: the first entry of its navigation. */
export function landingSection(role: WorkspaceRole): string {
  return SECTIONS[role][0].id;
}

export function hasSection(role: WorkspaceRole, section: string): boolean {
  return SECTIONS[role].some((s) => s.id === section);
}

export function sectionLabel(role: WorkspaceRole, section: string): string | null {
  return SECTIONS[role].find((s) => s.id === section)?.label ?? null;
}

/** The URL of a workspace section: `/w/<membership>/<section>`. */
export function workspacePath(membershipId: string, section: string): string {
  return `/w/${membershipId}/${section}`;
}
