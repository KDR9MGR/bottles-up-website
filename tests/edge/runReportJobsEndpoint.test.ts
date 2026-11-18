import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
vi.mock('../../supabase/functions/_shared/reportEmailSender.ts', () => ({
  sendReportEmail: vi.fn(async () => ({ sent: true })),
}));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendReportEmail } from '../../supabase/functions/_shared/reportEmailSender.ts';

// run-report-jobs: the scheduled function. Only a caller holding the project's SERVICE ROLE key may run it; it takes no input, and what it sends is decided by the database.

const KEY = 'service-role-key-0123456789';
let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let rpc: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/run-report-jobs/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_SERVICE_ROLE_KEY: KEY, RESEND_API_KEY: 're_test' };
  rpc = vi.fn(async (name: string) => (name === 'report_job_claim' ? { data: [], error: null } : { data: null, error: null }));
  (createClient as any).mockReturnValue({ rpc });
});

const post = (headers: Record<string, string> = { Authorization: `Bearer ${KEY}` }, method = 'POST') => handler(new Request('https://fn.test/run-report-jobs', { method, headers }));

describe('run-report-jobs', () => {
  it('only accepts POST', async () => {
    expect((await post({ Authorization: `Bearer ${KEY}` }, 'GET')).status).toBe(405);
  });

  it('refuses a caller with no key, a wrong key, a key of another length and a malformed header, before touching the database', async () => {
    for (const headers of [{}, { Authorization: 'Bearer wrong-key-0123456789012345' }, { Authorization: 'Bearer short' }, { Authorization: KEY }, { Authorization: `Basic ${KEY}` }, { Authorization: `Bearer ${KEY} extra` }]) {
      const res = await post(headers as Record<string, string>);
      expect(res.status).toBe(401);
      expect(await res.json()).toEqual({ error: 'Unauthorized' });
    }
    expect(createClient).not.toHaveBeenCalled();
    expect(rpc).not.toHaveBeenCalled();
  });

  it('refuses everyone when the function has no service key of its own', async () => {
    env.SUPABASE_SERVICE_ROLE_KEY = undefined;
    expect((await post({ Authorization: 'Bearer anything' })).status).toBe(401);
  });

  it('with the key: takes the due jobs as the service role and says how many it handled', async () => {
    const res = await post();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ claimed: 0, sent: 0, skipped: 0, failed: 0, retried: 0 });
    expect(createClient).toHaveBeenCalledWith('http://db.test', KEY);
    expect(rpc).toHaveBeenCalledWith('report_job_claim', { p_limit: 3 });
  });

  it('sends a queued report with the provider, and is not told anything by the request', async () => {
    const data = {
      kind: 'venue_night', time_zone: 'America/Toronto', ref: '2026-11-14',
      report: { view: 'full', final: true, venue_name: 'Club A', business_night: '2026-11-14', closed_by_name: 'Mia', bookings: { count: 1 } }, sales: null,
    };
    rpc = vi.fn(async (name: string) => {
      if (name === 'report_job_claim') return { data: [{ job_id: 'j1', kind: 'venue_night', org_id: 'o1', venue_id: 'v1', event_id: null, report_ref: '2026-11-14', attempts: 1 }], error: null };
      if (name === 'report_job_data') return { data, error: null };
      if (name === 'report_job_begin') return { data: [{ delivery_id: 'd1', batch_id: 'b1', email: 'a@club.example', org_name: 'Club Co', venue_name: 'Club A', event_title: null }], error: null };
      if (name === 'report_job_finish') return { data: 'sent', error: null };
      return { data: 1, error: null };
    });
    (createClient as any).mockReturnValue({ rpc });
    const res = await handler(new Request('https://fn.test/run-report-jobs', { method: 'POST', headers: { Authorization: `Bearer ${KEY}` }, body: JSON.stringify({ to: 'stranger@evil.example', kind: 'owner_combined' }) }));
    expect(await res.json()).toEqual({ claimed: 1, sent: 1, skipped: 0, failed: 0, retried: 0 });
    expect((sendReportEmail as any).mock.calls).toHaveLength(1);
    expect((sendReportEmail as any).mock.calls[0][0]).toBe('a@club.example');
    expect(rpc.mock.calls.some((c) => JSON.stringify(c).includes('stranger@evil.example'))).toBe(false);
  });

  it('waits (does not write a half-made log) when the e-mail provider key is not set', async () => {
    env.RESEND_API_KEY = undefined;
    rpc = vi.fn(async (name: string) => {
      if (name === 'report_job_claim') return { data: [{ job_id: 'j1', kind: 'venue_night', org_id: 'o1', venue_id: 'v1', event_id: null, report_ref: '2026-11-14', attempts: 1 }], error: null };
      if (name === 'report_job_data') return { data: { kind: 'venue_night', report: { business_night: '2026-11-14', final: true } }, error: null };
      if (name === 'report_job_finish') return { data: 'pending', error: null };
      return { data: null, error: null };
    });
    (createClient as any).mockReturnValue({ rpc });
    const res = await post();
    expect(await res.json()).toMatchObject({ claimed: 1, retried: 1, sent: 0 });
    expect(rpc.mock.calls.map((c) => c[0])).not.toContain('report_job_begin');
    expect(rpc.mock.calls.find((c) => c[0] === 'report_job_finish')![1]).toEqual({ p_job: 'j1', p_outcome: 'retry', p_error: 'The e-mail provider is not configured.' });
  });

  it('a failure is a plain 500 that says nothing about why', async () => {
    rpc = vi.fn(async () => ({ data: null, error: { message: 'secret detail' } }));
    (createClient as any).mockReturnValue({ rpc });
    const res = await post();
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'Internal server error' });
    expect(JSON.stringify(await Promise.resolve({}))).not.toContain('secret');
  });
});
