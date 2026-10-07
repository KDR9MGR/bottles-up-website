import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import BookingTimesEditor from './BookingTimesEditor';
import BottlesEditor from './BottlesEditor';
import FloorsEditor from './FloorsEditor';
import TableTypesEditor from './TableTypesEditor';
import VenueSetupEditors from './VenueSetupEditors';

// Effects do not run in a server render, so these show each editor's first paint: they prove every editor builds and
// renders without a person or data, and that the owner is offered all four areas of setup. What the forms accept is
// pinned down in venueSetupForms.test.ts; what the database allows in tests/db/tests/080_venue_setup.sql.
const noop = () => undefined;

describe('venue setup editors, first paint', () => {
  it('offers the four areas, in the order of the setup checklist, and opens on the first', () => {
    const html = renderToString(<VenueSetupEditors orgId="o1" venueId="v1" onChanged={noop} />);
    const order = ['Floor plans', 'Tables', 'Bottle menu', 'Booking times'].map((label) => html.indexOf(`>${label}<`));
    expect(order.every((i) => i > -1)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
    expect(html).toContain('Loading floors');
  });

  it.each([
    ['floors', <FloorsEditor key="f" orgId="o1" venueId="v1" onChanged={noop} />, 'Loading floors'],
    ['tables', <TableTypesEditor key="t" orgId="o1" venueId="v1" onChanged={noop} />, 'Loading tables'],
    ['bottles', <BottlesEditor key="b" orgId="o1" venueId="v1" onChanged={noop} />, 'Loading the bottle menu'],
    ['arrival times', <BookingTimesEditor key="a" venueId="v1" onChanged={noop} />, 'Loading arrival times'],
  ])('%s shows that it is loading, not an empty list that looks like "nothing set up"', (_name, element, text) => {
    const html = renderToString(element);
    expect(html).toContain(text);
    expect(html).not.toMatch(/No (floors|tables|bottles) yet/);
  });
});
