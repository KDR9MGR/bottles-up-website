-- Explore, venue facts and reviews (customer app completion plan, M3; client plan pages 6 and 14).
--
--   * VENUE FACTS the plan asks for and the database lacked: amenities, parking, age and ID rules, last entry, kitchen hours, a menu link. They are plain columns of
--     site_venues (so they travel with the venue the apps already read) and are changed only through save_venue_facts(), by the venue's owner or manager.
--   * REVIEWS of a venue or an event are by a person (never a business profile) who actually went: a paid table booking at the venue on a night that is over, or a paid
--     ticket to an event that is over (a ticket to an event at that venue counts for the venue too), matched by the signed-in e-mail address. One review per person per
--     venue / event; they may change or delete it. The venue's own profile (its owner or manager) may reply once to each review. Text goes through the banned-terms check; a
--     person is slowed to 10 reviews a day. Reviews refuse until the `reviews` switch is on. Reading is open to any signed-in profile; a blocked pair do not see each other's.
--   * EXPLORE: "what's hot" is counted from what really happened in the last two weeks (paid table bookings, paid tickets, public posts tagged with the venue or event),
--     and only the order and a score are returned, never anyone's booking. A directory of professionals (DJs, photographers...) by category, city and name.
--
-- Reached only through the functions below; the new tables cannot be read or written by a client. Plain CREATE, never CREATE OR REPLACE; the new columns are additive.

-- ---------------------------------------------------------------------------
-- 1. Venue facts
-- ---------------------------------------------------------------------------
alter table public.site_venues
  add column amenities text[] not null default '{}',
  add column parking_info text,
  add column min_age smallint,
  add column id_required boolean not null default false,
  add column last_entry text,
  add column kitchen_hours text,
  add column menu_url text;

alter table public.site_venues
  add constraint site_venues_amenities_known check (
    amenities <@ array['parking', 'valet', 'coat_check', 'wifi', 'accessible', 'outdoor', 'vip_area', 'food', 'smoking_area', 'private_rooms', 'live_music', 'dance_floor', 'bottle_service']::text[]
  ),
  add constraint site_venues_facts_lengths check (
    (parking_info is null or char_length(parking_info) <= 300)
    and (last_entry is null or char_length(last_entry) <= 40)
    and (kitchen_hours is null or char_length(kitchen_hours) <= 100)
    and (menu_url is null or (menu_url ~ '^https://' and char_length(menu_url) <= 500))
    and (min_age is null or min_age between 13 and 25)
  );

