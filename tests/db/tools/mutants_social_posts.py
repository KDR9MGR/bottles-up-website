# Mutants for 20261102100000_social_posts.sql:
#   python3 tests/db/tools/mutate_migrations.py tests/db/tools/mutants_social_posts.py --jobs 3
# Run from the repository root. Each mutant is one small wrong change; the test must fail for it.
import os

TARGET = '20261101100000'
TESTS = ['500_social_posts.sql']
SLOW = []
FILE = '20261102100000_social_posts.sql'
_SRC = open(os.path.join(os.getcwd(), 'supabase', 'migrations', FILE)).read()


def M(mid, fn, old, new):
    """A change inside one function. The text is widened to the left, line by line, until it occurs once in the whole file."""
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


VIS = "post_visible"
# Known equivalent changes (nothing in the database can tell them apart), kept out on purpose:
#   suggest-public: post_visible already hides every non-public post of a profile the viewer does not follow, and suggestions are only from those.
#   rail-expiry: post_visible already hides an expired story.  members-blocked: blocking removes the follow, so 'They need to follow you first.' answers first.
#   media-signed-out: the storage policies are for signed-in callers only.
MUTANTS = [
    # who sees a post
    M('vis-private-author', VIS, "(p.audience = 'public' and public.profile_content_visible(p_viewer, p.author))", "(p.audience = 'public')"),
    M('vis-followers-open', VIS, "or (p.audience = 'followers'\n                and exists (select 1 from public.site_follows f where f.follower = p_viewer and f.followed = p.author and f.status = 'active'))", "or (p.audience = 'followers')"),
    M('vis-members-no-follow', VIS, "or (p.audience = 'members'\n                and exists (select 1 from public.site_follows f where f.follower = p_viewer and f.followed = p.author and f.status = 'active')\n                and exists", "or (p.audience = 'members'\n                and exists"),
    M('vis-members-no-list', VIS, "\n                and exists (select 1 from public.site_member_lists l where l.owner = p.author and l.member = p_viewer))", ")"),
    M('vis-story-expiry', VIS, "and (p.kind <> 'story' or p.expires_at > now())\n", ""),
    M('vis-blocked', VIS, "and not public.profile_blocked_between(p_viewer, p.author)\n          and (", "and (\n          true or"),
    M('vis-suspended-author', VIS, "and a.status = 'active'\n", ""),
    M('vis-removed', VIS, "where p.id = p_post\n      and p.status = 'active'\n", "where p.id = p_post\n"),
    M('vis-author-own', VIS, "public.profile_is_mine(p.author)\n        or (", "false\n        or ("),
    # making a post
    M('create-rules', 'post_create', "perform public.social_require_rules();\n", ""),
    M('create-reels-flag', 'post_create', "if v_kind = 'reel' and not public.feature_enabled('reels') then raise exception 'Reels are not open yet.'; end if;\n", ""),
    M('create-stories-flag', 'post_create', "if v_kind = 'story' and not public.feature_enabled('stories') then raise exception 'Stories are not open yet.'; end if;\n", ""),
    M('create-members-flag', 'post_create', "if v_aud = 'members' and not public.feature_enabled('members_only') then raise exception 'Members Only is not open yet.'; end if;\n", ""),
    M('create-social-flag', 'post_create', "if not public.feature_enabled('social') then raise exception 'Posting is not open yet.'; end if;\n", ""),
    M('create-rate', 'post_create', ">= 20 then", ">= 21 then"),
    M('create-ten', 'post_create', "jsonb_array_length(p_media) > 10", "jsonb_array_length(p_media) > 11"),
    M('create-image-size', 'post_create', "v_size > 10485760 then", "v_size > 10485761 then"),
    M('create-video-size', 'post_create', "v_size > 104857600", "v_size > 104857601"),
    M('create-duration', 'post_create', "v_dur > 60000", "v_dur > 60001"),
    M('create-folder', 'post_create', "if public.social_media_profile(v_path) is distinct from p_actor then raise exception 'Something is wrong with that photo or video.'; end if;", ""),
    M('create-exists', 'post_create', "if not found then raise exception 'That photo or video did not finish uploading. Try again.'; end if;", ""),
    M('create-image-mime', 'post_create', "if v_mime is null or v_mime not like 'image/%' then raise exception 'Something is wrong with that photo.'; end if;", ""),
    M('create-video-mime', 'post_create', "if v_mime is null or v_mime not like 'video/%' then raise exception 'Something is wrong with that video.'; end if;", ""),
    M('create-poster-folder', 'post_create', "if public.social_media_profile(v_poster) is distinct from p_actor then raise exception 'Something is wrong with that video.'; end if;", ""),
    M('create-post-shape', 'post_create', "if v_kind = 'post' and (v_videos > 0 or v_images < 1)", "if v_kind = 'post' and (v_images < 1)"),
    M('create-reel-shape', 'post_create', "(v_videos <> 1 or v_images <> 0)", "(v_videos < 1)"),
    M('create-story-shape', 'post_create', "v_images + v_videos <> 1", "v_images + v_videos < 1"),
    M('create-tag-event', 'post_create', "where e.id = v_tag_id and e.status = 'published'", "where e.id = v_tag_id"),
    M('create-tag-venue', 'post_create', "where v.id = v_tag_id and v.status = 'published'", "where v.id = v_tag_id"),
    M('create-tag-profile', 'post_create', " or not public.profile_visible(p_actor, v_tag_id)", ""),
    M('create-tag-self', 'post_create', "if v_tag_id = p_actor or public.profile_is_mine(v_tag_id) or", "if v_tag_id = p_actor or"),
    M('create-tag-cap', 'post_create', "jsonb_array_length(coalesce(p_tags, '[]'::jsonb)) > 10", "jsonb_array_length(coalesce(p_tags, '[]'::jsonb)) > 11"),
    M('create-tag-dup', 'post_create', "if (v_tag_kind || ':' || v_tag_text) = any (v_seen) then raise exception 'You tagged the same one twice.'; end if;", ""),
    M('create-words', 'post_create', "if not public.social_text_ok(v_caption) then raise exception 'That text goes against our community rules.'; end if;", ""),
    M('create-caption-len', 'post_create', "char_length(v_caption) > 2200", "char_length(v_caption) > 2201"),
    M('words-boundary', 'social_text_ok', "'(^|[^a-z0-9])' || t.term || '($|[^a-z0-9])'", "'' || t.term || ''"),
    # changing and deleting
    M('edit-owner', 'post_edit', "if v_author is null or not public.profile_can_act_as(v_author) then", "if v_author is null then"),
    M('edit-words', 'post_edit', "if not public.social_text_ok(v_caption) then raise exception 'That text goes against our community rules.'; end if;", ""),
    M('delete-owner', 'post_delete', "if v_author is null or not public.profile_can_act_as(v_author) then", "if v_author is null then"),
    M('delete-poster', 'post_delete', "union all\n    select m.poster_path from public.site_post_media m where m.post = p_post and m.poster_path is not null", ""),
    M('get-visible', 'post_get', "if p_post is null or not public.post_visible(p_actor, p_post) then", "if p_post is null then"),
    M('untag-own', 'post_untag', "where post = p_post and profile_id = p_actor", "where post = p_post"),
    # reading
    M('grid-private', 'profile_posts', "if not (public.profile_content_visible(p_actor, p_profile) or public.profile_is_mine(p_profile)) then raise exception 'Follow this profile to see its posts.'; end if;", ""),
    M('grid-visible', 'profile_posts', "and public.post_visible(p_actor, p.id)\n        order by p.created_at desc, p.id desc", "order by p.created_at desc, p.id desc"),
    M('grid-total', 'profile_posts', "and (v_kind = '' or p.kind = v_kind) and public.post_visible(p_actor, p.id)),", "and (v_kind = '' or p.kind = v_kind)),"),
    M('feed-own', 'feed_home', "(p.author = p_actor or p.author in", "(false or p.author in"),
    M('feed-follows', 'feed_home', "or p.author in (select f.followed from public.site_follows f where f.follower = p_actor and f.status = 'active')", "or true"),
    M('feed-visible', 'feed_home', "and public.post_visible(p_actor, p.id)\n      order by", "order by"),
    M('feed-paging', 'feed_home', "(p.created_at, p.id) < (p_before,", "(p.created_at, p.id) > (p_before,"),
    M('feed-limit-floor', 'feed_home', "least(greatest(coalesce(p_limit, 20), 1), 40)", "least(coalesce(p_limit, 20), 40)"),
    M('suggest-followed', 'feed_suggested', "and p.author not in (select f.followed from public.site_follows f where f.follower = p_actor)\n", ""),
    M('suggest-public', 'feed_suggested', "and p.audience = 'public'\n", ""),
    M('suggest-old', 'feed_suggested', "and p.created_at > now() - interval '14 days'\n", ""),
    M('suggest-score', 'feed_suggested', "+ 2 * (select count(*) from public.site_comments c", "+ 1 * (select count(*) from public.site_comments c"),
    M('suggest-own', 'feed_suggested', "and not public.profile_is_mine(p.author)\n", ""),
    M('suggest-visible', 'feed_suggested', "and public.post_visible(p_actor, p.id)\n      order by score", "order by score"),
    M('reels-kind', 'feed_reels', "where p.kind = 'reel' and p.status = 'active'", "where p.kind in ('reel', 'post') and p.status = 'active'"),
    M('reels-visible', 'feed_reels', "and public.post_visible(p_actor, p.id)\n      order by", "order by"),
    # stories
    M('rail-members-ring', 'story_rail', "bool_or(s.audience = 'members') as members_only", "false as members_only"),
    M('rail-unseen', 'story_rail', "bool_or(s.author <> p_actor and not exists", "bool_or(not exists"),
    M('rail-visible', 'story_rail', "and public.post_visible(p_actor, s.id)\n      group by", "group by"),
    M('rail-expiry', 'story_rail', "and s.expires_at > now()\n", ""),
    M('rail-own-first', 'story_rail', "order by (g.author = p_actor) desc, g.unseen desc", "order by g.unseen desc"),
    M('stories-visible', 'stories_of', "and s.expires_at > now() and public.post_visible(p_actor, s.id)", "and s.expires_at > now()"),
    M('stories-order', 'stories_of', "order by r.created_at, r.id)", "order by r.created_at desc, r.id)"),
    M('seen-visible', 'story_seen', "or not public.post_visible(p_actor, p_story) then", "then"),
    M('seen-kind', 'story_seen', "s.id = p_story and s.kind = 'story')", "s.id = p_story)"),
    # likes, saves, comments
    M('like-visible', 'post_like', "if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;\n    insert", "insert"),
    M('save-visible', 'post_save', "if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;\n    insert", "insert"),
    M('saved-visible', 'saved_posts', "and public.post_visible(p_actor, sv.post)", ""),
    M('saved-order', 'saved_posts', "order by r.created_at desc, r.post desc)", "order by r.created_at, r.post)"),
    M('comment-rules', 'comment_add', "perform public.social_require_rules();\n", ""),
    M('comment-visible', 'comment_add', "if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;\n  select", "select"),
    M('comment-off', 'comment_add', "if not v_comments_on then raise exception 'Comments are turned off for this post.'; end if;", ""),
    M('comment-words', 'comment_add', "if not public.social_text_ok(v_body) then raise exception 'That text goes against our community rules.'; end if;", ""),
    M('comment-len', 'comment_add', "char_length(v_body) > 1000", "char_length(v_body) > 1001"),
    M('comment-reply-level', 'comment_add', "c.reply_to is null and c.status = 'active'", "c.status = 'active'"),
    M('comment-reply-post', 'comment_add', "c.id = p_reply_to and c.post = p_post and", "c.id = p_reply_to and"),
    M('comment-rate', 'comment_add', ">= 20 then", ">= 21 then"),
    M('comment-list-visible', 'comment_list', "if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;", ""),
    M('comment-list-blocked', 'comment_list', "and not public.profile_blocked_between(p_actor, c.author)\n      order by", "order by"),
    M('comment-list-paging', 'comment_list', "and (p_after is null or c.created_at > p_after)", ""),
    M('comment-list-suspended', 'comment_list', "join public.site_profiles s on s.id = c.author and s.status = 'active'", "join public.site_profiles s on s.id = c.author"),
    M('comment-delete-rule', 'comment_delete', "not (public.profile_can_act_as(v_author) or public.profile_can_act_as(v_post_author))", "false"),
    M('comment-can-delete', 'comment_card', "public.profile_is_mine(c.author) or public.profile_is_mine(p.author)", "public.profile_is_mine(c.author)"),
    M('card-liked', 'post_card', "p_viewer is not null and exists (select 1 from public.site_post_likes l where l.post = p.id and l.profile = p_viewer)", "false"),
    M('card-likes-suspended', 'post_card', "join public.site_profiles s on s.id = l.profile and s.status = 'active' where l.post = p.id)", "join public.site_profiles s on s.id = l.profile where l.post = p.id)"),
    M('card-tag-event-published', 'post_card', "left join public.site_events e on e.id = x.event_id and e.status = 'published'", "left join public.site_events e on e.id = x.event_id"),
    # Members Only
    M('members-follow', 'members_set', "if not exists (select 1 from public.site_follows f where f.follower = p_member and f.followed = p_actor and f.status = 'active') then", "if false then"),
    M('members-cap', 'members_set', ">= 2000", ">= 2001"),
    M('members-flag', 'members_set', "if not public.feature_enabled('members_only') then raise exception 'Members Only is not open yet.'; end if;\n", ""),
    M('members-self', 'members_set', "if p_member = p_actor or public.profile_is_mine(p_member) then", "if p_member = p_actor then"),
    M('members-blocked', 'members_set', "if not public.profile_visible(p_actor, p_member) then raise exception 'This profile isn''t available.'; end if;\n", ""),
    M('members-list-flag', 'members_list', "'still_following', exists (select 1 from public.site_follows f where f.follower = r.member and f.followed = p_actor and f.status = 'active')", "'still_following', true"),
    # rules, words, files
    M('rules-version', 'rules_accept', "if p_version is distinct from public.social_rules_version() then", "if false then"),
    M('rules-status', 'rules_status', "a.version >= public.social_rules_version()", "true"),
    M('banned-admin', 'cms_set_banned_term', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;", ""),
    M('banned-audit', 'cms_set_banned_term', "'banned_term', v_term, '{}'::jsonb", "'banned', v_term, '{}'::jsonb"),
    M('media-visible', 'social_media_visible', "where public.post_visible(me.id, m.post)", "where true"),
    M('media-own', 'social_media_visible', "if public.social_media_profile(p_name) is not null and public.profile_can_act_as(public.social_media_profile(p_name)) then return true; end if;\n", ""),
    M('media-signed-out', 'social_media_visible', "if auth.uid() is null then return false; end if;\n", ""),
    M('media-add', 'social_media_can_add', "and public.profile_can_act_as(public.social_media_profile(p_name))", ""),
    M('orphans-age', 'social_media_orphans', "and o.created_at < now() - interval '1 day'", ""),
    M('orphans-used', 'social_media_orphans', "and not exists (select 1 from public.site_post_media m where m.storage_path = o.name or m.poster_path = o.name)", "and not exists (select 1 from public.site_post_media m where m.storage_path = o.name)"),
    # surface
    (
        'grant-visible', FILE,
        "public.members_list(uuid, int, timestamptz), public.members_set(uuid, uuid, boolean)\nto authenticated, service_role;",
        "public.members_list(uuid, int, timestamptz), public.members_set(uuid, uuid, boolean), public.post_visible(uuid, uuid)\nto authenticated, service_role;",
    ),
    (
        'tables-open', FILE,
        "  public.site_posts, public.site_post_media, public.site_post_tags, public.site_post_likes, public.site_post_saves, public.site_comments,\n  public.site_member_lists, public.site_story_views, public.site_banned_terms, public.site_community_rules, public.site_rules_acceptance\nfrom public, anon, authenticated;",
        "  public.site_posts, public.site_post_media, public.site_post_tags, public.site_post_likes, public.site_post_saves, public.site_comments,\n  public.site_story_views, public.site_banned_terms, public.site_community_rules, public.site_rules_acceptance\nfrom public, anon, authenticated;",
    ),
    (
        'media-policy-read', FILE,
        "using (bucket_id = 'social-media' and public.social_media_visible(name));",
        "using (bucket_id = 'social-media');",
    ),
    (
        'media-policy-add', FILE,
        "with check (bucket_id = 'social-media' and public.social_media_can_add(name));",
        "with check (bucket_id = 'social-media');",
    ),
    (
        'media-policy-remove', FILE,
        "using (bucket_id = 'social-media' and public.social_media_can_add(name));",
        "using (bucket_id = 'social-media');",
    ),
    ('cascade-author', FILE, "author uuid not null references public.site_profiles (id) on delete cascade,\n  kind text not null check (kind in ('post', 'reel', 'story')),", "author uuid not null references public.site_profiles (id),\n  kind text not null check (kind in ('post', 'reel', 'story')),"),
    # the community rules text, from the CMS
    M('rules-version-max', 'social_rules_version', "select coalesce((select max(r.version) from public.site_community_rules r), 1)", "select coalesce((select min(r.version) from public.site_community_rules r), 1)"),
    M('rules-version-default', 'social_rules_version', "r), 1)", "r), 0)"),
    M('rules-current-latest', 'rules_current', "order by r.version desc limit 1", "order by r.version limit 1"),
    M('rules-publish-admin', 'cms_publish_rules', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;", "if auth.uid() is null then raise exception 'Only a BottlesUp admin can change this.'; end if;"),
    M('rules-publish-min', 'cms_publish_rules', "if char_length(v_body) < 20 or", "if char_length(v_body) < 19 or"),
    M('rules-publish-min-up', 'cms_publish_rules', "if char_length(v_body) < 20 or", "if char_length(v_body) < 21 or"),
    M('rules-publish-max', 'cms_publish_rules', "or char_length(v_body) > 8000 then", "or char_length(v_body) > 8001 then"),
    M('rules-publish-max-down', 'cms_publish_rules', "or char_length(v_body) > 8000 then", "or char_length(v_body) > 7999 then"),
    M('rules-publish-trim', 'cms_publish_rules', "v_body text := btrim(coalesce(p_body, ''));", "v_body text := coalesce(p_body, '');"),
    M('rules-publish-next', 'cms_publish_rules', "v_version := public.social_rules_version() + 1;", "v_version := public.social_rules_version() + 2;"),
    M('rules-publish-by', 'cms_publish_rules', "values (v_version, v_body, auth.uid());", "values (v_version, v_body, null);"),
    M('rules-publish-audit', 'cms_publish_rules', "'rules_published', 'community_rules', v_version::text,", "'rules_published', 'community_rules', 'x',"),
    M('rules-publish-audit-detail', 'cms_publish_rules', "jsonb_build_object('version', v_version, 'characters', char_length(v_body)));", "jsonb_build_object('version', v_version));"),
    M('rules-require-version', 'social_require_rules', "a.version >= public.social_rules_version()", "a.version >= 1"),
    M('rules-status-accepted', 'rules_status', "a.version >= public.social_rules_version())", "a.version >= 1)"),
    M('rules-accept-version', 'rules_accept', "if p_version is distinct from public.social_rules_version() then", "if false then"),
    M('rules-accept-upsert', 'rules_accept', "on conflict (user_id) do update set version = excluded.version, accepted_at = now();", "on conflict (user_id) do nothing;"),
    ('rules-table-open', FILE, "public.site_banned_terms, public.site_community_rules, public.site_rules_acceptance\nfrom public, anon, authenticated;", "public.site_banned_terms, public.site_rules_acceptance\nfrom public, anon, authenticated;"),
    ('rules-current-anon', FILE, "grant execute on function public.rules_current() to anon, authenticated, service_role;", "grant execute on function public.rules_current() to authenticated, service_role;"),
    ('rules-publish-open', FILE, "public.rules_status(), public.rules_accept(int), public.cms_publish_rules(text), public.cms_set_banned_term(text, boolean), public.cms_list_banned_terms(),\n  public.post_create(uuid, text, text, text, jsonb, jsonb, boolean), public.post_edit(uuid, uuid, text, text, boolean), public.post_delete(uuid, uuid),\n  public.post_get(uuid, uuid), public.post_untag(uuid, uuid),\n  public.profile_posts", "public.rules_status(), public.rules_accept(int), public.cms_set_banned_term(text, boolean), public.cms_list_banned_terms(),\n  public.post_create(uuid, text, text, text, jsonb, jsonb, boolean), public.post_edit(uuid, uuid, text, text, boolean), public.post_delete(uuid, uuid),\n  public.post_get(uuid, uuid), public.post_untag(uuid, uuid),\n  public.profile_posts"),
]
