import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
vi.mock('../../supabase/functions/_shared/reportEmailSender.ts', () => ({
  sendReportEmail: vi.fn(async () => ({ sent: true })),
}));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendReportEmail } from '../../supabase/functions/_shared/reportEmailSender.ts';

const ORG = '11111111-1111-4111-8111-111111111111';
const VENUE = '22222222-2222-4222-8222-222222222222';
const PDF = Buffer.concat([Buffer.from('%PDF-1.4\n'), Buffer.alloc(500, 0x20)]).toString('base64');
const BODY = { kind: 'venue_night', orgId: ORG, venueId: VENUE, ref: '2026-10-30', filename: 'night.pdf', pdfBase64: PDF };
const ROWS = [{ delivery_id: 'd1', batch_id: 'b1', email: 'boss@club.example', org_name: 'Club Co', venue_name: 'Club A', event_title: null }];

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let getUser: ReturnType<typeof vi.fn>;
let serviceRpc: ReturnType<typeof vi.fn>;
let userRpc: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/send-report-email/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
  getUser = vi.fn(async () => ({ data: { user: { id: 'u1', email: 'manager@club.example' } }, error: null }));
  serviceRpc = vi.fn(async () => ({ data: 1, error: null }));
  userRpc = vi.fn(async () => ({ data: ROWS, error: null }));
  // The person's own client (anon key + their token) and the service client (service key): told apart by the key.
  (createClient as any).mockImplementation((_url: string, key: string) => (key === 'service-key' ? { rpc: serviceRpc } : { auth: { getUser }, rpc: userRpc }));
});

const post = (body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }) =>
  handler(new Request('https://fn.test/send-report-email', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) }));

describe('the endpoint', () => {
  it('answers a browser preflight', async () => {
    const res = await handler(new Request('https://fn.test/x', { method: 'OPTIONS', headers: { origin: 'https://www.bottlesupapp.com' } }));
    expect(res.status).toBe(200);
  });

  it('only accepts POST', async () => {
    expect((await handler(new Request('https://fn.test/x', { method: 'GET' }))).status).toBe(405);
  });

  it('refuses a request with no sign-in, before doing anything', async () => {
    const res = await post(BODY, {});
    expect(res.status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
    expect(serviceRpc).not.toHaveBeenCalled();
  });

  it('refuses a session the auth service does not accept', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: { message: 'bad jwt' } });
    const res = await post(BODY);
    expect(res.status).toBe(401);
    expect(userRpc).not.toHaveBeenCalled();
    expect(serviceRpc).not.toHaveBeenCalled();
  });

  it('refuses a person who has no e-mail address on their session', async () => {
    getUser.mockResolvedValue({ data: { user: { id: 'u1', email: null } }, error: null });
    const res = await post(BODY);
    expect(res.status).toBe(401);
    expect(userRpc).not.toHaveBeenCalled();
    expect(sendReportEmail).not.toHaveBeenCalled();
  });

  it('refuses a body that is not JSON', async () => {
    const res = await post('{not json');
    expect(res.status).toBe(400);
    expect(userRpc).not.toHaveBeenCalled();
  });

  it('refuses when the service key is not configured, without sending anything', async () => {
    delete env.SUPABASE_SERVICE_ROLE_KEY;
    const res = await post(BODY);
    expect(res.status).toBe(500);
    expect(sendReportEmail).not.toHaveBeenCalled();
  });

  it('asks the database as the person, sends, and records with the service role', async () => {
    const res = await post(BODY);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ sent: 1, failed: 0, results: [{ email: 'boss@club.example', ok: true }] });
    expect(userRpc.mock.calls[0][0]).toBe('report_send_begin');
    expect(serviceRpc.mock.calls.map((c) => c[0])).toEqual(['report_send_finish']);
    expect(sendReportEmail).toHaveBeenCalledTimes(1);
    expect((sendReportEmail as any).mock.calls[0][4]).toEqual({ filename: 'night.pdf', contentBase64: PDF });
  });

  it('takes the sender from the session, not from the request', async () => {
    await post({ ...BODY, senderEmail: 'ceo@elsewhere.example' });
    expect((sendReportEmail as any).mock.calls[0][3]).toContain('Sent by manager@club.example');
    expect((sendReportEmail as any).mock.calls[0][3]).not.toContain('ceo@elsewhere');
  });

  it('never returns the PDF or a provider message', async () => {
    (sendReportEmail as any).mockResolvedValueOnce({ sent: false, reason: 'send_failed' });
    const res = await post(BODY);
    const text = await res.text();
    expect(text).not.toContain(PDF);
    expect(JSON.parse(text)).toEqual({ sent: 0, failed: 1, results: [{ email: 'boss@club.example', ok: false }] });
  });

  it('passes a refusal from the database on, as a sentence', async () => {
    userRpc.mockResolvedValue({ data: null, error: { message: 'not allowed' } });
    const res = await post(BODY);
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'You cannot e-mail this report.' });
    expect(sendReportEmail).not.toHaveBeenCalled();
    expect(serviceRpc).not.toHaveBeenCalled();
  });
});
