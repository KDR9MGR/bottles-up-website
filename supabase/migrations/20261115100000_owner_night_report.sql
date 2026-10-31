-- The owner's consolidated nightly report (client Phase 2 brief, section 27 "Owner: individual owned venues and consolidated performance", section 5 "Combined totals must not
-- double-count ... Never sum unlike currencies without an explicitly designed conversion method; show currency labels", and scenario 1 "Owner adds two clubs: separate
-- staff/stock/reports and correct consolidated overview").
--
-- owner_night_report(org, night): for ONE business night, each club of the business with its own nightly report exactly as that club's manager and the owner see it
-- (night_report: FINAL, the figures kept at the close, once the night is closed; otherwise PRELIMINARY, worked out now), plus totals across the clubs.
--   * READ-ONLY, for the OWNER of the business only. A manager has their own club's report; another business's owner, a server and a stranger are refused; a visitor cannot call it.
--   * Nothing is counted twice: a booking belongs to one club, and each club's report is taken once. Organizers' event figures are not in it.
--   * Currencies: if every paid booking of the night is in one currency the totals carry its label ("CAD"); if the clubs sold in more than one, NO total is made (currency_mixed
--     is true and the currencies are listed), because adding dollars to pounds would be wrong. The clubs' own reports are still returned.
--   * The totals say how many clubs are final, so a combined figure is never mistaken for a closed one.
--
-- A new function: nothing existing is replaced and no row is changed. Needs the close-night (20261018140000) and tenancy migrations.

do $guard$
begin
  if to_regprocedure('public.night_report(uuid, date)') is null then
    raise exception 'public.night_report(uuid, date) does not exist: run the close-night migration (20261018140000) first. Nothing was changed.';
  end if;
  if to_regprocedure('public.night_booking_ids(uuid, date)') is null then
    raise exception 'public.night_booking_ids(uuid, date) does not exist: run the close-night migration (20261018140000) first. Nothing was changed.';
  end if;
end $guard$;