-- The venue's owner or manager sets the facts customers see. Every field is replaced (a form saves them all); an empty text clears it.
create function public.save_venue_facts(
  p_venue uuid,
  p_amenities text[],
  p_parking text,
  p_min_age int,
  p_id_required boolean,
  p_last_entry text,
  p_kitchen_hours text,
  p_menu_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amenities text[];
  v_parking text := nullif(btrim(coalesce(p_parking, '')), '');
  v_last text := nullif(btrim(coalesce(p_last_entry, '')), '');
  v_kitchen text := nullif(btrim(coalesce(p_kitchen_hours, '')), '');
  v_menu text := nullif(btrim(coalesce(p_menu_url, '')), '');
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then
    raise exception 'You can only change the details of a venue you own or manage.';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_amenities from unnest(coalesce(p_amenities, '{}')) x;
  if not (v_amenities <@ array['parking', 'valet', 'coat_check', 'wifi', 'accessible', 'outdoor', 'vip_area', 'food', 'smoking_area', 'private_rooms', 'live_music', 'dance_floor', 'bottle_service']::text[]) then
    raise exception 'One of those features is not one we know.';
  end if;
  if v_parking is not null and char_length(v_parking) > 300 then raise exception 'The parking note can be 300 characters at most.'; end if;
  if v_last is not null and char_length(v_last) > 40 then raise exception 'Last entry can be 40 characters at most.'; end if;
  if v_kitchen is not null and char_length(v_kitchen) > 100 then raise exception 'Kitchen hours can be 100 characters at most.'; end if;
  if v_menu is not null and (v_menu !~ '^https://' or char_length(v_menu) > 500) then raise exception 'The menu link must start with https://.'; end if;
  if p_min_age is not null and p_min_age not between 13 and 25 then raise exception 'The minimum age must be between 13 and 25.'; end if;
  if p_id_required is null then raise exception 'Say whether ID is required.'; end if;

  update public.site_venues set
    amenities = v_amenities, parking_info = v_parking, min_age = p_min_age, id_required = p_id_required,
    last_entry = v_last, kitchen_hours = v_kitchen, menu_url = v_menu
  where id = p_venue;
  perform public.venue_setup_log('venue_facts_saved', 'venue', p_venue, p_venue, jsonb_build_object('amenities', v_amenities));
  return jsonb_build_object('amenities', v_amenities, 'parking_info', v_parking, 'min_age', p_min_age, 'id_required', p_id_required,
                            'last_entry', v_last, 'kitchen_hours', v_kitchen, 'menu_url', v_menu);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Reviews
-- ---------------------------------------------------------------------------
create table public.site_reviews (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('venue', 'event')),
  venue_id uuid references public.site_venues (id) on delete cascade,
  event_id uuid references public.site_events (id) on delete cascade,
  author uuid not null references public.site_profiles (id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  body text check (body is null or char_length(btrim(body)) between 1 and 1000),
  status text not null default 'active' check (status in ('active', 'removed')),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint site_reviews_target check ((kind = 'venue' and venue_id is not null and event_id is null) or (kind = 'event' and event_id is not null and venue_id is null))
);
create unique index site_reviews_one_per_venue on public.site_reviews (author, venue_id) where venue_id is not null;
create unique index site_reviews_one_per_event on public.site_reviews (author, event_id) where event_id is not null;
create index site_reviews_venue_idx on public.site_reviews (venue_id, created_at desc, id desc) where venue_id is not null and status = 'active';
create index site_reviews_event_idx on public.site_reviews (event_id, created_at desc, id desc) where event_id is not null and status = 'active';

create table public.site_review_replies (
  review uuid primary key references public.site_reviews (id) on delete cascade,
  author uuid not null references public.site_profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default clock_timestamp()
);

alter table public.site_reviews enable row level security;
alter table public.site_review_replies enable row level security;
revoke all on table public.site_reviews, public.site_review_replies from public, anon, authenticated;

-- Has the signed-in person been to this venue (a paid table booking on a night that is over, or a paid ticket to a finished event there) or to this event?
create function public.review_visited(p_kind text, p_target uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.email(), ''));
begin
  if v_email = '' then return false; end if;
  if p_kind = 'venue' then
    return exists (
      select 1 from public.site_table_bookings b
      join public.site_venues v on v.id = b.venue_id
      where b.venue_id = p_target and b.status = 'paid' and lower(b.customer_email) = v_email
        and b.booking_date < (now() at time zone coalesce(nullif(v.time_zone, ''), 'UTC'))::date
    ) or exists (
      select 1 from public.site_orders o
      join public.site_events e on e.id = o.event_id
      where e.venue_id = p_target and o.status = 'paid' and lower(o.customer_email) = v_email and coalesce(e.end_date, e.start_date) < now()
    );
  elsif p_kind = 'event' then
    return exists (
      select 1 from public.site_orders o
      join public.site_events e on e.id = o.event_id
      where o.event_id = p_target and o.status = 'paid' and lower(o.customer_email) = v_email and coalesce(e.end_date, e.start_date) < now()
    );
  end if;
  return false;
end;
$$;

