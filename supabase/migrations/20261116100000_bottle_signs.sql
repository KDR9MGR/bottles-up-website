-- Bottle signs (client Phase 2 brief, section 14 "Signs: Owner/manager Settings -> Bottle Signs -> All Eligible Items or Selected Premium Products. Server enters text on
-- eligible order; required staff review can precede service. Sign travels with the order."; section 28 "Manage menu/signs"; scenario 10 "Add bottle with discount/sign").
--
--   * THE CLUB'S SETTING (owner or manager of that club): sign_mode 'off' (the default: nobody can put a sign on anything), 'all' (any bottle on the menu may carry a sign) or
--     'selected' (only the bottles the club has marked as sign bottles), and sign_review (a sign typed by a server has to be approved by a manager before the bottle is prepared).
--     Changing a setting changes what can be done from then on; signs already on orders are not touched.
--   * THE SIGN is one line of plain text, 1 to 40 characters, on ONE bottle line of an order (site_table_booking_bottles.sign_text). The manager or owner of the club, or the
--     server the table was given to, sets or clears it, only while the line is not cancelled and has not gone out ("on the way" or delivered). Typing the same words again changes
--     nothing. With review on, a server's sign waits for a manager (sign_status 'pending_review'); a manager's own sign is approved at once. Changing an approved sign under review
--     sends it back to review. A manager approves, or declines with a reason (the server then changes the words, which sends it back to review).
--   * REVIEW BEFORE SERVICE is enforced by the table, so it holds on every path that moves an order (the app's desk_set_service_status, partial delivery, and the website's own
--     hand-made staff function): with review on, a line whose sign is waiting or declined cannot be moved to preparing, ready, on the way or delivered. Accepting is still fine.
--     Nothing existing is replaced to do this.
--   * READING: desk_line_signs(lines) gives the signs and whether each line may take one now, for the lines the caller may see (the manager, owner, or that table's server;
--     a verifier and the door see none). desk_pending_sign_reviews(club) is the manager's queue. The guest's own request at checkout (booking.bottle_sign_text) is separate and
--     unchanged; the app offers it as a suggestion.
--
-- Additive only: new columns with defaults that change nothing (every club starts with signs off), new functions, one trigger. No existing function is replaced and no row is
-- rewritten. Needs the server desk (20261014*), venue setup (20261010100000), and the tables site_bottles / site_table_booking_bottles.

do $guard$
declare
  fn text;
begin
  foreach fn in array array['public.require_venue_editor(uuid)', 'public.venue_setup_log(text, text, uuid, uuid, jsonb)', 'public.desk_booking_level(uuid)', 'public.desk_log(text, text, uuid, jsonb)',
                            'public.booking_venue(uuid)', 'public.setup_only_keys(jsonb, text[])', 'public.setup_text(jsonb, text, text, int)'] loop
    if to_regprocedure(fn) is null then
      raise exception '% does not exist: run the earlier server desk and venue setup migrations first. Nothing was changed.', fn;
    end if;
  end loop;
  if to_regclass('public.site_bottles') is null or to_regclass('public.site_table_booking_bottles') is null then
    raise exception 'site_bottles and site_table_booking_bottles must exist first. Nothing was changed.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_venues' and column_name in ('sign_mode', 'sign_review'))
     or exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_bottles' and column_name = 'sign_eligible')
     or exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_table_booking_bottles' and column_name like 'sign\_%') then
    raise exception 'a sign column already exists: this migration was already applied, or something else made one. Nothing was changed.';
  end if;
end $guard$;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.site_venues
  add column sign_mode text not null default 'off' constraint site_venues_sign_mode_check check (sign_mode in ('off', 'all', 'selected')),
  add column sign_review boolean not null default false;

alter table public.site_bottles
  add column sign_eligible boolean not null default false;

alter table public.site_table_booking_bottles
  add column sign_text text,
  add column sign_status text,
  add column sign_set_by uuid references auth.users (id) on delete set null,
  add column sign_set_at timestamptz,
  add column sign_reviewed_by uuid references auth.users (id) on delete set null,
  add column sign_reviewed_at timestamptz,
  add column sign_review_note text,
  add constraint site_tbb_sign_text_check check (sign_text is null or (char_length(sign_text) between 1 and 40 and sign_text !~ '[[:cntrl:]]')),
  add constraint site_tbb_sign_status_check check (sign_status is null or sign_status in ('pending_review', 'approved', 'rejected')),
  add constraint site_tbb_sign_together check ((sign_text is null) = (sign_status is null)),
  add constraint site_tbb_sign_note_check check (sign_review_note is null or char_length(sign_review_note) <= 200);

