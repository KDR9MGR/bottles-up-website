import { createClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@1';
import { corsHeadersFor, handleOptions } from '../_shared/cors.ts';
import { NOTHING_SENTENCE, SYSTEM_PROMPT, buildUserMessage, parseCaptions, parseRequest } from '../_shared/captionIdeas.ts';

// Caption ideas for the customer app: the person types a few words about a post and gets three drafts. The draft is theirs to read, change or ignore; nothing is posted here.
//
//   1. The caller must be signed in (their own JWT; a user id in the body is never trusted).
//   2. The database decides whether they may ask: the `ai_captions` switch is on, they accepted the community rules, and they have not used today's 20. It counts the request
//      (`ai_caption_begin`, called AS the person) BEFORE any model is asked, so a refusal costs nothing.
//   3. Only the typed words and the place or event name go to the model (see _shared/captionIdeas.ts); not the picture, not the account. They are not stored or logged here.
//
// Needs the secret ANTHROPIC_API_KEY (the owner's Anthropic account). Without it the function says it is not set up.
const MODEL = 'claude-opus-5-5';

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const cors = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Sign in first.' }, 401);

  const callerClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await callerClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: 'Sign in first.' }, 401);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Say a little about what you are posting.' }, 400);
  }
  const parsed = parseRequest(body);
  if (!parsed.ok) return json({ error: parsed.error }, 400);

  // The database's answer is a plain sentence; how it maps to a status only tells the app whether trying again later can help.
  const { error: gateError } = await callerClient.rpc('ai_caption_begin');
  if (gateError) {
    const status = /Try again tomorrow/.test(gateError.message) ? 429 : /Sign in/.test(gateError.message) ? 401 : 403;
    return json({ error: gateError.message }, status);
  }

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) return json({ error: 'Caption ideas are not set up yet.' }, 503);

  try {
    const client = new Anthropic({ apiKey });
    const response = await client.beta.messages.create({
      model: MODEL,
      max_tokens: 8000,
      // A caption is a small job: low effort keeps it quick and cheap. Fallbacks re-run the request on another model if the first declines it.
      output_config: { effort: 'low' },
      betas: ['server-side-fallback-2026-06-01'],
      fallbacks: [{ model: 'claude-opus-4-8' }],
      system: SYSTEM_PROMPT,
      messages: [{ role: 'user', content: buildUserMessage(parsed.value) }],
    });
    if (response.stop_reason === 'refusal') return json({ captions: [], message: NOTHING_SENTENCE });
    const text = response.content.flatMap((b: { type: string; text?: string }) => (b.type === 'text' && typeof b.text === 'string' ? [b.text] : [])).join('\n');
    const captions = parseCaptions(text);
    return json(captions.length === 0 ? { captions: [], message: NOTHING_SENTENCE } : { captions });
  } catch (err) {
    // Say what kind of failure, never what was asked.
    console.error('suggest-caption: the model could not be reached', (err as { status?: number })?.status ?? 'no status');
    return json({ error: 'We could not reach the caption writer just now. Try again in a moment.' }, 502);
  }
});
