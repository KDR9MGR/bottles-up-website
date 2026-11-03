import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('npm:@supabase/supabase-js@2', () => ({ createClient: vi.fn() }));
import { createClient } from 'npm:@supabase/supabase-js@2';
import { model } from './stubs/anthropic-sdk.ts';

let env: Record<string, string | undefined> = {};
let handler: (req: Request) => Promise<Response>;
let getUser: ReturnType<typeof vi.fn>;
let rpc: ReturnType<typeof vi.fn>;

beforeAll(async () => {
  (globalThis as any).Deno = {
    serve: (h: (req: Request) => Promise<Response>) => { handler = h; },
    env: { get: (k: string) => env[k] },
  };
  await import('../../supabase/functions/suggest-caption/index.ts');
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  env = { SUPABASE_URL: 'http://db.test', SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key', ANTHROPIC_API_KEY: 'sk-test' };
  getUser = vi.fn(async () => ({ data: { user: { id: 'u1' } }, error: null }));
  rpc = vi.fn(async () => ({ data: { left: 19 }, error: null }));
  (createClient as any).mockReturnValue({ auth: { getUser }, rpc });
  model.calls.length = 0;
  model.apiKeys.length = 0;
  model.answer = async () => ({ stop_reason: 'end_turn', content: [{ type: 'text', text: '{"captions": ["Friday was a good one", "Lights, music, friends", "Again next week?"]}' }] });
});

const post = (body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }) =>
  handler(new Request('https://fn.test/suggest-caption', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) }));

describe('the endpoint', () => {
  it('answers a preflight and only accepts POST', async () => {
    expect((await handler(new Request('https://fn.test/x', { method: 'OPTIONS', headers: { origin: 'https://www.bottlesupapp.com' } }))).status).toBe(200);
    expect((await handler(new Request('https://fn.test/x', { method: 'GET' }))).status).toBe(405);
  });

  it('refuses a request with no sign-in before anything else happens', async () => {
    const res = await post({ idea: 'great night' }, {});
    expect(res.status).toBe(401);
    expect(createClient).not.toHaveBeenCalled();
    expect(model.calls).toHaveLength(0);
  });

  it('refuses a sign-in the auth service rejects, and never asks the model', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: { message: 'bad jwt' } });
    expect((await post({ idea: 'great night' })).status).toBe(401);
    expect(rpc).not.toHaveBeenCalled();
    expect(model.calls).toHaveLength(0);
  });

  it('acts as the CALLER with the public key, never with the service key', async () => {
    await post({ idea: 'great night' });
    const [url, key, options] = (createClient as any).mock.calls[0];
    expect(url).toBe('http://db.test');
    expect(key).toBe('anon-key');
    expect(options.global.headers.Authorization).toBe('Bearer user-jwt');
    expect(JSON.stringify((createClient as any).mock.calls)).not.toContain('service-key');
  });

  it('says what is wrong with a body that is not JSON, or has no idea, without counting the request or asking the model', async () => {
    const bad = await post('{not json');
    expect(bad.status).toBe(400);
    const empty = await post({ idea: 'x' });
    expect(empty.status).toBe(400);
    expect((await empty.json()).error).toContain('3 to 300');
    expect(rpc).not.toHaveBeenCalled();
    expect(model.calls).toHaveLength(0);
  });
});

describe('the database decides first', () => {
  it('counts the request AS the person before the model is asked', async () => {
    const order: string[] = [];
    rpc.mockImplementation(async () => { order.push('gate'); return { data: { left: 18 }, error: null }; });
    model.answer = async () => { order.push('model'); return { stop_reason: 'end_turn', content: [{ type: 'text', text: '{"captions": ["Only one"]}' }] }; };
    await post({ idea: 'great night' });
    expect(order).toEqual(['gate', 'model']);
    expect(rpc).toHaveBeenCalledWith('ai_caption_begin');
  });

  it('a used-up day is 429 with the sentence, and the model is never asked', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: "You have used all of today's caption ideas. Try again tomorrow." } });
    const res = await post({ idea: 'great night' });
    expect(res.status).toBe(429);
    expect((await res.json()).error).toBe("You have used all of today's caption ideas. Try again tomorrow.");
    expect(model.calls).toHaveLength(0);
  });

  it('a switch that is off, or rules not accepted, is 403 with the sentence', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'Caption ideas are not open yet.' } });
    const off = await post({ idea: 'great night' });
    expect(off.status).toBe(403);
    expect((await off.json()).error).toBe('Caption ideas are not open yet.');
    rpc.mockResolvedValue({ data: null, error: { message: 'Read and accept the community rules first.' } });
    expect((await post({ idea: 'great night' })).status).toBe(403);
    rpc.mockResolvedValue({ data: null, error: { message: 'Sign in first.' } });
    expect((await post({ idea: 'great night' })).status).toBe(401);
    expect(model.calls).toHaveLength(0);
  });
});

