import { describe, expect, it } from 'vitest';
import {
  hasSection,
  isWorkspaceRole,
  landingSection,
  ROLE_LABEL,
  sectionLabel,
  sectionsFor,
  workspacePath,
  WORKSPACE_ROLES,
} from './roleNavigation';

describe('role navigation (brief, sections 4 and 5)', () => {
  it('the owner sidebar has the sixteen sections of section 4, in order', () => {
    expect(sectionsFor('owner').map((s) => s.label)).toEqual([
      'Overview', 'My Venues', 'Tonight', 'Events & Organizers', 'Tables & Bookings', 'Bottle Orders', 'Payments',
      'Discounts', 'Complimentary', 'VIP Guests', 'Inventory', 'Team', 'Chat', 'Booking Link', 'Reports', 'Settings',
    ]);
  });

  it.each([
    ['manager', ['Tonight', 'Floor', 'Orders', 'Team', 'More']],
    ['organizer', ['Home', 'Events', 'Guests', 'Chat', 'More']],
    ['server', ['My Tables', 'Orders', 'Scan', 'Requests', 'Chat']],
    ['door', ['Scan', 'Guests', 'Door Sale', 'Chat']],
    ['security', ['Alerts', 'Tasks', 'Chat', 'Incidents']],
    ['verifier', ['Review', 'Cash', 'Exceptions', 'Summary']],
  ] as const)('%s sees exactly its section 5 navigation', (role, labels) => {
    expect(sectionsFor(role).map((s) => s.label)).toEqual(labels);
  });

  it('every role has a label and at least one section, and section ids are unique within a role', () => {
    for (const role of WORKSPACE_ROLES) {
      expect(ROLE_LABEL[role].length).toBeGreaterThan(2);
      const ids = sectionsFor(role).map((s) => s.id);
      expect(ids.length).toBeGreaterThan(0);
      expect(new Set(ids).size).toBe(ids.length);
    }
  });

  it('a role lands on the first entry of its own navigation', () => {
    expect(landingSection('owner')).toBe('overview');
    expect(landingSection('door')).toBe('scan');
    expect(landingSection('verifier')).toBe('review');
  });

  it('a role cannot open another role\'s section (no owner screens for staff)', () => {
    expect(hasSection('door', 'payments')).toBe(false);
    expect(hasSection('server', 'reports')).toBe(false);
    expect(hasSection('security', 'team')).toBe(false);
    expect(hasSection('owner', 'payments')).toBe(true);
    expect(sectionLabel('door', 'payments')).toBeNull();
    expect(sectionLabel('door', 'door-sale')).toBe('Door Sale');
  });

  it('recognises the seven roles only', () => {
    expect(WORKSPACE_ROLES).toHaveLength(7);
    expect(isWorkspaceRole('door')).toBe(true);
    expect(isWorkspaceRole('admin')).toBe(false);
    expect(isWorkspaceRole(undefined)).toBe(false);
  });

  it('builds workspace urls', () => {
    expect(workspacePath('abc', 'tables')).toBe('/w/abc/tables');
  });
});
