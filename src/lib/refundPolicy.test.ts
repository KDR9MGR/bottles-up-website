import { beforeEach, describe, expect, it, vi } from 'vitest';

const rpc = vi.fn();
vi.mock('@/lib/supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));
import { RefundRequestError, fetchPublicRefundPolicy, requestRefund } from './refundPolicy';

beforeEach(() => { vi.clearAllMocks(); });

describe('fetchPublicRefundPolicy: what a guest reads before paying', () => {
  it('returns the sentences and whether the venue set a policy', async () => {
    rpc.mockResolvedValue({ data: [{ has_policy: true, lines: ['Cancel at least 2 days before you arrive: the whole deposit is refunded.', 'Later than that: no refund.'] }], error: null });
    expect(await fetchPublicRefundPolicy('v1')).toEqual({ hasPolicy: true, lines: ['Cancel at least 2 days before you arrive: the whole deposit is refunded.', 'Later than that: no refund.'] });
    expect(rpc).toHaveBeenCalledWith('public_venue_refund_policy', { p_venue: 'v1' });
  });

  it('says so when the venue has not set one (the venue decides)', async () => {
    rpc.mockResolvedValue({ data: [{ has_policy: false, lines: ['This venue has not set a refund policy: refunds are decided by the venue.'] }], error: null });
    expect((await fetchPublicRefundPolicy('v1'))?.hasPolicy).toBe(false);
  });

  it('shows nothing, and breaks nothing, when it cannot be read', async () => {
    rpc.mockResolvedValue({ data: null, error: { code: 'PGRST202', message: 'Could not find the function' } });
    expect(await fetchPublicRefundPolicy('v1')).toBeNull();
    rpc.mockRejectedValue(new Error('network'));
    expect(await fetchPublicRefundPolicy('v1')).toBeNull();
    rpc.mockResolvedValue({ data: [], error: null });
    expect(await fetchPublicRefundPolicy('v1')).toBeNull();
    rpc.mockResolvedValue({ data: [{ has_policy: true, lines: [] }], error: null });
    expect(await fetchPublicRefundPolicy('v1')).toBeNull();
  });

  it('ignores anything in the lines that is not text', async () => {
    rpc.mockResolvedValue({ data: [{ has_policy: true, lines: ['One.', 3, null, '  ', 'Two.'] }], error: null });
    expect((await fetchPublicRefundPolicy('v1'))?.lines).toEqual(['One.', 'Two.']);
  });
});

describe('requestRefund: a guest asks for their money back', () => {
  it('sends the code, the e-mail and the reason, tidied, and shows the venue\'s sentence', async () => {
    rpc.mockResolvedValue({ data: 'Your request has been sent to the venue. They will look at it and update you.', error: null });
    expect(await requestRefund(' bt-abc ', ' me@x.example ', ' I am ill ')).toBe('Your request has been sent to the venue. They will look at it and update you.');
    expect(rpc).toHaveBeenCalledWith('guest_request_refund', { p_code: 'bt-abc', p_email: 'me@x.example', p_reason: 'I am ill' });
  });

  it('shows the database\'s own sentence for a refusal', async () => {
    rpc.mockResolvedValue({ data: null, error: { code: 'P0001', message: 'we could not find a booking with that code and e-mail' } });
    await expect(requestRefund('x', 'y', 'z z z')).rejects.toThrow('we could not find a booking with that code and e-mail');
    await expect(requestRefund('x', 'y', 'z z z')).rejects.toBeInstanceOf(RefundRequestError);
  });

  it('never shows anything technical for another failure', async () => {
    rpc.mockResolvedValue({ data: null, error: { code: '57014', message: 'canceling statement due to statement timeout' } });
    await expect(requestRefund('x', 'y', 'z z z')).rejects.toThrow('Your request could not be sent just now. Try again in a moment.');
  });
});