-- ---------------------------------------------------------------------------
-- 2. Review before service, enforced by the table
-- ---------------------------------------------------------------------------
create function public.bottle_sign_service_gate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.sign_status in ('pending_review', 'rejected')
     and new.service_status is distinct from old.service_status
     and new.service_status in ('preparing', 'ready', 'picked_up', 'served')
     and exists (select 1 from public.site_table_bookings b join public.site_venues v on v.id = b.venue_id where b.id = new.booking_id and v.sign_review) then
    raise exception 'the sign on this order has not been approved yet';
  end if;
  return new;
end;
$$;
revoke all on function public.bottle_sign_service_gate() from public, anon, authenticated;

create trigger site_table_booking_bottles_sign_gate
  before update of service_status on public.site_table_booking_bottles
  for each row execute function public.bottle_sign_service_gate();

-- ---------------------------------------------------------------------------
-- 3. The club's settings (owner or manager of that club)
-- ---------------------------------------------------------------------------
create function public.venue_sign_settings(p_venue uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  return jsonb_build_object(
    'mode', (select v.sign_mode from public.site_venues v where v.id = p_venue),
    'review_required', (select v.sign_review from public.site_venues v where v.id = p_venue),
    'bottles', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'size', x.size, 'category', x.category, 'sign_eligible', x.sign_eligible, 'is_available', x.is_available)
                       order by lower(coalesce(x.category, '')), lower(x.name), x.id)
      from (select b.id, b.name, b.size, b.category, b.sign_eligible, b.is_available from public.site_bottles b where b.venue_id = p_venue order by lower(coalesce(b.category, '')), lower(b.name), b.id limit 300) x), '[]'::jsonb));
end;
$$;

