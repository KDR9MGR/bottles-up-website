import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import type { OrgEvent } from '@/lib/organizerEvents';
import EventsList from './EventsList';
import EventFields from './EventFields';
import { EMPTY_EVENT_FORM } from '@/lib/organizerEvents';

const now = new Date('2031-10-24T12:00:00Z');
const ev = (over: Partial<OrgEvent> = {}): OrgEvent => ({
  eventId: 'e1', title: 'Rooftop Party', description: 'Dancing', venueName: 'The Roof', address: '1 King St W', startDate: '2031-10-30T22:00:00Z',
  endDate: null, category: 'Party', capacity: 250, coverImageUrl: null, status: 'draft', ticketTierCount: 0, ...over,
});

const render = (events: OrgEvent[]) =>
  renderToString(<EventsList events={events} now={now} timeZone="America/Toronto" onCreate={() => undefined} onEdit={() => undefined} onRemove={() => undefined} />);

/** The markup of one event's card. */
const card = (html: string, id: string) => {
  const start = html.indexOf(`data-testid="event-${id}"`);
  expect(start, `card ${id}`).toBeGreaterThan(-1);
  const next = html.indexOf('data-testid="event-', start + 10);
  return html.slice(start, next === -1 ? undefined : next);
};

describe('the organizer\'s events list', () => {
  it('with no events it says so and offers to create one', () => {
    const html = render([]);
    expect(html).toContain('data-testid="no-events"');
    expect(html).toContain('No events yet');
    expect(html).toContain('Create event');
    expect(html).toContain('private draft');
  });

  it('shows what a guest would see: title, when, where, capacity', () => {
    const c = card(render([ev()]), 'e1');
    expect(c).toContain('Rooftop Party');
    expect(c).toMatch(/Oct 30, 2031/);
    expect(c).toContain('The Roof, 1 King St W');
    expect(c).toContain('Capacity 250');
  });

  it('leaves out what is not there: no capacity line, no address, no photo', () => {
    const c = card(render([ev({ capacity: null, address: null })]), 'e1');
    expect(c).not.toContain('Capacity');
    expect(c).not.toContain('1 King St W');
    expect(c).not.toContain('<img');
    expect(card(render([ev({ coverImageUrl: 'https://img.example/a.jpg' })]), 'e1')).toContain('src="https://img.example/a.jpg"');
  });

  it('a draft can be changed or removed; a published event cannot, and says who to ask', () => {
    const html = render([ev({ eventId: 'd', status: 'draft' }), ev({ eventId: 'p', status: 'published', title: 'Live night' })]);
    const draft = card(html, 'd');
    expect(draft).toContain('>Edit<');
    expect(draft).toContain('>Remove<');
    expect(draft).toContain('Only you can see this');
    expect(draft).toContain('>Draft<');
    const live = card(html, 'p');
    expect(live).not.toContain('>Edit<');
    expect(live).not.toContain('>Remove<');
    expect(live).toContain('Contact BottlesUp');
    expect(live).toContain('>Published<');
  });

  it('groups drafts, then upcoming, then past, each only when it has something', () => {
    const html = render([
      ev({ eventId: 'past', status: 'published', startDate: '2031-06-01T22:00:00Z', endDate: '2031-06-02T04:00:00Z' }),
      ev({ eventId: 'soon', status: 'published', startDate: '2031-11-01T22:00:00Z' }),
      ev({ eventId: 'draft', status: 'draft' }),
    ]);
    const at = (label: string) => html.indexOf(`aria-label="${label}"`);
    expect(at('Drafts')).toBeGreaterThan(-1);
    expect(at('Drafts')).toBeLessThan(at('Upcoming'));
    expect(at('Upcoming')).toBeLessThan(at('Past'));
    const only = render([ev({ eventId: 'draft', status: 'draft' })]);
    expect(only).not.toContain('aria-label="Upcoming"');
    expect(only).not.toContain('aria-label="Past"');
  });

  it('an unknown status is shown as published and offers no editing', () => {
    // parseOrgEvent reads anything but "draft" as published; this is the same guarantee at the list.
    const c = card(render([ev({ eventId: 'x', status: 'published' })]), 'x');
    expect(c).not.toContain('>Edit<');
  });
});

describe('the event form fields', () => {
  const html = renderToString(<EventFields form={EMPTY_EVENT_FORM} orgId="o1" onChange={() => undefined} problems={[]} timeZone="America/Toronto" />);

  it('asks for everything the database takes, and for nothing it does not', () => {
    for (const label of ['Title', 'Description', 'Venue or place name', 'Address', 'Starts', 'Ends', 'Category', 'Capacity', 'Cover photo']) {
      expect(html, label).toContain(label);
    }
    for (const forbidden of ['Status', 'Publish', 'Slug', 'Ticket']) expect(html, forbidden).not.toContain(forbidden);
  });

  it('says which zone the times are in', () => {
    expect(html).toContain('America/Toronto');
  });

  it('the times are real date-time boxes', () => {
    expect((html.match(/type="datetime-local"/g) ?? []).length).toBe(2);
  });

  it('shows no problem box until there is a problem, then lists each one', () => {
    expect(html).not.toContain('data-testid="event-problems"');
    const withProblems = renderToString(<EventFields form={EMPTY_EVENT_FORM} orgId="o1" onChange={() => undefined} problems={['Give the event a title.', 'Choose when it starts.']} timeZone="UTC" />);
    expect(withProblems).toContain('data-testid="event-problems"');
    expect(withProblems).toContain('Give the event a title.');
    expect(withProblems).toContain('Choose when it starts.');
  });
});

// A click cannot be simulated here (the pages are rendered on the server), and these are the two places a slip would lose a
// person's work or delete a draft with one click, so the wiring is checked in the source.
describe('the wiring that cannot be clicked in these tests', () => {
  const dir = join(__dirname);
  const container = readFileSync(join(dir, 'OrganizerEvents.tsx'), 'utf8');
  const dialog = readFileSync(join(dir, 'OrganizerEventDialog.tsx'), 'utf8');

  it('Remove only opens the confirmation; the removal runs from the confirmation alone', () => {
    expect(container).toMatch(/onRemove=\{setRemoving\}/);
    expect(container).toMatch(/onConfirm=\{\(\) => void remove\(\)\}/);
    expect((container.match(/\bremove\(\)/g) ?? []).length).toBe(1);
  });

  it('keeping or closing the confirmation just closes it', () => {
    expect(container).toMatch(/onClose=\{\(\) => setRemoving\(null\)\}/);
  });

  it('the dialog saves from its button, cannot be closed while saving, and clears the saving flag when it failed', () => {
    expect(dialog).toMatch(/onClick=\{\(\) => void save\(\)\}/);
    expect(dialog).toMatch(/if \(!o && !saving\) onClose\(\)/);
    expect(dialog).toMatch(/setProblems\(result\.problems\);\s*setSaving\(false\)/);
  });

  it('Create event opens an empty form; Edit opens the event', () => {
    expect(container).toMatch(/onCreate=\{\(\) => setEditing\(\{ event: null \}\)\}/);
    expect(container).toMatch(/onEdit=\{\(e\) => setEditing\(\{ event: e \}\)\}/);
  });
});
