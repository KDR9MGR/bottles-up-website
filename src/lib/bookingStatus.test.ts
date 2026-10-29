import { describe, expect, it } from 'vitest';
import { readBookingStatus } from './bookingStatus';

const ticket = { ticketCode: 'TKT-1' };
const booking = { confirmationCode: 'BT-1' };

describe('readBookingStatus: what one answer means for the booking-success page', () => {
  it('a paid ticket is shown', () => {
    expect(readBookingStatus({ status: 'paid', ticket }, 0)).toEqual({ kind: 'ticket', ticket });
  });

  it('a paid table booking is shown', () => {
    expect(readBookingStatus({ status: 'paid', booking }, 0)).toEqual({ kind: 'booking', booking });
  });

  it('a held booking is NOT shown as a confirmation, even if the answer also carried a booking', () => {
    expect(readBookingStatus({ status: 'held' }, 0)).toEqual({ kind: 'held' });
    expect(readBookingStatus({ status: 'held', booking }, 0)).toEqual({ kind: 'held' });
  });

  it('"paid" with nothing to show is not a confirmation: ask again', () => {
    expect(readBookingStatus({ status: 'paid' }, 0)).toEqual({ kind: 'retry' });
  });

  it('not paid yet, no answer, or an unknown answer: ask again', () => {
    expect(readBookingStatus({ status: 'pending' }, 0)).toEqual({ kind: 'retry' });
    expect(readBookingStatus(null, 3)).toEqual({ kind: 'retry' });
    expect(readBookingStatus(undefined, 3)).toEqual({ kind: 'retry' });
    expect(readBookingStatus({ status: 'not_found' }, 3)).toEqual({ kind: 'retry' });
  });

  it('asks up to ten times in all, then gives up', () => {
    expect(readBookingStatus({ status: 'pending' }, 8)).toEqual({ kind: 'retry' });
    expect(readBookingStatus({ status: 'pending' }, 9)).toEqual({ kind: 'give_up' });
    expect(readBookingStatus({ status: 'pending' }, 2, 3)).toEqual({ kind: 'give_up' });
  });

  it('a held answer is shown even on the last try', () => {
    expect(readBookingStatus({ status: 'held' }, 9)).toEqual({ kind: 'held' });
  });
});
