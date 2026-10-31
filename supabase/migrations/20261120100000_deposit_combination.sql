-- An explicit combination for a venue's deposit (client Phase 2 brief, section 9 "Table-payment and admission configuration": "Support: no upfront charge; separate reservation charge;
-- minimum-spend credit; room-admission payment; explicit combination ... Combined allocations must sum to the payment and cannot give the same money two credits ... Admission-only
-- money does not become bottle credit unless explicitly allocated that way ... Snapshot accepted booking terms so later defaults do not rewrite existing bookings"; scenario 5
-- "Upfront charge alternatives: separate fee, spend credit, admission-only and split examples calculate correctly").
--
-- Until now a venue's deposit had ONE purpose (reservation fee, minimum-spend credit or admission). A combination splits it into the three shares, in whole percents that add up to 100:
--   reservation_fee_pct         kept as a charge of its own; never counts toward the bottle bill
--   minimum_spend_credit_pct    counts toward the bottle bill (the minimum spend), and ONLY this share does
--   admission_pct               pays for the admissions the table includes; never counts toward the bottle bill
-- Because the shares add up to exactly 100 and only one of them is a credit, no money is credited twice and none is left unaccounted for. In cents the credit and the admission are
-- worked out by rounding DOWN and the reservation fee takes the remainder, so the credit is never more than its share (website: supabase/functions/_shared/depositAllocation.ts).
--
-- It is stored where the other deposit terms are: site_venues.deposit_terms = {recipient, venue_pct, purpose: 'combination', parts: {reservation_fee_pct, minimum_spend_credit_pct,
-- admission_pct}}. Every new booking already copies the venue's terms when it is made (site_table_bookings_snapshot_terms, 20261021100000), so the parts travel with the booking and a
-- later change never rewrites a booking that exists.
--
-- The credit still follows BottlesUp's switch (site_venues.deposit_is_credit, owned by the BottlesUp team): a share above 0 for the credit needs it on, and with it on the credit share must
-- be above 0, the same agreement the single purposes already have.
--
-- One new function; nothing existing is replaced and no row is changed. The single-purpose function (save_venue_deposit_terms) is untouched. Needs the floor plan and table states
-- migration (20261021100000).

do $guard$
declare
  fn text;
begin
  foreach fn in array array['public.require_venue_editor(uuid)', 'public.setup_only_keys(jsonb, text[])', 'public.setup_text(jsonb, text, text, int)', 'public.setup_int(jsonb, text, text, int, int)',
                            'public.venue_setup_log(text, text, uuid, uuid, jsonb)', 'public.save_venue_deposit_terms(uuid, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception '% does not exist: run the floor plan and table states migration (20261021100000) first. Nothing was changed.', fn;
    end if;
  end loop;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_venues' and column_name = 'deposit_terms') then
    raise exception 'site_venues.deposit_terms must exist first (20261021100000). Nothing was changed.';
  end if;
end $guard$;

create function public.save_venue_deposit_combination(p_venue uuid, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recipient text;
  v_pct int;
  v_fee int;
  v_credit_pct int;
  v_adm int;
  v_credit boolean;
  v_old jsonb;
  v_new jsonb;
begin
  perform public.require_venue_editor(p_venue);
  perform public.setup_only_keys(p_details, array['recipient', 'venue_pct', 'reservation_fee_pct', 'minimum_spend_credit_pct', 'admission_pct']);

  v_recipient := public.setup_text(p_details, 'recipient', 'recipient', 20);
  v_pct := public.setup_int(p_details, 'venue_pct', 'the venue''s share', 0, 100);
  v_fee := public.setup_int(p_details, 'reservation_fee_pct', 'the reservation fee share', 0, 100);
  v_credit_pct := public.setup_int(p_details, 'minimum_spend_credit_pct', 'the minimum spend credit share', 0, 100);
  v_adm := public.setup_int(p_details, 'admission_pct', 'the admission share', 0, 100);

  if v_recipient is null or v_recipient not in ('venue', 'organizer', 'split') then raise exception 'choose who receives the deposit: the venue, the approved organizer, or a split'; end if;
  if v_recipient = 'venue' then
    if v_pct is not null and v_pct <> 100 then raise exception 'when the venue keeps the deposit its share is 100 percent'; end if;
    v_pct := 100;
  elsif v_recipient = 'organizer' then
    if v_pct is not null and v_pct <> 0 then raise exception 'when the organizer receives the deposit the venue''s share is 0 percent'; end if;
    v_pct := 0;
  else
    if v_pct is null or v_pct < 1 or v_pct > 99 then raise exception 'for a split give the venue''s share between 1 and 99 percent (the organizer gets the rest, so the two add up to 100)'; end if;
  end if;

  if v_fee is null or v_credit_pct is null or v_adm is null then raise exception 'give a share for each of the three: the reservation fee, the minimum spend credit and admission (0 for none)'; end if;
  if v_fee + v_credit_pct + v_adm <> 100 then raise exception 'the three shares have to add up to 100 percent (they add up to % percent)', v_fee + v_credit_pct + v_adm; end if;
  if (case when v_fee > 0 then 1 else 0 end) + (case when v_credit_pct > 0 then 1 else 0 end) + (case when v_adm > 0 then 1 else 0 end) < 2 then
    raise exception 'a combination needs at least two of the three shares above 0; for a single purpose choose it on its own';
  end if;

  select v.deposit_is_credit, v.deposit_terms into v_credit, v_old from public.site_venues v where v.id = p_venue for update;
  if not found then raise exception 'not allowed'; end if;
  -- the credit switch is owned by BottlesUp (bookings are worked out with it), so the credit share has to agree with it
  if v_credit_pct > 0 and not v_credit then
    raise exception 'part of the deposit would be a credit toward the bottle bill, but that is not switched on for this venue; give the credit share as 0, or ask the BottlesUp team to switch the credit on';
  end if;
  if v_credit_pct = 0 and v_credit then
    raise exception 'the deposit is credited toward the bottle bill at this venue, so a combination needs a credit share above 0; ask the BottlesUp team if that should change';
  end if;

  v_new := jsonb_build_object('recipient', v_recipient, 'venue_pct', v_pct, 'purpose', 'combination',
    'parts', jsonb_build_object('reservation_fee_pct', v_fee, 'minimum_spend_credit_pct', v_credit_pct, 'admission_pct', v_adm));
  if v_old is not distinct from v_new then return v_new; end if;
  update public.site_venues set deposit_terms = v_new where id = p_venue;
  perform public.venue_setup_log('venue.deposit_terms_saved', 'site_venues', p_venue, p_venue, jsonb_build_object('from', v_old, 'to', v_new));
  return v_new;
end;
$$;

revoke all on function public.save_venue_deposit_combination(uuid, jsonb) from public, anon;
grant execute on function public.save_venue_deposit_combination(uuid, jsonb) to authenticated, service_role;
