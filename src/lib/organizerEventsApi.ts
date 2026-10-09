import { call } from './account';
import { parseOrgEvent, type OrgEvent } from './organizerEvents';

// The organizer's events, over the database functions in 20261013100000_organizer_events.sql. Each call is checked by the database
// against the signed-in person's role in THIS business; nothing here decides who may do what.

export async function listOrgEvents(orgId: string): Promise<OrgEvent[]> {
  const rows = await call<Record<string, unknown>[] | null>('list_org_events', { p_org: orgId });
  return (rows ?? []).map(parseOrgEvent).filter((e): e is OrgEvent => e !== null);
}

/** eventId null adds a draft; otherwise changes that draft. Only the fields in `details` change. */
export async function saveOrgEvent(orgId: string, eventId: string | null, details: Record<string, unknown>): Promise<string> {
  return call<string>('save_org_event', { p_org: orgId, p_event: eventId, p_details: details });
}

export async function removeOrgEvent(orgId: string, eventId: string): Promise<void> {
  await call('remove_org_event', { p_org: orgId, p_event: eventId });
}
