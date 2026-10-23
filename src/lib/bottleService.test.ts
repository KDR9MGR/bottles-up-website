import { describe, expect, it } from 'vitest';
import { BOTTLE_SERVICE_STATUSES, BOTTLE_SERVICE_STATUS_LABELS } from './bottleService';

describe('the order stages the website\'s staff pages offer', () => {
  it('are in the order an order moves, with Accepted straight after a new order', () => {
    expect(BOTTLE_SERVICE_STATUSES).toEqual(['awaiting_prep', 'accepted', 'preparing', 'ready', 'picked_up', 'served']);
  });

  it('every stage has a label, so a screen never shows a blank for one', () => {
    for (const status of BOTTLE_SERVICE_STATUSES) expect(BOTTLE_SERVICE_STATUS_LABELS[status]).toBeTruthy();
    expect(BOTTLE_SERVICE_STATUS_LABELS.accepted).toBe('Accepted');
  });

  it('and the labels cover nothing the list does not', () => {
    expect(Object.keys(BOTTLE_SERVICE_STATUS_LABELS).sort()).toEqual([...BOTTLE_SERVICE_STATUSES].sort());
  });
});