-- May this profile review this venue or event right now? Answers {eligible, reason, mine} where mine is the review it already wrote (to edit).
create function public.review_eligibility(p_actor uuid, p_kind text, p_target uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mine uuid;
begin
  perform public.profile_require_actor(p_actor);
  if p_kind not in ('venue', 'event') or p_target is null then raise exception 'Choose a venue or an event.'; end if;
  if p_kind = 'venue' then
    select r.id into v_mine from public.site_reviews r where r.author = p_actor and r.venue_id = p_target;
  else
    select r.id into v_mine from public.site_reviews r where r.author = p_actor and r.event_id = p_target;
  end if;
  if not public.feature_enabled('reviews') then return jsonb_build_object('eligible', false, 'reason', 'Reviews are not open yet.', 'mine', v_mine); end if;
  if exists (select 1 from public.site_profiles s where s.id = p_actor and s.kind = 'business') then
    return jsonb_build_object('eligible', false, 'reason', 'Only a person''s own profile can write a review.', 'mine', v_mine);
  end if;
  if not public.review_visited(p_kind, p_target) then
    return jsonb_build_object('eligible', false,
      'reason', case p_kind when 'venue' then 'You can review a venue after a night you booked there.' else 'You can review an event after you went to it.' end,
      'mine', v_mine);
  end if;
  return jsonb_build_object('eligible', true, 'reason', null, 'mine', v_mine);
end;
$$;

-- Write a review, or change the one already written for this venue / event.
create function public.review_save(p_actor uuid, p_kind text, p_target uuid, p_rating int, p_body text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
  v_elig jsonb;
  v_id uuid;
begin
  perform public.profile_require_actor(p_actor);
  v_elig := public.review_eligibility(p_actor, p_kind, p_target);
  if (v_elig ->> 'eligible')::boolean is not true then raise exception '%', v_elig ->> 'reason'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose 1 to 5 stars.'; end if;
  if v_body is not null and char_length(v_body) > 1000 then raise exception 'A review can be 1000 characters at most.'; end if;
  if not public.social_text_ok(v_body) then raise exception 'That text goes against our community rules.'; end if;
  if (v_elig ->> 'mine') is null
     and (select count(*) from public.site_reviews r where r.author = p_actor and r.created_at > now() - interval '1 day') >= 10 then
    raise exception 'You are writing reviews too quickly. Try again later.';
  end if;

  if (v_elig ->> 'mine') is not null then
    update public.site_reviews set rating = p_rating, body = v_body, updated_at = clock_timestamp() where id = (v_elig ->> 'mine')::uuid returning id into v_id;
  else
    insert into public.site_reviews (kind, venue_id, event_id, author, rating, body)
    values (p_kind, case when p_kind = 'venue' then p_target end, case when p_kind = 'event' then p_target end, p_actor, p_rating, v_body)
    returning id into v_id;
  end if;
  return public.review_card(p_actor, v_id);
end;
$$;

create function public.review_delete(p_actor uuid, p_review uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
begin
  perform public.profile_require_actor(p_actor);
  select r.author into v_author from public.site_reviews r where r.id = p_review;
  if v_author is null or not public.profile_can_act_as(v_author) then raise exception 'You can only delete your own reviews.'; end if;
  delete from public.site_reviews where id = p_review;
  return jsonb_build_object('deleted', true);
end;
$$;

-- Who may answer a review: the venue's own profile (its owner or manager), or the profile of the business that runs the event.
create function public.review_can_reply(p_actor uuid, p_review uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.profile_can_act_as(p_actor)
     and exists (
       select 1
       from public.site_reviews r
       join public.site_profiles me on me.id = p_actor and me.kind = 'business'
       left join public.site_events e on e.id = r.event_id
       where r.id = p_review
         and ((r.venue_id is not null and me.venue_id = r.venue_id) or (r.event_id is not null and me.org_id is not null and me.venue_id is null and me.org_id = e.org_id))
     )
$$;

create function public.review_reply(p_actor uuid, p_review uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body text := btrim(coalesce(p_body, ''));
begin
  perform public.profile_require_actor(p_actor);
  if not public.feature_enabled('reviews') then raise exception 'Reviews are not open yet.'; end if;
  if not public.review_can_reply(p_actor, p_review) then raise exception 'Only the venue or the organizer it is about can reply.'; end if;
  if char_length(v_body) < 1 then raise exception 'Write something first.'; end if;
  if char_length(v_body) > 1000 then raise exception 'A reply can be 1000 characters at most.'; end if;
  if not public.social_text_ok(v_body) then raise exception 'That text goes against our community rules.'; end if;
  insert into public.site_review_replies (review, author, body) values (p_review, p_actor, v_body)
  on conflict (review) do update set author = excluded.author, body = excluded.body;
  return public.review_card(p_actor, p_review);
end;
$$;

create function public.review_reply_delete(p_actor uuid, p_review uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if not public.review_can_reply(p_actor, p_review) then raise exception 'Only the venue or the organizer it is about can reply.'; end if;
  delete from public.site_review_replies where review = p_review;
  return jsonb_build_object('deleted', true);
end;
$$;

-- One review as the app shows it.
create function public.review_card(p_viewer uuid, p_review uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', r.id,
    'kind', r.kind,
    'venue_id', r.venue_id,
    'event_id', r.event_id,
    'rating', r.rating,
    'body', r.body,
    'created_at', r.created_at,
    'updated_at', r.updated_at,
    'author', public.profile_mini(r.author),
    'is_mine', public.profile_is_mine(r.author),
    'can_reply', public.review_can_reply(p_viewer, r.id),
    'reply', (select jsonb_build_object('body', y.body, 'created_at', y.created_at, 'author', public.profile_mini(y.author))
              from public.site_review_replies y where y.review = r.id)
  )
  from public.site_reviews r
  where r.id = p_review
$$;

-- The average, the count and how many of each star, for one venue or event. Counted over reviews by profiles in good standing.
create function public.review_summary(p_kind text, p_target uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'count', count(*),
    'average', coalesce(round(avg(r.rating)::numeric, 1), 0),
    'stars', jsonb_build_array(
      count(*) filter (where r.rating = 1), count(*) filter (where r.rating = 2), count(*) filter (where r.rating = 3),
      count(*) filter (where r.rating = 4), count(*) filter (where r.rating = 5))
  )
  from public.site_reviews r
  join public.site_profiles s on s.id = r.author and s.status = 'active'
  where r.status = 'active' and r.kind = p_kind and ((p_kind = 'venue' and r.venue_id = p_target) or (p_kind = 'event' and r.event_id = p_target))
$$;

-- A page of reviews (newest first) with the summary. p_before / p_before_id are the created_at and id of the last review seen.
create function public.reviews_list(p_actor uuid, p_kind text, p_target uuid, p_limit int default 20, p_before timestamptz default null, p_before_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  perform public.profile_require_actor(p_actor);
  if p_kind not in ('venue', 'event') or p_target is null then raise exception 'Choose a venue or an event.'; end if;
  return jsonb_build_object(
    'summary', public.review_summary(p_kind, p_target),
    'items', coalesce((
      select jsonb_agg(public.review_card(p_actor, x.id) order by x.created_at desc, x.id desc)
      from (
        select r.id, r.created_at
        from public.site_reviews r
        join public.site_profiles s on s.id = r.author and s.status = 'active'
        where r.status = 'active' and r.kind = p_kind
          and ((p_kind = 'venue' and r.venue_id = p_target) or (p_kind = 'event' and r.event_id = p_target))
          and not public.profile_blocked_between(p_actor, r.author)
          and (p_before is null or (r.created_at, r.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
        order by r.created_at desc, r.id desc
        limit v_limit
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

-- Average and count for many venues at once, for a list of venue cards. Open to visitors; it holds nothing but the two numbers. Empty while reviews are off.
create function public.venue_ratings(p_venues uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when not public.feature_enabled('reviews') then '{}'::jsonb else coalesce((
    select jsonb_object_agg(g.venue_id, jsonb_build_object('count', g.n, 'average', g.avg))
    from (
      select r.venue_id, count(*) as n, round(avg(r.rating)::numeric, 1) as avg
      from public.site_reviews r
      join public.site_profiles s on s.id = r.author and s.status = 'active'
      where r.status = 'active' and r.kind = 'venue' and r.venue_id = any (coalesce(p_venues, '{}'::uuid[]))
      group by r.venue_id
    ) g
  ), '{}'::jsonb) end
$$;

-- ---------------------------------------------------------------------------
-- 3. Explore
-- ---------------------------------------------------------------------------
-- The venues with the most going on, busiest first: 3 points for each paid table booking made in the last 14 days, 1 for each paid ticket to an event there, 2 for each
-- public post tagged with the venue. Only published venues; only the id and the score are answered. Open to visitors (the venues themselves are public).
create function public.explore_hot_venues(p_limit int default 10)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'score', h.score) order by h.score desc, h.id), '[]'::jsonb)
  from (
    select v.id,
           3 * (select count(*) from public.site_table_bookings b where b.venue_id = v.id and b.status = 'paid' and b.created_at > now() - interval '14 days')
         + (select count(*) from public.site_orders o join public.site_events e on e.id = o.event_id where e.venue_id = v.id and o.status = 'paid' and o.created_at > now() - interval '14 days')
         + 2 * (select count(*) from public.site_post_tags t join public.site_posts p on p.id = t.post join public.site_profiles a on a.id = p.author
                where t.venue_id = v.id and p.status = 'active' and p.audience = 'public' and p.kind <> 'story' and a.status = 'active' and a.privacy = 'public'
                  and p.created_at > now() - interval '14 days') as score
    from public.site_venues v
    where v.status = 'published'
    order by score desc, v.id
    limit least(greatest(coalesce(p_limit, 10), 1), 30)
  ) h
  where h.score > 0
$$;

-- The same for upcoming events: 2 points for each paid ticket order in the last 7 days, 2 for each public post tagged with it, 3 more when it starts within a week.
create function public.explore_hot_events(p_limit int default 10)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'score', h.score) order by h.score desc, h.id), '[]'::jsonb)
  from (
    select e.id,
           2 * (select count(*) from public.site_orders o where o.event_id = e.id and o.status = 'paid' and o.created_at > now() - interval '7 days')
         + 2 * (select count(*) from public.site_post_tags t join public.site_posts p on p.id = t.post join public.site_profiles a on a.id = p.author
                where t.event_id = e.id and p.status = 'active' and p.audience = 'public' and p.kind <> 'story' and a.status = 'active' and a.privacy = 'public'
                  and p.created_at > now() - interval '14 days')
         + case when e.start_date < now() + interval '7 days' then 3 else 0 end as score
    from public.site_events e
    where e.status = 'published' and coalesce(e.end_date, e.start_date) >= now()
    order by score desc, e.id
    limit least(greatest(coalesce(p_limit, 10), 1), 30)
  ) h
  where h.score > 0
$$;

-- A directory of professionals and event groups. Narrow it by category, city (whole word start) and name; best known first. p_offset pages it.
create function public.explore_professionals(p_actor uuid, p_category text default null, p_city text default null, p_query text default null, p_limit int default 20, p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_category text := nullif(lower(btrim(coalesce(p_category, ''))), '');
  v_city text := nullif(lower(btrim(coalesce(p_city, ''))), '');
  v_query text := nullif(lower(btrim(coalesce(p_query, ''))), '');
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  perform public.profile_require_actor(p_actor);
  if v_category is not null and v_category not in ('event_group', 'dj', 'mc', 'artist', 'instrumentalist', 'photographer', 'videographer', 'influencer', 'promoter', 'other') then
    raise exception 'Choose a kind of professional from the list.';
  end if;
  if v_query is not null and char_length(v_query) > 40 then raise exception 'That search is too long.'; end if;
  return coalesce((
    select jsonb_agg(public.profile_card(p_actor, x.id) order by x.followers desc, x.name, x.id)
    from (
      select s.id,
             (select count(*) from public.site_follows f where f.followed = s.id and f.status = 'active') as followers,
             lower(s.display_name) as name
      from public.site_profiles s
      where s.kind = 'business' and s.status = 'active' and s.category <> 'venue'
        and (v_category is null or s.category = v_category)
        and (v_city is null or lower(coalesce(s.city, '')) like replace(replace(replace(v_city, '\', '\\'), '%', '\%'), '_', '\_') || '%')
        and (v_query is null or s.handle like replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_') || '%'
             or lower(s.display_name) like replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_') || '%')
        and not public.profile_blocked_between(p_actor, s.id)
      order by followers desc, name, s.id
      offset greatest(coalesce(p_offset, 0), 0)
      limit v_limit
    ) x
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.save_venue_facts(uuid, text[], text, int, boolean, text, text, text),
  public.review_visited(text, uuid), public.review_eligibility(uuid, text, uuid), public.review_save(uuid, text, uuid, int, text), public.review_delete(uuid, uuid),
  public.review_can_reply(uuid, uuid), public.review_reply(uuid, uuid, text), public.review_reply_delete(uuid, uuid), public.review_card(uuid, uuid),
  public.review_summary(text, uuid), public.reviews_list(uuid, text, uuid, int, timestamptz, uuid), public.venue_ratings(uuid[]),
  public.explore_hot_venues(int), public.explore_hot_events(int), public.explore_professionals(uuid, text, text, text, int, int)
from public, anon, authenticated;
grant execute on function
  public.save_venue_facts(uuid, text[], text, int, boolean, text, text, text),
  public.review_eligibility(uuid, text, uuid), public.review_save(uuid, text, uuid, int, text), public.review_delete(uuid, uuid),
  public.review_reply(uuid, uuid, text), public.review_reply_delete(uuid, uuid), public.reviews_list(uuid, text, uuid, int, timestamptz, uuid),
  public.explore_professionals(uuid, text, text, text, int, int)
to authenticated, service_role;
grant execute on function public.venue_ratings(uuid[]), public.explore_hot_venues(int), public.explore_hot_events(int) to anon, authenticated, service_role;
