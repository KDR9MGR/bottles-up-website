# Mutants for 20261103100000_explore_reviews.sql:
#   python3 tests/db/tools/mutate_migrations.py tests/db/tools/mutants_explore_reviews.py --jobs 3
# Run from the repository root.
import os

TARGET = '20261103100000'
TESTS = ['510_explore_reviews.sql']
SLOW = []
FILE = '20261103100000_explore_reviews.sql'
_SRC = open(os.path.join(os.getcwd(), 'supabase', 'migrations', FILE)).read()


def M(mid, fn, old, new):
    """A change inside one function, widened to the left line by line until it occurs once in the file."""
    start = _SRC.index('create function public.%s(' % fn)
    end = _SRC.find('\ncreate function', start + 10)
    body = _SRC[start:end if end != -1 else len(_SRC)]
    assert body.count(old) == 1, (mid, fn, old, body.count(old))
    at = start + body.index(old)
    lo = at
    while _SRC.count(_SRC[lo:at + len(old)]) > 1:
        lo = _SRC.rfind('\n', 0, lo - 1) + 1
    ctx = _SRC[lo:at]
    return (mid, FILE, ctx + old, ctx + new)


# Known equivalent changes (nothing in the database can tell them apart), kept out on purpose: a personal profile has no venue or business behind it so
# review_can_reply is false for it anyway (reply-business), and every caller has already checked that the profile is in good standing (reply-standing).
MUTANTS = [
    # venue facts
    M('facts-managers', 'save_venue_facts', "public.can_access_venue(p_venue, array['owner', 'manager'])", "public.can_access_venue(p_venue, array['owner'])"),
    M('facts-anyone', 'save_venue_facts', "if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then", "if p_venue is null then"),
    M('facts-amenity', 'save_venue_facts', "raise exception 'One of those features is not one we know.'", "null"),
    M('facts-age', 'save_venue_facts', "if p_min_age is not null and p_min_age not between 13 and 25 then raise exception 'The minimum age must be between 13 and 25.'; end if;", ""),
    M('facts-menu', 'save_venue_facts', "if v_menu is not null and (v_menu !~ '^https://' or char_length(v_menu) > 500) then raise exception 'The menu link must start with https://.'; end if;", ""),
    M('facts-parking', 'save_venue_facts', "if v_parking is not null and char_length(v_parking) > 300 then raise exception 'The parking note can be 300 characters at most.'; end if;", ""),
    M('facts-id', 'save_venue_facts', "if p_id_required is null then raise exception 'Say whether ID is required.'; end if;", ""),
    M('facts-dedupe', 'save_venue_facts', "select coalesce(array_agg(distinct x order by x), '{}') into v_amenities", "select coalesce(array_agg(x), '{}') into v_amenities"),
    M('facts-audit', 'save_venue_facts', "'venue_facts_saved'", "'venue_facts'"),
    # who has been
    M('visit-paid', 'review_visited', "b.venue_id = p_target and b.status = 'paid' and", "b.venue_id = p_target and"),
    M('visit-night-over', 'review_visited', "and b.booking_date < (now() at time zone", "and b.booking_date <= (now() at time zone"),
    M('visit-email-case', 'review_visited', "and lower(b.customer_email) = v_email", "and b.customer_email = v_email"),
    M('visit-ticket-venue', 'review_visited', "where e.venue_id = p_target and o.status = 'paid'", "where o.status = 'paid'"),
    M('visit-ticket-paid', 'review_visited', "where e.venue_id = p_target and o.status = 'paid' and", "where e.venue_id = p_target and"),
    M('visit-event-over-venue', 'review_visited', "and lower(o.customer_email) = v_email and coalesce(e.end_date, e.start_date) < now()\n    );\n  elsif", "and lower(o.customer_email) = v_email\n    );\n  elsif"),
    M('visit-event-over', 'review_visited', "where o.event_id = p_target and o.status = 'paid' and lower(o.customer_email) = v_email and coalesce(e.end_date, e.start_date) < now()", "where o.event_id = p_target and o.status = 'paid' and lower(o.customer_email) = v_email"),
    M('visit-event-paid', 'review_visited', "where o.event_id = p_target and o.status = 'paid' and", "where o.event_id = p_target and"),
    M('visit-no-email', 'review_visited', "if v_email = '' then return false; end if;", ""),
    M('elig-business', 'review_eligibility', "if exists (select 1 from public.site_profiles s where s.id = p_actor and s.kind = 'business') then", "if false then"),
    M('elig-flag', 'review_eligibility', "if not public.feature_enabled('reviews') then return jsonb_build_object('eligible', false, 'reason', 'Reviews are not open yet.', 'mine', v_mine); end if;", ""),
    M('elig-visit', 'review_eligibility', "if not public.review_visited(p_kind, p_target) then", "if false then"),
    M('elig-kind', 'review_eligibility', "if p_kind not in ('venue', 'event') or p_target is null then raise exception 'Choose a venue or an event.'; end if;", ""),
    # writing
    M('save-rating', 'review_save', "if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose 1 to 5 stars.'; end if;", ""),
    M('save-length', 'review_save', "if v_body is not null and char_length(v_body) > 1000 then raise exception 'A review can be 1000 characters at most.'; end if;", ""),
    M('save-words', 'review_save', "if not public.social_text_ok(v_body) then raise exception 'That text goes against our community rules.'; end if;", ""),
    M('save-eligible', 'review_save', "if (v_elig ->> 'eligible')::boolean is not true then raise exception '%', v_elig ->> 'reason'; end if;", ""),
    M('save-rate', 'review_save', ">= 10 then", ">= 11 then"),
    M('save-rate-new-only', 'review_save', "if (v_elig ->> 'mine') is null\n     and (select", "if (select"),
    M('save-update', 'review_save', "if (v_elig ->> 'mine') is not null then\n    update", "if false then\n    update"),
    M('delete-owner', 'review_delete', "if v_author is null or not public.profile_can_act_as(v_author) then", "if v_author is null then"),
    # answering
    M('reply-venue', 'review_can_reply', "(r.venue_id is not null and me.venue_id = r.venue_id)", "(r.venue_id is not null)"),
    M('reply-event-org', 'review_can_reply', "me.org_id is not null and me.venue_id is null and me.org_id = e.org_id", "me.org_id is not null and me.venue_id is null"),
    M('reply-event-venue-profile', 'review_can_reply', "me.org_id is not null and me.venue_id is null and me.org_id = e.org_id", "me.org_id is not null and me.org_id = e.org_id"),
    M('reply-flag', 'review_reply', "if not public.feature_enabled('reviews') then raise exception 'Reviews are not open yet.'; end if;", ""),
    M('reply-check', 'review_reply', "if not public.review_can_reply(p_actor, p_review) then raise exception 'Only the venue or the organizer it is about can reply.'; end if;", ""),
    M('reply-length', 'review_reply', "if char_length(v_body) > 1000 then raise exception 'A reply can be 1000 characters at most.'; end if;", ""),
    M('reply-words', 'review_reply', "if not public.social_text_ok(v_body) then raise exception 'That text goes against our community rules.'; end if;", ""),
    M('reply-once', 'review_reply', "on conflict (review) do update set author = excluded.author, body = excluded.body;", "on conflict do nothing;"),
    M('reply-delete-check', 'review_reply_delete', "if not public.review_can_reply(p_actor, p_review) then raise exception 'Only the venue or the organizer it is about can reply.'; end if;", ""),
    # reading
    M('summary-suspended', 'review_summary', "join public.site_profiles s on s.id = r.author and s.status = 'active'", "join public.site_profiles s on s.id = r.author"),
    M('summary-removed', 'review_summary', "where r.status = 'active' and r.kind = p_kind", "where r.kind = p_kind"),
    M('summary-average', 'review_summary', "round(avg(r.rating)::numeric, 1)", "round(min(r.rating)::numeric, 1)"),
    M('list-blocked', 'reviews_list', "and not public.profile_blocked_between(p_actor, r.author)\n", ""),
    M('list-suspended', 'reviews_list', "join public.site_profiles s on s.id = r.author and s.status = 'active'", "join public.site_profiles s on s.id = r.author"),
    M('list-removed', 'reviews_list', "where r.status = 'active' and r.kind = p_kind", "where r.kind = p_kind"),
    M('list-paging', 'reviews_list', "(r.created_at, r.id) < (p_before,", "(r.created_at, r.id) > (p_before,"),
    M('list-order', 'reviews_list', "order by x.created_at desc, x.id desc)", "order by x.created_at, x.id)"),
    M('list-target', 'reviews_list', "or (p_kind = 'event' and r.event_id = p_target))\n          and not", "or (p_kind = 'event'))\n          and not"),
    M('card-can-reply', 'review_card', "'can_reply', public.review_can_reply(p_viewer, r.id),", "'can_reply', true,"),
    M('ratings-flag', 'venue_ratings', "select case when not public.feature_enabled('reviews') then '{}'::jsonb else", "select case when false then '{}'::jsonb else"),
    M('ratings-suspended', 'venue_ratings', "join public.site_profiles s on s.id = r.author and s.status = 'active'", "join public.site_profiles s on s.id = r.author"),
    # hot
    M('hot-v-booking-weight', 'explore_hot_venues', "3 * (select count(*) from public.site_table_bookings", "2 * (select count(*) from public.site_table_bookings"),
    M('hot-v-booking-paid', 'explore_hot_venues', "b.venue_id = v.id and b.status = 'paid' and", "b.venue_id = v.id and"),
    M('hot-v-booking-window', 'explore_hot_venues', "b.created_at > now() - interval '14 days')\n         + (select", "true)\n         + (select"),
    M('hot-v-ticket-paid', 'explore_hot_venues', "e.venue_id = v.id and o.status = 'paid' and", "e.venue_id = v.id and"),
    M('hot-v-tag-weight', 'explore_hot_venues', "+ 2 * (select count(*) from public.site_post_tags t", "+ 1 * (select count(*) from public.site_post_tags t"),
    M('hot-v-tag-public', 'explore_hot_venues', "and p.audience = 'public' and p.kind <> 'story'", "and p.kind <> 'story'"),
    M('hot-v-tag-story', 'explore_hot_venues', "and p.audience = 'public' and p.kind <> 'story' and", "and p.audience = 'public' and"),
    M('hot-v-tag-removed', 'explore_hot_venues', "where t.venue_id = v.id and p.status = 'active' and", "where t.venue_id = v.id and"),
    M('hot-v-tag-private', 'explore_hot_venues', "and a.status = 'active' and a.privacy = 'public'", "and a.status = 'active'"),
    M('hot-v-tag-window', 'explore_hot_venues', "and p.created_at > now() - interval '14 days') as score", ") as score"),
    M('hot-v-published', 'explore_hot_venues', "where v.status = 'published'", "where true"),
    M('hot-v-zero', 'explore_hot_venues', "where h.score > 0", "where true"),
    M('hot-v-limit', 'explore_hot_venues', "limit least(greatest(coalesce(p_limit, 10), 1), 30)", "limit 30"),
    M('hot-e-order-weight', 'explore_hot_events', "2 * (select count(*) from public.site_orders o where o.event_id = e.id", "3 * (select count(*) from public.site_orders o where o.event_id = e.id"),
    M('hot-e-paid', 'explore_hot_events', "o.event_id = e.id and o.status = 'paid' and", "o.event_id = e.id and"),
    M('hot-e-soon', 'explore_hot_events', "case when e.start_date < now() + interval '7 days' then 3 else 0 end", "0"),
    M('hot-e-upcoming', 'explore_hot_events', "and coalesce(e.end_date, e.start_date) >= now()", ""),
    M('hot-e-published', 'explore_hot_events', "where e.status = 'published' and", "where"),
    M('hot-e-tag-public', 'explore_hot_events', "and p.audience = 'public' and p.kind <> 'story'", "and p.kind <> 'story'"),
    # directory
    M('pros-venue', 'explore_professionals', "and s.category <> 'venue'", ""),
    M('pros-category', 'explore_professionals', "if v_category is not null and v_category not in ('event_group',", "if false and v_category not in ('event_group',"),
    M('pros-filter', 'explore_professionals', "and (v_category is null or s.category = v_category)", ""),
    M('pros-city', 'explore_professionals', "and (v_city is null or lower(coalesce(s.city, '')) like", "and (true or lower(coalesce(s.city, '')) like"),
    M('pros-blocked', 'explore_professionals', "and not public.profile_blocked_between(p_actor, s.id)", ""),
    M('pros-suspended', 'explore_professionals', "s.kind = 'business' and s.status = 'active'", "s.kind = 'business'"),
    M('pros-order', 'explore_professionals', "order by followers desc, name, s.id\n      offset", "order by name, s.id\n      offset"),
    M('pros-offset', 'explore_professionals', "offset greatest(coalesce(p_offset, 0), 0)", "offset 0"),
    M('pros-escape', 'explore_professionals', "and (v_query is null or s.handle like replace(replace(replace(v_query, '\\', '\\\\'), '%', '\\%'), '_', '\\_') || '%'", "and (v_query is null or s.handle like v_query || '%'"),
    # surface
    ('grant-visited', FILE, "public.explore_professionals(uuid, text, text, text, int, int)\nto authenticated, service_role;", "public.explore_professionals(uuid, text, text, text, int, int), public.review_visited(text, uuid)\nto authenticated, service_role;"),
    ('tables-open', FILE, "revoke all on table public.site_reviews, public.site_review_replies from public, anon, authenticated;", "revoke all on table public.site_reviews from public, anon, authenticated;"),
    ('anon-reviews', FILE, "public.venue_ratings(uuid[]), public.explore_hot_venues(int), public.explore_hot_events(int) to anon, authenticated, service_role;", "public.venue_ratings(uuid[]), public.explore_hot_venues(int), public.explore_hot_events(int), public.reviews_list(uuid, text, uuid, int, timestamptz, uuid) to anon, authenticated, service_role;"),
    ('author-cascade', FILE, "author uuid not null references public.site_profiles (id) on delete cascade,\n  rating smallint", "author uuid not null references public.site_profiles (id),\n  rating smallint"),
    ('one-per-venue', FILE, "create unique index site_reviews_one_per_venue on public.site_reviews (author, venue_id) where venue_id is not null;", ""),
]
