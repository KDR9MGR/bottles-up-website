-- The owner's Money tab (client Phase 2 brief, sections 5 and 27: "Collections, outstanding balances", per-venue figures for a business).
--
-- One row per club of the business for a range of business nights: tables and guests, what was booked, paid so far and still due, what was
-- collected at the club in cash and by card, cash shortages and overages from counted handovers, payments still flagged, and how many
-- nights were closed. The figures are the same ones the nightly report uses (a correction replaces the payment it corrects, so each payment
-- counts once; a night is the club's business night). READ-ONLY, for the OWNER of the business only: a manager sees their own club through
-- the nightly report, and nobody else sees a business's totals.
-- A range is at most 62 nights. Plain CREATE, never CREATE OR REPLACE. Needs the table service, cash, close-night migrations.

create function public.owner_money(p_org uuid, p_from date, p_to date)
returns table (
  venue_id uuid, venue_name text, tables int, guests int, booked_cents bigint, paid_cents bigint, balance_cents bigint,
  cash_cents bigint, card_cents bigint, shortage_cents bigint, overage_cents bigint, flags_open int, nights_closed int
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_org is null or not public.is_org_member(p_org, array['owner']) then raise exception 'not allowed'; end if;
  if p_from is null or p_to is null then raise exception 'choose the nights'; end if;
  if p_to < p_from then raise exception 'the last night is before the first'; end if;
  if p_to - p_from > 61 then raise exception 'choose at most 62 nights'; end if;

  return query
    select v.id, v.name,
           coalesce(b.tables, 0), coalesce(b.guests, 0), coalesce(b.booked, 0), coalesce(b.paid, 0), coalesce(b.balance, 0),
           coalesce(p.cash, 0), coalesce(p.card, 0),
           coalesce(h.shortage, 0), coalesce(h.overage, 0), coalesce(f.open_flags, 0), coalesce(c.closed, 0)
    from public.site_venues v
    left join lateral (
      select count(*)::int as tables, coalesce(sum(x.guest_count), 0)::int as guests, coalesce(sum(x.amount_total_cents), 0)::bigint as booked,
             coalesce(sum(x.amount_paid_cents), 0)::bigint as paid, coalesce(sum(greatest(x.amount_total_cents - x.amount_paid_cents, 0)), 0)::bigint as balance
      from (
        select bk.* from public.site_table_bookings bk
        join public.site_venue_time_slots s on s.id = bk.time_slot_id
        where bk.venue_id = v.id and bk.status = 'paid' and bk.booking_date between p_from and p_to + 1
          and public.booking_night(bk.booking_date, s.start_time) between p_from and p_to
      ) x
    ) b on true
    left join lateral (
      select coalesce(sum(public.desk_cash_part(cp.payment_method, cp.amount_paid_cents, cp.split_breakdown)), 0)::bigint as cash,
             coalesce(sum(cp.amount_paid_cents - public.desk_cash_part(cp.payment_method, cp.amount_paid_cents, cp.split_breakdown)), 0)::bigint as card
      from public.site_table_booking_club_payments cp
      join public.site_table_bookings bk on bk.id = cp.booking_id
      join public.site_venue_time_slots s on s.id = bk.time_slot_id
      where bk.venue_id = v.id and bk.status = 'paid' and bk.booking_date between p_from and p_to + 1
        and public.booking_night(bk.booking_date, s.start_time) between p_from and p_to
        and not exists (select 1 from public.site_table_booking_club_payments c2 where c2.corrects_payment_id = cp.id)
    ) p on true
    left join lateral (
      select coalesce(sum(hh.claimed_cents - hh.counted_cents) filter (where hh.counted_cents < hh.claimed_cents), 0)::bigint as shortage,
             coalesce(sum(hh.counted_cents - hh.claimed_cents) filter (where hh.counted_cents > hh.claimed_cents), 0)::bigint as overage
      from public.site_cash_handovers hh
      where hh.venue_id = v.id and hh.status = 'acknowledged' and hh.business_night between p_from and p_to
    ) h on true
    left join lateral (
      select count(*)::int as open_flags
      from public.site_payment_flags fl
      join public.site_table_booking_club_payments cp on cp.id = fl.payment_id
      join public.site_table_bookings bk on bk.id = cp.booking_id
      join public.site_venue_time_slots s on s.id = bk.time_slot_id
      where fl.venue_id = v.id and fl.status = 'open' and bk.booking_date between p_from and p_to + 1
        and public.booking_night(bk.booking_date, s.start_time) between p_from and p_to
    ) f on true
    left join lateral (
      select count(*)::int as closed from public.site_night_closes nc where nc.venue_id = v.id and nc.status = 'closed' and nc.business_night between p_from and p_to
    ) c on true
    where v.org_id = p_org
    order by lower(v.name), v.id;
end;
$$;

revoke all on function public.owner_money(uuid, date, date) from public, anon;
grant execute on function public.owner_money(uuid, date, date) to authenticated, service_role;
