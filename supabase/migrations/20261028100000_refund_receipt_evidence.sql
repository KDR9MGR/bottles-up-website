-- A refund paid back at the club: the receipt photo is checked, and the list of requests shows the evidence (developer brief 15 Oct, section 31; the owner's wish to see a receipt photo).
-- This is a CORRECTION of 20261023100000_refund_policy_and_requests.sql, which is already live in production and must not be edited. Two things:
--   * desk_complete_club_refund(request, reference, receipt path) now refuses a receipt photo that is not filed under the booking's own id in the private receipts bucket (and one with ".." in it), so a
--     booking can never point at another booking's file. Same arguments, same answer.
--   * desk_refund_requests(venue, status) returns two more columns, refund_reference and refund_receipt_path (what was recorded when the refund was paid back at the club), so the app can show the
--     reference and open the photo. A function's list of columns cannot be changed in place, so it is dropped and made again with its grants (nothing else depends on it; only the app calls it).
--
-- GUARD (compare-and-swap, because both are LIVE functions): each is replaced only if it is exactly the version 20261023100000 made (its fingerprint is below: md5 of the whitespace-normalised
-- source | security definer | config, the same fingerprint the earlier guards use); one that is already the corrected version is left alone; anything else (changed by hand, made differently, or
-- missing) STOPS the migration before anything is changed. Where 20261023100000 is replayed on a new database the corrected versions are what this file produces too.
-- Undo: put 20261023100000's two versions back (tests/db/fixtures/refund_receipt_before.sql); the receipt check and the two columns are the only difference.

do $guard$
declare
  v_live text;
  r record;
begin
  for r in select * from (values
      ('desk_complete_club_refund', 'p_request uuid, p_pos_reference text, p_receipt_path text', '1f7ae08a68a2ce5aeefcf84c45026104', '365989e5592b3bdc80ebb6282e742818'),
      ('desk_refund_requests', 'p_venue uuid, p_status text', '4519f961a03dc473ac62f9a6c5a5cdc2', '441b138b50cd2960b3697a8467c45f31')
    ) as x(fname, fargs, c_before, c_after) loop
    select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
      into v_live
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname and pg_get_function_identity_arguments(p.oid) = r.fargs;
    if v_live is null then
      raise exception 'public.%() does not exist in this database. Nothing was changed.', r.fname;
    end if;
    if v_live <> r.c_before and v_live <> r.c_after then
      raise exception '%() in this database differs from the version this change was written against (live fingerprint %, expected %). It was NOT replaced, because that could undo a change made directly in the database. Nothing was changed.', r.fname, v_live, r.c_before;
    end if;
  end loop;
end
$guard$;

do $replace$
declare
  v_live text;
begin
  -- the receipt check
  select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, '')) into v_live
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'desk_complete_club_refund';
  if v_live = '1f7ae08a68a2ce5aeefcf84c45026104' then
    execute $sql$
create or replace function public.desk_complete_club_refund(p_request uuid, p_pos_reference text, p_receipt_path text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_refund_requests;
  v_ref text := nullif(btrim(coalesce(p_pos_reference, '')), '');
  v_path text := nullif(btrim(coalesce(p_receipt_path, '')), '');
  v_refund uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into r from public.site_refund_requests where id = p_request for update;
  if not found or public.desk_level(r.venue_id) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if r.status = 'completed' then return r.refund_id; end if;
  if r.status <> 'approved' or r.method <> 'club' then raise exception 'only an approved refund that is paid back at the club can be recorded here'; end if;
  if v_ref is null and v_path is null then raise exception 'add the terminal or receipt reference, or a photo of the receipt, as evidence'; end if;
  if v_ref is not null and char_length(v_ref) > 200 then raise exception 'the reference is too long'; end if;
  -- the photo is filed under the booking's own id in the private receipts bucket (the bucket's policy lets a manager of THAT booking add one there), so it cannot point at another booking's file
  if v_path is not null and (char_length(v_path) > 300 or v_path not like r.booking_id::text || '/%' or v_path like '%..%') then raise exception 'the receipt photo does not belong to this booking'; end if;
  perform 1 from public.site_table_bookings b where b.id = r.booking_id for update;
  insert into public.site_table_booking_refunds (booking_id, refund_type, amount_cents, reason, pos_reference, receipt_photo_path, recorded_by)
  values (r.booking_id, 'club', r.approved_cents, r.reason, v_ref, v_path, auth.uid()) returning id into v_refund;
  update public.site_table_bookings set amount_paid_cents = greatest(amount_paid_cents - r.approved_cents, 0), updated_at = now() where id = r.booking_id;
  update public.site_refund_requests set status = 'completed', refund_id = v_refund, completed_at = now(), updated_at = now() where id = p_request;
  perform public.desk_log('refund.completed', 'site_refund_requests', p_request, jsonb_build_object('venue_id', r.venue_id, 'booking_id', r.booking_id, 'amount_cents', r.approved_cents, 'method', 'club', 'refund_id', v_refund));
  return v_refund;
end;
$$;
$sql$;
  else
    raise notice 'desk_complete_club_refund() already has the receipt check, so it was left alone';
  end if;

  -- the two evidence columns (a different list of columns needs the function made again, with its grants)
  select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, '')) into v_live
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'desk_refund_requests';
  if v_live = '4519f961a03dc473ac62f9a6c5a5cdc2' then
    drop function public.desk_refund_requests(uuid, text);
    execute $sql$
create function public.desk_refund_requests(p_venue uuid, p_status text default null)
returns table (
  request_id uuid, booking_id uuid, confirmation_code text, guest_name text, table_name text, booking_date date, requested_by_kind text, reason text, status text,
  paid_cents int, available_cents int, policy_percent int, suggested_cents int, approved_cents int, method text, decision_note text, failure_note text,
  decided_at timestamptz, created_at timestamptz, completed_at timestamptz, refund_reference text, refund_receipt_path text
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_status is not null and p_status not in ('requested', 'approved', 'declined', 'processing', 'completed', 'failed') then raise exception 'unknown status'; end if;
  return query
    select r.id, r.booking_id, b.confirmation_code, b.customer_name, t.name, b.booking_date, r.requested_by_kind, r.reason, r.status,
           b.amount_paid_cents, public.booking_refundable_cents(b.id, r.id), r.policy_percent, r.suggested_cents, r.approved_cents, r.method, r.decision_note, r.failure_note,
           r.decided_at, r.created_at, r.completed_at, f.pos_reference, f.receipt_photo_path
      from public.site_refund_requests r
      join public.site_table_bookings b on b.id = r.booking_id
      join public.site_table_types t on t.id = b.table_type_id
      left join public.site_table_booking_refunds f on f.id = r.refund_id
     where r.venue_id = p_venue and (p_status is null or r.status = p_status)
     order by (r.status = 'requested') desc, r.created_at desc, r.id
     limit 200;
end;
$$;
$sql$;
    revoke all on function public.desk_refund_requests(uuid, text) from public, anon;
    grant execute on function public.desk_refund_requests(uuid, text) to authenticated, service_role;
  else
    raise notice 'desk_refund_requests() already returns the evidence columns, so it was left alone';
  end if;
end
$replace$;