describe('asking the model', () => {
  it('without the account key it says it is not set up, after the gate', async () => {
    env.ANTHROPIC_API_KEY = undefined;
    const res = await post({ idea: 'great night' });
    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe('Caption ideas are not set up yet.');
    expect(model.calls).toHaveLength(0);
  });

  it('sends only the typed words and the place, with the rules for the model, on the key from the secret', async () => {
    await post({ idea: '  dancing   till 3am ', kind: 'story', context: 'Club A', extra: 'ignored', user_id: 'someone-else' });
    expect(model.apiKeys).toEqual(['sk-test']);
    expect(model.calls).toHaveLength(1);
    const call = model.calls[0] as any;
    expect(call.model).toBe('claude-opus-5-5');
    expect(call.system).toContain('Never invent');
    expect(call.messages).toHaveLength(1);
    expect(call.messages[0].role).toBe('user');
    expect(call.messages[0].content).toContain('dancing till 3am');
    expect(call.messages[0].content).toContain('Club A');
    expect(call.messages[0].content).toContain('a story');
    const everything = JSON.stringify(call);
    expect(everything).not.toContain('someone-else');
    expect(everything).not.toContain('u1');
    expect(everything).not.toContain('ignored');
  });

  it('asks for a small job at low effort, with a fallback if the model declines', async () => {
    await post({ idea: 'great night' });
    const call = model.calls[0] as any;
    expect(call.output_config).toEqual({ effort: 'low' });
    expect(call.betas).toEqual(['server-side-fallback-2026-06-01']);
    expect(call.fallbacks).toEqual([{ model: 'claude-opus-4-8' }]);
    expect(call.max_tokens).toBeGreaterThanOrEqual(4000);
  });

  it('answers the captions, three at most', async () => {
    const res = await post({ idea: 'great night' });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ captions: ['Friday was a good one', 'Lights, music, friends', 'Again next week?'] });
    model.answer = async () => ({ stop_reason: 'end_turn', content: [{ type: 'thinking', thinking: '' }, { type: 'text', text: '{"captions": ["a one", "b two", "c three", "d four"]}' }] });
    expect((await (await post({ idea: 'great night' })).json()).captions).toEqual(['a one', 'b two', 'c three']);
  });

  it('when it has nothing to offer, or declines, it says so and offers nothing', async () => {
    model.answer = async () => ({ stop_reason: 'end_turn', content: [{ type: 'text', text: '{"captions": []}' }] });
    const empty = await (await post({ idea: 'great night' })).json();
    expect(empty.captions).toEqual([]);
    expect(empty.message).toContain('could not think of a caption');
    model.answer = async () => ({ stop_reason: 'refusal', stop_details: { category: 'general_harms' }, content: [] });
    const refused = await post({ idea: 'great night' });
    expect(refused.status).toBe(200);
    expect((await refused.json()).captions).toEqual([]);
  });

  it('when the model cannot be reached it says so, in a sentence, and logs the kind of failure only', async () => {
    model.answer = async () => { throw Object.assign(new Error('secret details about the request: great night'), { status: 529 }); };
    const res = await post({ idea: 'great night' });
    expect(res.status).toBe(502);
    expect((await res.json()).error).toBe('We could not reach the caption writer just now. Try again in a moment.');
    const logged = JSON.stringify((console.error as any).mock.calls);
    expect(logged).toContain('529');
    expect(logged).not.toContain('great night');
  });
});
