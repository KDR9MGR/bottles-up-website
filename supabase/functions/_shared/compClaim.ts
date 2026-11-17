// The logic of comp-claim, the public function behind the claim page, with its collaborators passed in so it can be tested without a network.
//
// A stranger opens the link in an e-mail: they are not signed in, and the database functions they reach (comp_claim_view, comp_claim_submit) can be called by the service role only. This is the
// only door. It counts every visit against a hash of the visitor's address and against the link (so a guesser is slowed and one link cannot be hammered), checks the shape of everything, and
// returns ONLY the fields the page shows: the club, the event, the item, the sign, the expiry and the club's table labels on its floor plan. Never another guest's name or booking.
// One claim only: the database makes a second submission change nothing. See 20261123100000_complimentary_offers.sql and 20261124100000_complimentary_send.sql.

import { TOKEN, UUID, type Outcome } from './compOffer.ts';

type RpcResult = Promise<{ data: unknown; error: { message: string } | null }>;

export interface ClaimDeps {
  /** Calls a database function with the SERVICE role. Only this function holds that key. */
  rpcService: (fn: string, args: Record<string, unknown>) => RpcResult;
  /** A hash of the visitor's address (never the address itself). */
  visitor: string;
}

/** Visits one address may make in a window, and visits one link may take. */
export const VISITOR_LIMIT = 60;
export const LINK_LIMIT = 30;
export const WINDOW_SECONDS = 600;

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

const TOO_MANY: Outcome = { status: 429, body: { error: 'Too many tries. Wait a few minutes and try again.' } };
const FAILED: Outcome = { status: 500, body: { error: 'Something went wrong. Try again.' } };
const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const str = (v: unknown, max: number): string | null => (typeof v === 'string' && v.length <= max ? v : null);
const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const link = (v: unknown): string | null => (typeof v === 'string' && /^https?:\/\/[^\s"'<>]{1,500}$/.test(v) ? v : null);

const STATES = new Set(['not_found', 'expired', 'cancelled', 'claimed', 'open', 'submitted', 'bad_table']);

/** What the page may be told about an open offer: nothing but this. */
function openView(d: Record<string, unknown>): Record<string, unknown> | null {
  const venue = str(d.venue_name, 120);
  const item = str(d.item, 120);
  const quantity = num(d.quantity);
  const expires = str(d.expires_at, 40);
  if (venue === null || item === null || quantity === null || expires === null) return null;
  const floors = (Array.isArray(d.floors) ? d.floors : []).flatMap((f) => {
    if (!isObject(f)) return [];
    const id = typeof f.id === 'string' && UUID.test(f.id) ? f.id : null;
    const label = str(f.label, 80);
    return id && label !== null ? [{ id, label, image_url: link(f.image_url) }] : [];
  });
  const tables = (Array.isArray(d.tables) ? d.tables : []).flatMap((t) => {
    if (!isObject(t)) return [];
    const id = typeof t.id === 'string' && UUID.test(t.id) ? t.id : null;
    const name = str(t.name, 80);
    if (!id || name === null) return [];
    return [{
      id,
      name,
      floor_id: typeof t.floor_id === 'string' && UUID.test(t.floor_id) ? t.floor_id : null,
      pos_x: num(t.pos_x),
      pos_y: num(t.pos_y),
      width: num(t.width),
      height: num(t.height),
    }];
  });
  return {
    state: 'open',
    venue_name: venue,
    event_title: str(d.event_title, 200),
    item,
    size: str(d.size, 40),
    quantity,
    sign: str(d.sign, 40),
    recipient_name: str(d.recipient_name, 60),
    expires_at: expires,
    floors,
    tables,
  };
}

export async function handleClaim(body: unknown, deps: ClaimDeps): Promise<Outcome> {
  if (!isObject(body)) return { status: 400, body: { error: 'Invalid request.' } };
  const action = body.action;
  if (action !== 'view' && action !== 'submit') return { status: 400, body: { error: 'Invalid request.' } };
  const token = body.token;
  let tableId: string | null = null;
  if (action === 'submit') {
    if (typeof body.tableId !== 'string' || !UUID.test(body.tableId)) return { status: 400, body: { error: 'Choose where you are.' } };
    tableId = body.tableId;
  }

  // Every visit counts, whatever the link: a guesser is slowed down before anything is looked up.
  const visitor = await deps.rpcService('comp_claim_throttle', { p_key: `ip:${deps.visitor}`, p_limit: VISITOR_LIMIT, p_window_seconds: WINDOW_SECONDS });
  if (visitor.error) return FAILED;
  if (visitor.data !== true) return TOO_MANY;

  // A link that cannot be a link is "not found", the same answer as one that is not there: nothing tells a guesser how close they were.
  if (typeof token !== 'string' || !TOKEN.test(token)) return { status: 200, body: { state: 'not_found' } };

  const perLink = await deps.rpcService('comp_claim_throttle', { p_key: `link:${(await sha256Hex(token)).slice(0, 32)}`, p_limit: LINK_LIMIT, p_window_seconds: WINDOW_SECONDS });
  if (perLink.error) return FAILED;
  if (perLink.data !== true) return TOO_MANY;

  const answered = action === 'view'
    ? await deps.rpcService('comp_claim_view', { p_token: token })
    : await deps.rpcService('comp_claim_submit', { p_token: token, p_table: tableId });
  if (answered.error || !isObject(answered.data)) {
    console.error('comp-claim: the database could not answer');
    return FAILED;
  }
  const data = answered.data;
  const state = typeof data.state === 'string' && STATES.has(data.state) ? data.state : null;
  if (state === null) return FAILED;

  if (state === 'open') {
    const view = openView(data);
    return view ? { status: 200, body: view } : FAILED;
  }
  if (state === 'claimed') {
    const item = str(data.item, 120);
    const quantity = num(data.quantity);
    const venue = str(data.venue_name, 120);
    // A second submission answers with the state alone; opening the link again says what it was.
    return { status: 200, body: item !== null && quantity !== null && venue !== null ? { state, item, quantity, venue_name: venue } : { state } };
  }
  return { status: 200, body: { state } };
}