-- details: {"mode": "off" | "all" | "selected", "review_required": true | false}; either or both. Returns the settings as they now are.
create function public.save_venue_sign_settings(p_venue uuid, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mode text;
  v_review boolean;
  v_old_mode text;
  v_old_review boolean;
begin
  perform public.require_venue_editor(p_venue);
  perform public.setup_only_keys(p_details, array['mode', 'review_required']);
  v_mode := public.setup_text(p_details, 'mode', 'sign mode', 20);
  if v_mode is not null and v_mode not in ('off', 'all', 'selected') then raise exception 'signs must be off, on every bottle, or on the bottles you choose'; end if;
  if p_details ? 'review_required' then
    if jsonb_typeof(p_details -> 'review_required') <> 'boolean' then raise exception 'say whether a sign needs a manager''s approval, yes or no'; end if;
    v_review := (p_details ->> 'review_required')::boolean;
  end if;
  if v_mode is null and v_review is null then raise exception 'choose how signs work'; end if;

  select v.sign_mode, v.sign_review into v_old_mode, v_old_review from public.site_venues v where v.id = p_venue for update;
  if not found then raise exception 'not allowed'; end if;
  if (v_mode is null or v_mode = v_old_mode) and (v_review is null or v_review = v_old_review) then
    return public.venue_sign_settings(p_venue);
  end if;
  update public.site_venues set sign_mode = coalesce(v_mode, sign_mode), sign_review = coalesce(v_review, sign_review) where id = p_venue;
  perform public.venue_setup_log('venue.bottle_sign_settings_saved', 'site_venues', p_venue, p_venue,
    jsonb_build_object('mode_from', v_old_mode, 'mode_to', coalesce(v_mode, v_old_mode), 'review_from', v_old_review, 'review_to', coalesce(v_review, v_old_review)));
  return public.venue_sign_settings(p_venue);
end;
$$;

-- Marks a bottle of this club's menu as one that may carry a sign (it matters when the club's mode is "selected"). Returns whether anything changed.
create function public.set_bottle_sign_eligible(p_venue uuid, p_bottle uuid, p_eligible boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old boolean;
begin
  perform public.require_venue_editor(p_venue);
  if p_eligible is null then raise exception 'say whether this bottle may carry a sign'; end if;
  select b.sign_eligible into v_old from public.site_bottles b where b.id = p_bottle and b.venue_id = p_venue for update;
  if not found then raise exception 'that bottle is not on this club''s menu'; end if;
  if v_old = p_eligible then return false; end if;
  update public.site_bottles set sign_eligible = p_eligible where id = p_bottle;
  perform public.venue_setup_log('venue.bottle_sign_eligibility_saved', 'site_bottles', p_bottle, p_venue, jsonb_build_object('from', v_old, 'to', p_eligible));
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. A sign on an order line
-- ---------------------------------------------------------------------------
-- Sets the sign (or clears it with empty text). Returns {changed, sign_text, sign_status}.
create function public.desk_set_bottle_sign(p_line uuid, p_text text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_level text;
  v_line record;
  v_venue record;
  v_text text := nullif(btrim(coalesce(p_text, '')), '');
  v_status text;
  v_bottle_ok boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select bb.booking_id into v_booking_id from public.site_table_booking_bottles bb where bb.id = p_line;
  v_level := public.desk_booking_level(v_booking_id);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;

  select bb.id, bb.bottle_id, bb.sign_text, bb.sign_status, bb.service_status, bb.cancelled_at into v_line
    from public.site_table_booking_bottles bb where bb.id = p_line for update;
  select v.id, v.sign_mode, v.sign_review into v_venue from public.site_venues v join public.site_table_bookings b on b.venue_id = v.id where b.id = v_booking_id;

  if v_line.cancelled_at is not null then raise exception 'this item was cancelled'; end if;
  if v_line.service_status in ('picked_up', 'served') then raise exception 'this item is already on its way, so its sign can no longer change'; end if;

  if v_text is null then
    if v_line.sign_text is null then return jsonb_build_object('changed', false, 'sign_text', null, 'sign_status', null); end if;
    update public.site_table_booking_bottles
      set sign_text = null, sign_status = null, sign_set_by = null, sign_set_at = null, sign_reviewed_by = null, sign_reviewed_at = null, sign_review_note = null
      where id = p_line;
    perform public.desk_log('table_booking.bottle_sign_cleared', 'site_table_booking_bottles', p_line, jsonb_build_object('venue_id', v_venue.id, 'booking_id', v_booking_id, 'old_text', v_line.sign_text));
    return jsonb_build_object('changed', true, 'sign_text', null, 'sign_status', null);
  end if;

  if char_length(v_text) > 40 then raise exception 'a sign is at most 40 characters'; end if;
  if v_text ~ '[[:cntrl:]]' then raise exception 'a sign is one line of plain text'; end if;
  if v_venue.sign_mode = 'off' then raise exception 'signs are not switched on for this club'; end if;
  if v_venue.sign_mode = 'selected' then
    select coalesce(b.sign_eligible, false) into v_bottle_ok from public.site_bottles b where b.id = v_line.bottle_id;
    if not coalesce(v_bottle_ok, false) then raise exception 'this bottle is not one of the club''s sign bottles'; end if;
  end if;

  if v_line.sign_text is not distinct from v_text then
    return jsonb_build_object('changed', false, 'sign_text', v_line.sign_text, 'sign_status', v_line.sign_status);
  end if;

  v_status := case when v_venue.sign_review and v_level = 'server' then 'pending_review' else 'approved' end;
  update public.site_table_booking_bottles
    set sign_text = v_text, sign_status = v_status, sign_set_by = auth.uid(), sign_set_at = clock_timestamp(),
        sign_reviewed_by = case when v_status = 'approved' then auth.uid() end, sign_reviewed_at = case when v_status = 'approved' then clock_timestamp() end,
        sign_review_note = null
    where id = p_line;
  perform public.desk_log('table_booking.bottle_sign_set', 'site_table_booking_bottles', p_line,
    jsonb_build_object('venue_id', v_venue.id, 'booking_id', v_booking_id, 'old_text', v_line.sign_text, 'new_text', v_text, 'status', v_status));
  return jsonb_build_object('changed', true, 'sign_text', v_text, 'sign_status', v_status);
end;
$$;

-- A manager (or the owner) approves a waiting sign, or declines it with a reason of 3 to 200 characters. Not one's own sign. Asking for what is already decided changes nothing.
create function public.desk_review_bottle_sign(p_line uuid, p_decision text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_line record;
  v_venue uuid;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_new text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select bb.booking_id into v_booking_id from public.site_table_booking_bottles bb where bb.id = p_line;
  if public.desk_booking_level(v_booking_id) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_decision is null or p_decision not in ('approve', 'reject') then raise exception 'approve the sign or decline it'; end if;
  if p_decision = 'reject' and (v_note is null or char_length(v_note) < 3) then raise exception 'say why the sign is declined (at least 3 characters)'; end if;
  if v_note is not null and char_length(v_note) > 200 then raise exception 'keep the reason to 200 characters or fewer'; end if;
  v_new := case p_decision when 'approve' then 'approved' else 'rejected' end;

  select bb.id, bb.sign_text, bb.sign_status, bb.sign_set_by, bb.service_status, bb.cancelled_at into v_line
    from public.site_table_booking_bottles bb where bb.id = p_line for update;
  v_venue := public.booking_venue(v_booking_id);

  if v_line.sign_text is null then raise exception 'this item has no sign'; end if;
  if v_line.sign_status = v_new then return jsonb_build_object('changed', false, 'sign_status', v_new); end if;
  if v_line.sign_status <> 'pending_review' then raise exception 'this sign was already reviewed'; end if;
  if v_line.cancelled_at is not null then raise exception 'this item was cancelled'; end if;
  if v_line.sign_set_by is not distinct from auth.uid() then raise exception 'someone else has to review your sign'; end if;

  update public.site_table_booking_bottles
    set sign_status = v_new, sign_reviewed_by = auth.uid(), sign_reviewed_at = clock_timestamp(), sign_review_note = case when v_new = 'rejected' then v_note end
    where id = p_line;
  perform public.desk_log('table_booking.bottle_sign_reviewed', 'site_table_booking_bottles', p_line,
    jsonb_build_object('venue_id', v_venue, 'booking_id', v_booking_id, 'sign_text', v_line.sign_text, 'decision', p_decision, 'note', v_note));
  return jsonb_build_object('changed', true, 'sign_status', v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Reading
-- ---------------------------------------------------------------------------
-- For the lines the caller already holds (at most 500): the sign each carries, and whether the caller may enter or change one now. A line the caller may not see is not in
-- the answer; neither is a line with no sign that cannot take one.
create function public.desk_line_signs(p_lines uuid[])
returns table (line_id uuid, sign_text text, sign_status text, review_note text, can_set boolean, review_required boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_lines is null or cardinality(p_lines) = 0 then return; end if;
  if cardinality(p_lines) > 500 then raise exception 'ask for at most 500 items at a time'; end if;
  return query
    with wanted as (
      select bb.id, bb.booking_id, bb.bottle_id, bb.sign_text as txt, bb.sign_status as st, bb.sign_review_note as note, bb.service_status, bb.cancelled_at
      from public.site_table_booking_bottles bb where bb.id = any (p_lines)
    ), levels as (
      select d.booking_id, public.desk_booking_level(d.booking_id) as lvl from (select distinct w.booking_id from wanted w) d
    )
    select w.id, w.txt, w.st, w.note,
           (l.lvl in ('manager', 'server') and w.cancelled_at is null and w.service_status not in ('picked_up', 'served')
            and (v.sign_mode = 'all' or (v.sign_mode = 'selected' and coalesce(bt.sign_eligible, false)))),
           v.sign_review
    from wanted w
    join levels l on l.booking_id = w.booking_id
    join public.site_table_bookings b on b.id = w.booking_id
    join public.site_venues v on v.id = b.venue_id
    left join public.site_bottles bt on bt.id = w.bottle_id
    where l.lvl in ('manager', 'server')
      and (w.txt is not null
           or (w.cancelled_at is null and w.service_status not in ('picked_up', 'served') and (v.sign_mode = 'all' or (v.sign_mode = 'selected' and coalesce(bt.sign_eligible, false)))));
end;
$$;

-- The manager's queue: signs waiting for approval at this club, oldest first (at most 200). Tables already closed out and cancelled items are not work.
create function public.desk_pending_sign_reviews(p_venue uuid)
returns table (line_id uuid, booking_id uuid, bottle_name text, quantity int, sign_text text, set_by_name text, set_at timestamptz, guest_name text, service_status text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  return query
    select bb.id, bb.booking_id, bb.bottle_name, bb.quantity, bb.sign_text,
           coalesce(nullif(btrim(pr.name), ''), 'Staff member'), bb.sign_set_at, b.customer_name, bb.service_status
    from public.site_table_booking_bottles bb
    join public.site_table_bookings b on b.id = bb.booking_id
    left join public.profiles pr on pr.id = bb.sign_set_by
    where b.venue_id = p_venue and b.status = 'paid' and b.reconciled_at is null
      and bb.sign_status = 'pending_review' and bb.cancelled_at is null and bb.service_status not in ('picked_up', 'served')
    order by bb.sign_set_at, bb.id
    limit 200;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.venue_sign_settings(uuid), public.save_venue_sign_settings(uuid, jsonb), public.set_bottle_sign_eligible(uuid, uuid, boolean),
  public.desk_set_bottle_sign(uuid, text), public.desk_review_bottle_sign(uuid, text, text), public.desk_line_signs(uuid[]), public.desk_pending_sign_reviews(uuid)
from public, anon;
grant execute on function
  public.venue_sign_settings(uuid), public.save_venue_sign_settings(uuid, jsonb), public.set_bottle_sign_eligible(uuid, uuid, boolean),
  public.desk_set_bottle_sign(uuid, text), public.desk_review_bottle_sign(uuid, text, text), public.desk_line_signs(uuid[]), public.desk_pending_sign_reviews(uuid)
to authenticated, service_role;
