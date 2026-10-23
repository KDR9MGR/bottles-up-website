-- The two functions as 20261023100000_refund_policy_and_requests.sql made them (and as production has them): the state 20261028100000_refund_receipt_evidence.sql corrects.
-- Used by tests/db/migration_guard_refund_receipt.sql.sh to put a database back to "before" and prove the guard. Not a migration; never applied anywhere else.

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
  perform 1 from public.site_table_bookings b where b.id = r.booking_id for update;
  insert into public.site_table_booking_refunds (booking_id, refund_type, amount_cents, reason, pos_reference, receipt_photo_path, recorded_by)
  values (r.booking_id, 'club', r.approved_cents, r.reason, v_ref, v_path, auth.uid()) returning id into v_refund;
  update public.site_table_bookings set amount_paid_cents = greatest(amount_paid_cents - r.approved_cents, 0), updated_at = now() where id = r.booking_id;
  update public.site_refund_requests set status = 'completed', refund_id = v_refund, completed_at = now(), updated_at = now() where id = p_request;
  perform public.desk_log('refund.completed', 'site_refund_requests', p_request, jsonb_build_object('venue_id', r.venue_id, 'booking_id', r.booking_id, 'amount_cents', r.approved_cents, 'method', 'club', 'refund_id', v_refund));
  return v_refund;
end;
$$;

drop function if exists public.desk_refund_requests(uuid, text);

create function public.desk_refund_requests(p_venue uuid, p_status text default null)
returns table (
  request_id uuid, booking_id uuid, confirmation_code text, guest_name text, table_name text, booking_date date, requested_by_kind text, reason text, status text,
  paid_cents int, available_cents int, policy_percent int, suggested_cents int, approved_cents int, method text, decision_note text, failure_note text,
  decided_at timestamptz, created_at timestamptz, completed_at timestamptz
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
           r.decided_at, r.created_at, r.completed_at
      from public.site_refund_requests r
      join public.site_table_bookings b on b.id = r.booking_id
      join public.site_table_types t on t.id = b.table_type_id
     where r.venue_id = p_venue and (p_status is null or r.status = p_status)
     order by (r.status = 'requested') desc, r.created_at desc, r.id
     limit 200;
end;
$$;

revoke all on function public.desk_refund_requests(uuid, text) from public, anon;
grant execute on function public.desk_refund_requests(uuid, text) to authenticated, service_role;