create function public.owner_night_report(p_org uuid, p_night date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v record;
  v_venues jsonb := '[]'::jsonb;
  v_vc text[];
  v_all text[] := '{}'::text[];
  v_currencies text[];
  v_mixed boolean;
  v_totals jsonb := null;
  v_org_name text;
  v_final int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_org is null or not public.is_org_member(p_org, array['owner']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;

  select o.name into v_org_name from public.site_organizations o where o.id = p_org;

  -- Each club's report, as the database gives it to its owner. The owner reaches every club of the business, so night_report answers 'full' for each.
  -- Each club also says which currencies its own paid bookings of the night are in, so an amount is never shown under another club's label.
  for v in select cv.id, cv.name from public.site_venues cv where cv.org_id = p_org order by lower(cv.name), cv.id loop
    select coalesce(array_agg(distinct lower(coalesce(nullif(btrim(b.currency), ''), 'cad')) order by lower(coalesce(nullif(btrim(b.currency), ''), 'cad'))), '{}'::text[])
      into v_vc
    from public.night_booking_ids(v.id, p_night) n
    join public.site_table_bookings b on b.id = n.id;
    v_all := v_all || v_vc;
    v_venues := v_venues || jsonb_build_array(jsonb_build_object(
      'venue_id', v.id,
      'venue_name', v.name,
      'currencies', to_jsonb(v_vc),
      'report', public.night_report(v.id, p_night)));
  end loop;

  select count(*) filter (where coalesce((e #>> '{report,final}')::boolean, false)) into v_final from jsonb_array_elements(v_venues) e;

  -- Which currencies the night's paid bookings are in, over every club of the business.
  select coalesce(array_agg(distinct c order by c), '{}'::text[]) into v_currencies from unnest(v_all) c;
  v_mixed := coalesce(cardinality(v_currencies), 0) > 1;

  if not v_mixed then
    select jsonb_build_object(
      'tables', coalesce(sum(coalesce((e #>> '{report,bookings,count}')::bigint, 0)), 0),
      'guests', coalesce(sum(coalesce((e #>> '{report,bookings,guests}')::bigint, 0)), 0),
      'seated', coalesce(sum(coalesce((e #>> '{report,bookings,seated}')::bigint, 0)), 0),
      'booked_cents', coalesce(sum(coalesce((e #>> '{report,bookings,total_cents}')::bigint, 0)), 0),
      'paid_cents', coalesce(sum(coalesce((e #>> '{report,bookings,paid_cents}')::bigint, 0)), 0),
      'balance_cents', coalesce(sum(coalesce((e #>> '{report,bookings,balance_cents}')::bigint, 0)), 0),
      'discount_cents', coalesce(sum(coalesce((e #>> '{report,bookings,discount_cents}')::bigint, 0)), 0),
      'payments', coalesce(sum(coalesce((e #>> '{report,payments,count}')::bigint, 0)), 0),
      'collected_cents', coalesce(sum(coalesce((e #>> '{report,payments,collected_cents}')::bigint, 0)), 0),
      'cash_cents', coalesce(sum(coalesce((e #>> '{report,payments,cash_cents}')::bigint, 0)), 0),
      'card_cents', coalesce(sum(coalesce((e #>> '{report,payments,debit_cents}')::bigint, 0) + coalesce((e #>> '{report,payments,credit_cents}')::bigint, 0)
                                   + coalesce((e #>> '{report,payments,split_card_cents}')::bigint, 0)), 0),
      'unverified', coalesce(sum(coalesce((e #>> '{report,payments,unverified}')::bigint, 0)), 0),
      'disputed', coalesce(sum(coalesce((e #>> '{report,payments,disputed}')::bigint, 0)), 0),
      'no_receipt', coalesce(sum(coalesce((e #>> '{report,payments,no_receipt}')::bigint, 0)), 0),
      'bottle_lines', coalesce(sum(coalesce((e #>> '{report,bottles,lines}')::bigint, 0)), 0),
      'bottle_value_cents', coalesce(sum(coalesce((e #>> '{report,bottles,value_cents}')::bigint, 0)), 0),
      'bottles_served', coalesce(sum(coalesce((e #>> '{report,bottles,served}')::bigint, 0)), 0),
      'cash_counted_cents', coalesce(sum(coalesce((e #>> '{report,cash,counted_cents}')::bigint, 0)), 0),
      'shortage_cents', coalesce(sum(coalesce((e #>> '{report,cash,shortage_cents}')::bigint, 0)), 0),
      'overage_cents', coalesce(sum(coalesce((e #>> '{report,cash,overage_cents}')::bigint, 0)), 0),
      'held_cents', coalesce(sum(coalesce((e #>> '{report,cash,held_cents}')::bigint, 0)), 0),
      'flags_open', coalesce(sum(coalesce((e #>> '{report,flags,open}')::bigint, 0)), 0),
      'requests_open', coalesce(sum(coalesce((e #>> '{report,service,open}')::bigint, 0)), 0),
      'alerts_unresolved', coalesce(sum(coalesce((e #>> '{report,security,alerts,unresolved}')::bigint, 0)), 0),
      'closed_with_exceptions', coalesce(sum(case when coalesce((e #>> '{report,final}')::boolean, false) and jsonb_array_length(coalesce(e #> '{report,exceptions}', '[]'::jsonb)) > 0 then 1 else 0 end), 0))
    into v_totals
    from jsonb_array_elements(v_venues) e;
  end if;

  return jsonb_build_object(
    'org_name', v_org_name,
    'business_night', p_night,
    'generated_at', clock_timestamp(),
    'venues_total', jsonb_array_length(v_venues),
    'venues_final', v_final,
    'currency', case when v_mixed then null else upper(coalesce(v_currencies[1], 'cad')) end,
    'currency_mixed', v_mixed,
    'currencies', to_jsonb(v_currencies),
    'totals', v_totals,
    'venues', v_venues);
end;
$$;

revoke all on function public.owner_night_report(uuid, date) from public, anon;
grant execute on function public.owner_night_report(uuid, date) to authenticated, service_role;
