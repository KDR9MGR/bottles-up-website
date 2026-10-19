-- The organizer's Guests tab (client Phase 2 brief, section 7: "Guest lists, invitations and passes for your events"): who bought tickets
-- to the organizer's own events and how check-in is going. READ-ONLY.
--
--   * Only the owner and organizers of the business that owns the event. Not the clubs, not event door staff (who have the door's own search),
--     not other businesses.
--   * Paid orders only. A name or ticket code comes back for each order; NO email address, phone number or payment detail does.
--   * Without a search at most 100 come back (newest first); with one, at most 50. The counts are exact, whatever the list shows.
--   * Sending invitations and issuing extra passes are website features that are not part of this.
-- Plain CREATE, never CREATE OR REPLACE. Needs the tenancy and door scanner migrations.

create function public.organizer_guest_summary(p_event uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_event is null or not public.can_access_event(p_event, array['owner', 'organizer']) then raise exception 'not allowed'; end if;

  return jsonb_build_object(
    'orders', (select count(*)::int from public.site_orders o where o.event_id = p_event and o.status = 'paid'),
    'tickets_sold', (select coalesce(sum(o.quantity), 0)::int from public.site_orders o where o.event_id = p_event and o.status = 'paid'),
    'checked_in', (select coalesce(sum(o.quantity), 0)::int from public.site_orders o where o.event_id = p_event and o.status = 'paid' and o.checked_in_at is not null),
    'by_tier', coalesce((
      select jsonb_agg(jsonb_build_object('tier', t.name, 'sold', t.sold, 'checked_in', t.checked_in) order by t.name)
      from (
        select tt.name, coalesce(sum(o.quantity), 0)::int as sold, coalesce(sum(o.quantity) filter (where o.checked_in_at is not null), 0)::int as checked_in
        from public.site_ticket_tiers tt
        left join public.site_orders o on o.tier_id = tt.id and o.event_id = p_event and o.status = 'paid'
        where tt.event_id = p_event
        group by tt.name
      ) t), '[]'::jsonb));
end;
$$;

create function public.organizer_guests(p_event uuid, p_query text default null)
returns table (order_id uuid, customer_name text, ticket_code text, tier_name text, quantity int, checked_in_at timestamptz, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_q text := nullif(btrim(p_query), '');
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_event is null or not public.can_access_event(p_event, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  if v_q is not null and char_length(v_q) < 2 then raise exception 'type at least 2 characters to search'; end if;
  if v_q is not null then v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_'); end if;

  return query
    select o.id, o.customer_name, o.ticket_code, t.name, o.quantity, o.checked_in_at, o.created_at
    from public.site_orders o
    left join public.site_ticket_tiers t on t.id = o.tier_id
    where o.event_id = p_event and o.status = 'paid'
      and (v_q is null or o.customer_name ilike '%' || v_q || '%' or coalesce(o.ticket_code, '') ilike '%' || v_q || '%')
    order by case when v_q is null then null else lower(o.customer_name) end, o.created_at desc, o.id
    limit case when v_q is null then 100 else 50 end;
end;
$$;

revoke all on function public.organizer_guest_summary(uuid), public.organizer_guests(uuid, text) from public, anon;
grant execute on function public.organizer_guest_summary(uuid), public.organizer_guests(uuid, text) to authenticated, service_role;
