# Mutants for 20261105100000_safety_moderation.sql:
#   python3 tests/db/tools/mutate_migrations.py tests/db/tools/mutants_safety_moderation.py --jobs 3
# Run from the repository root.
import os

TARGET = '20261105100000'
TESTS = ['530_safety_moderation.sql']
SLOW = []
FILE = '20261105100000_safety_moderation.sql'
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


# Known equivalent changes (nothing a single session can tell apart), kept out on purpose: the ON CONFLICT of report_create only matters when the same report arrives twice
# at the same instant (the early lookup answers every sequential repeat); counting reporters with or without DISTINCT (the unique index already keeps a reporter to one report a
# target); a null target in report_create (every branch finds nothing and gives the same sentence).
MUTANTS = [
    # reporting
    M('rc-actor', 'report_create', "perform public.profile_require_actor(p_actor);\n", ""),
    M('rc-flag', 'report_create', "if not public.feature_enabled('social') then raise exception 'Reporting is not open yet.'; end if;", ""),
    M('rc-kind', 'report_create', "if p_kind is null or p_kind not in ('post', 'comment', 'profile', 'message', 'review') then raise exception 'Say what you are reporting.'; end if;", ""),
    M('rc-reason', 'report_create', "if p_reason is null or p_reason not in ('spam', 'harassment', 'hate', 'sexual', 'violence', 'scam', 'impersonation', 'self_harm', 'other') then raise exception 'Choose a reason.'; end if;", ""),
    M('rc-details-length', 'report_create', "if v_details is not null and char_length(v_details) > 500 then", "if v_details is not null and char_length(v_details) > 501 then"),
    M('rc-details-blank', 'report_create', "v_details text := nullif(btrim(coalesce(p_details, '')), '');", "v_details text := btrim(coalesce(p_details, ''));"),
    M('rc-post-visible', 'report_create', "if not public.post_visible(p_actor, p_target) then raise exception 'This isn''t available.'; end if;", ""),
    M('rc-post-caption', 'report_create', "coalesce(left(p.caption, 500), '(' || p.kind || ' with no caption)')", "left(p.caption, 500)"),
    M('rc-post-owner', 'report_create', "select p.author, coalesce(left(p.caption, 500)", "select p.id, coalesce(left(p.caption, 500)"),
    M('rc-comment-active', 'report_create', "where c.id = p_target and c.status = 'active' and public.post_visible", "where c.id = p_target and public.post_visible"),
    M('rc-comment-post', 'report_create', "and public.post_visible(p_actor, c.post) and public.profile_visible(p_actor, c.author);", "and public.profile_visible(p_actor, c.author);"),
    M('rc-comment-author', 'report_create', "and public.post_visible(p_actor, c.post) and public.profile_visible(p_actor, c.author);", "and public.post_visible(p_actor, c.post);"),
    M('rc-profile-visible', 'report_create', "if public.profile_visible(p_actor, p_target) then", "if true then"),
    M('rc-profile-excerpt', 'report_create', "(public.profile_mini(p_target) ->> 'display_name') || ' (@' || (public.profile_mini(p_target) ->> 'handle') || ')'", "(public.profile_mini(p_target) ->> 'handle')"),
    M('rc-message-member', 'report_create', "where m.id = p_target and m.deleted_at is null and public.dm_is_member(p_actor, m.conversation);", "where m.id = p_target and m.deleted_at is null;"),
    M('rc-message-deleted', 'report_create', "where m.id = p_target and m.deleted_at is null and public.dm_is_member(p_actor, m.conversation);", "where m.id = p_target and public.dm_is_member(p_actor, m.conversation);"),
    M('rc-message-share', 'report_create', "case when m.kind = 'text' then m.body else '[shared ' || m.kind || '] ' || coalesce(m.body, '') end", "m.body"),
    M('rc-review-active', 'report_create', "where r.id = p_target and r.status = 'active' and public.profile_visible(p_actor, r.author);", "where r.id = p_target and public.profile_visible(p_actor, r.author);"),
    M('rc-review-author', 'report_create', "where r.id = p_target and r.status = 'active' and public.profile_visible(p_actor, r.author);", "where r.id = p_target and r.status = 'active';"),
    M('rc-review-excerpt', 'report_create', "left('Rating ' || r.rating || '/5: ' || coalesce(r.body, ''), 500)", "left(coalesce(r.body, ''), 500)"),
    M('rc-nothing', 'report_create', "if v_owner is null then raise exception 'This isn''t available.'; end if;", ""),
    M('rc-own', 'report_create', "if public.profile_is_mine(v_owner) then raise exception 'You can''t report your own profile or what you wrote.'; end if;", ""),
    M('rc-already-first', 'report_create', "if v_id is not null then return jsonb_build_object('id', v_id, 'already', true); end if;\n", ""),
    M('rc-already-flag', 'report_create', "if v_id is not null then return jsonb_build_object('id', v_id, 'already', true); end if;", "if v_id is not null then return jsonb_build_object('id', v_id, 'already', false); end if;"),
    M('rc-limit', 'report_create', "and r.created_at > now() - interval '1 day') >= 20 then", "and r.created_at > now() - interval '1 day') >= 21 then"),
    M('rc-limit-low', 'report_create', "and r.created_at > now() - interval '1 day') >= 20 then", "and r.created_at > now() - interval '1 day') >= 19 then"),
    M('rc-limit-window-short', 'report_create', "and r.created_at > now() - interval '1 day') >= 20 then", "and r.created_at > now() - interval '1 hour') >= 20 then"),
    M('rc-limit-window-long', 'report_create', "and r.created_at > now() - interval '1 day') >= 20 then", "and r.created_at > now() - interval '2 days') >= 20 then"),
    M('rc-limit-reporter', 'report_create', "where r.reporter = p_actor and r.created_at > now()", "where r.created_at > now()"),
    M('rc-store-reason', 'report_create', "values (p_actor, p_kind, p_target, v_owner, p_reason, v_details, v_excerpt)", "values (p_actor, p_kind, p_target, v_owner, 'other', v_details, v_excerpt)"),
    M('rc-store-owner', 'report_create', "values (p_actor, p_kind, p_target, v_owner, p_reason, v_details, v_excerpt)", "values (p_actor, p_kind, p_target, p_actor, p_reason, v_details, v_excerpt)"),
    # the queue
    M('list-admin', 'cms_reports_list', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;", "if auth.uid() is null then raise exception 'Only a BottlesUp admin can see this.'; end if;"),
    M('list-status', 'cms_reports_list', "if p_status is null or p_status not in ('open', 'actioned', 'dismissed', 'all') then raise exception 'Choose open, actioned, dismissed or all.'; end if;", ""),
    M('list-filter', 'cms_reports_list', "where p_status = 'all' or r.status = p_status", "where true"),
    M('list-cap', 'cms_reports_list', "least(greatest(coalesce(p_limit, 50), 1), 100)", "least(greatest(coalesce(p_limit, 50), 1), 1000)"),
    M('list-floor', 'cms_reports_list', "least(greatest(coalesce(p_limit, 50), 1), 100)", "least(coalesce(p_limit, 50), 100)"),
    M('list-default', 'cms_reports_list', "least(greatest(coalesce(p_limit, 50), 1), 100)", "least(greatest(coalesce(p_limit, 20), 1), 100)"),
    M('list-offset', 'cms_reports_list', "v_offset int := greatest(coalesce(p_offset, 0), 0);", "v_offset int := coalesce(p_offset, 0);"),
    M('list-order-open', 'cms_reports_list', "case when x.status = 'open' then extract(epoch from x.first_at) else -extract(epoch from x.handled_at) end", "case when x.status = 'open' then -extract(epoch from x.first_at) else -extract(epoch from x.handled_at) end"),
    M('list-order-handled', 'cms_reports_list', "case when x.status = 'open' then extract(epoch from x.first_at) else -extract(epoch from x.handled_at) end", "case when x.status = 'open' then extract(epoch from x.first_at) else extract(epoch from x.handled_at) end"),
    M('list-group-decision', 'cms_reports_list', "group by r.kind, r.target, r.status, r.handled_at", "group by r.kind, r.target, r.status"),
    M('list-reasons-status', 'cms_reports_list', "where r2.kind = r.kind and r2.target = r.target and r2.status = r.status and r2.handled_at is not distinct from r.handled_at) d) as reasons", "where r2.kind = r.kind and r2.target = r.target) d) as reasons"),
    M('list-details-cap', 'cms_reports_list', "order by r2.created_at limit 5) d) as details", "order by r2.created_at limit 6) d) as details"),
    M('list-details-order', 'cms_reports_list', "order by r2.created_at limit 5) d) as details", "order by r2.created_at desc limit 5) d) as details"),
    M('list-excerpt-first', 'cms_reports_list', "(array_agg(r.excerpt order by r.created_at))[1] as excerpt", "(array_agg(r.excerpt order by r.created_at desc))[1] as excerpt"),
    M('list-state-post', 'cms_reports_list', "when 'post' then coalesce((select p.status from public.site_posts p where p.id = x.target), 'gone')", "when 'post' then 'active'"),
    M('list-state-comment', 'cms_reports_list', "when 'comment' then coalesce((select c.status from public.site_comments c where c.id = x.target), 'gone')", "when 'comment' then 'active'"),
    M('list-state-review', 'cms_reports_list', "when 'review' then coalesce((select r.status from public.site_reviews r where r.id = x.target), 'gone')", "when 'review' then 'active'"),
    M('list-state-message', 'cms_reports_list', "case when m.deleted_at is null then 'active' else 'removed' end", "'active'"),
    M('list-state-profile', 'cms_reports_list', "case when s.status = 'active' then 'active' else 'suspended' end", "'active'"),
    M('list-state-gone', 'cms_reports_list', "when 'post' then coalesce((select p.status from public.site_posts p where p.id = x.target), 'gone')", "when 'post' then coalesce((select p.status from public.site_posts p where p.id = x.target), 'active')"),
    M('list-profile-status', 'cms_reports_list', "jsonb_build_object('status', (select s.status from public.site_profiles s where s.id = x.target_profile))", "jsonb_build_object('status', 'active')"),
    M('list-reporters-named', 'cms_reports_list', "'reporters', x.reporters,", "'reporters', x.reporters, 'reporter_ids', (select jsonb_agg(r3.reporter) from public.site_reports r3 where r3.kind = x.kind and r3.target = x.target),"),
    # deciding
    M('rr-admin', 'cms_report_resolve', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;", "if auth.uid() is null then raise exception 'Only a BottlesUp admin can change this.'; end if;"),
    M('rr-kind', 'cms_report_resolve', "or p_target is null then raise exception 'Say what was reported.'; end if;", "then raise exception 'Say what was reported.'; end if;"),
    M('rr-kind-list', 'cms_report_resolve', "if p_kind is null or p_kind not in ('post', 'comment', 'profile', 'message', 'review')", "if p_kind is null"),
    M('rr-action', 'cms_report_resolve', "if p_action is null or p_action not in ('dismiss', 'remove', 'suspend', 'restore') then raise exception 'Choose dismiss, remove, suspend or restore.'; end if;", ""),
    M('rr-note-length', 'cms_report_resolve', "if v_note is not null and char_length(v_note) > 500 then", "if v_note is not null and char_length(v_note) > 501 then"),
    M('rr-nobody', 'cms_report_resolve', "if v_any = 0 then raise exception 'Nobody has reported this.'; end if;", ""),
    M('rr-handled', 'cms_report_resolve', "if p_action <> 'restore' and v_open = 0 then raise exception 'These reports have already been handled.'; end if;", ""),
    M('rr-restore-open', 'cms_report_resolve', "if p_action <> 'restore' and v_open = 0 then", "if v_open = 0 then"),
    M('rr-profile-remove', 'cms_report_resolve', "if p_kind = 'profile' then raise exception 'A profile is suspended, not removed.'; end if;", ""),
    M('rr-remove-post', 'cms_report_resolve', "if p_kind = 'post' then update public.site_posts set status = 'removed' where id = p_target;", "if p_kind = 'post' then update public.site_posts set status = 'active' where id = p_target;"),
    M('rr-remove-comment', 'cms_report_resolve', "elsif p_kind = 'comment' then update public.site_comments set status = 'removed' where id = p_target;", "elsif p_kind = 'comment' then update public.site_comments set status = 'active' where id = p_target;"),
    M('rr-remove-review', 'cms_report_resolve', "elsif p_kind = 'review' then update public.site_reviews set status = 'removed' where id = p_target;", "elsif p_kind = 'review' then update public.site_reviews set status = 'active' where id = p_target;"),
    M('rr-remove-message', 'cms_report_resolve', "update public.site_dm_messages set deleted_at = coalesce(deleted_at, now()) where id = p_target;", "update public.site_dm_messages set deleted_at = null where id = p_target;"),
    M('rr-suspend-none', 'cms_report_resolve', "if v_profile is null then raise exception 'There is no profile left to suspend.'; end if;", ""),
    M('rr-suspend-person', 'cms_report_resolve', "update public.site_profiles set status = 'suspended' where id in (select public.moderation_person_profiles(v_profile));", "update public.site_profiles set status = 'suspended' where id = v_profile;"),
    M('rr-restore-post', 'cms_report_resolve', "if p_kind = 'post' then update public.site_posts set status = 'active' where id = p_target;", "if p_kind = 'post' then update public.site_posts set status = 'removed' where id = p_target;"),
    M('rr-restore-comment', 'cms_report_resolve', "elsif p_kind = 'comment' then update public.site_comments set status = 'active' where id = p_target;", "elsif p_kind = 'comment' then update public.site_comments set status = 'removed' where id = p_target;"),
    M('rr-restore-review', 'cms_report_resolve', "elsif p_kind = 'review' then update public.site_reviews set status = 'active' where id = p_target;", "elsif p_kind = 'review' then update public.site_reviews set status = 'removed' where id = p_target;"),
    M('rr-restore-message', 'cms_report_resolve', "elsif p_kind = 'message' then update public.site_dm_messages set deleted_at = null where id = p_target;", "elsif p_kind = 'message' then update public.site_dm_messages set deleted_at = now() where id = p_target;"),
    M('rr-restore-person', 'cms_report_resolve', "update public.site_profiles set status = 'active' where id in (select public.moderation_person_profiles(v_profile));", "update public.site_profiles set status = 'active' where id = v_profile;"),
    M('rr-restore-reports', 'cms_report_resolve', "where kind = p_kind and target = p_target and status = 'actioned';", "where kind = p_kind and target = p_target;"),
    M('rr-restore-mark', 'cms_report_resolve', "set status = 'dismissed', action = 'restored', note = v_note,", "set status = 'actioned', action = 'restored', note = v_note,"),
    M('rr-status-map', 'cms_report_resolve', "set status = case p_action when 'dismiss' then 'dismissed' else 'actioned' end,", "set status = 'actioned',"),
    M('rr-action-map', 'cms_report_resolve', "action = case p_action when 'dismiss' then 'dismissed' when 'remove' then 'removed' else 'suspended' end,", "action = 'removed',"),
    M('rr-open-only', 'cms_report_resolve', "where kind = p_kind and target = p_target and status = 'open';", "where kind = p_kind and target = p_target;"),
    M('rr-note-stored', 'cms_report_resolve', "note = v_note, handled_by = auth.uid(), handled_at = v_at\n    where kind = p_kind and target = p_target and status = 'open';", "handled_by = auth.uid(), handled_at = v_at\n    where kind = p_kind and target = p_target and status = 'open';"),
    M('rr-handled-by', 'cms_report_resolve', "note = v_note, handled_by = auth.uid(), handled_at = v_at\n    where kind = p_kind and target = p_target and status = 'open';", "note = v_note, handled_at = v_at\n    where kind = p_kind and target = p_target and status = 'open';"),
    M('rr-audit', 'cms_report_resolve', "values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'report_' || p_action, 'report', p_target::text,", "values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'report_decided', 'report', p_target::text,"),
    M('rr-audit-detail', 'cms_report_resolve', "jsonb_build_object('kind', p_kind, 'note', v_note, 'reports', v_n));", "jsonb_build_object('kind', p_kind));"),
    M('rr-answer', 'cms_report_resolve', "return jsonb_build_object('handled', v_n);", "return jsonb_build_object('handled', 1);"),
    # finding people and acting on a profile
    M('fp-admin', 'cms_find_profiles', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;", "if auth.uid() is null then raise exception 'Only a BottlesUp admin can see this.'; end if;"),
    M('fp-min', 'cms_find_profiles', "if char_length(v_q) < 2 then", "if char_length(v_q) < 1 then"),
    M('fp-escape', 'cms_find_profiles', "v_like := replace(replace(replace(v_q, '\\', '\\\\'), '%', '\\%'), '_', '\\_') || '%';", "v_like := v_q || '%';"),
    M('fp-name', 'cms_find_profiles', "         or lower(case p.kind when 'personal' then pr.name else p.display_name end) like v_like", ""),
    M('fp-cap', 'cms_find_profiles', "      limit 20\n", "      limit 200\n"),
    M('fp-case', 'cms_find_profiles', "v_q text := lower(btrim(coalesce(p_query, '')));", "v_q text := btrim(coalesce(p_query, ''));"),
    M('ps-admin', 'cms_profile_set_status', "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;", "if auth.uid() is null then raise exception 'Only a BottlesUp admin can change this.'; end if;"),
    M('ps-choice', 'cms_profile_set_status', "if p_suspended is null then raise exception 'Choose suspend or restore.'; end if;", ""),
    M('ps-exists', 'cms_profile_set_status', "if not exists (select 1 from public.site_profiles s where s.id = p_profile) then raise exception 'There is no such profile.'; end if;", ""),
    M('ps-note-length', 'cms_profile_set_status', "if v_note is not null and char_length(v_note) > 500 then", "if v_note is not null and char_length(v_note) > 501 then"),
    M('ps-person', 'cms_profile_set_status', "where id in (select public.moderation_person_profiles(p_profile));", "where id = p_profile;"),
    M('ps-direction', 'cms_profile_set_status', "set status = case when p_suspended then 'suspended' else 'active' end", "set status = case when p_suspended then 'active' else 'suspended' end"),
    M('ps-audit-name', 'cms_profile_set_status', "case when p_suspended then 'profile_suspended' else 'profile_restored' end", "'profile_suspended'"),
    M('ps-audit-note', 'cms_profile_set_status', "jsonb_build_object('note', v_note, 'profiles', v_n));", "jsonb_build_object('profiles', v_n));"),
    M('mp-person', 'moderation_person_profiles', "or (s.user_id is not null and s.user_id = (select p.user_id from public.site_profiles p where p.id = p_profile))", ""),
    M('mp-self', 'moderation_person_profiles', "where s.id = p_profile or (s.user_id", "where (s.user_id"),
    # daily housekeeping
    M('hk-floor', 'social_housekeeping', "greatest(coalesce(p_story_days, 7), 1)", "coalesce(p_story_days, 7)"),
    M('hk-default-story', 'social_housekeeping', "coalesce(p_story_days, 7)", "coalesce(p_story_days, 5)"),
    M('hk-default-story-long', 'social_housekeeping', "coalesce(p_story_days, 7)", "coalesce(p_story_days, 9)"),
    M('hk-default-notif', 'social_housekeeping', "coalesce(p_notification_days, 90)", "coalesce(p_notification_days, 60)"),
    M('hk-default-notif-long', 'social_housekeeping', "coalesce(p_notification_days, 90)", "coalesce(p_notification_days, 120)"),
    M('hk-notifications', 'social_housekeeping', "  v_notifications := public.notifications_purge(coalesce(p_notification_days, 90));\n", "  v_notifications := 0;\n"),
    M('hk-uses-short', 'social_housekeeping', "where created_at < now() - interval '2 days';", "where created_at < now() - interval '1 day';"),
    M('hk-uses-long', 'social_housekeeping', "where created_at < now() - interval '2 days';", "where created_at < now() - interval '4 days';"),
    M('hk-uses-delete', 'social_housekeeping', "  delete from public.site_ai_caption_uses where created_at < now() - interval '2 days';\n  get diagnostics v_uses = row_count;\n", "  v_uses := 0;\n"),
    M('hk-stories-delete', 'social_housekeeping', "  delete from public.site_posts where kind = 'story' and expires_at < now() - make_interval(days => greatest(coalesce(p_story_days, 7), 1));\n  get diagnostics v_stories = row_count;\n", "  v_stories := 0;\n"),
    M('hk-answer', 'social_housekeeping', "jsonb_build_object('stories', v_stories, 'notifications', v_notifications, 'caption_uses', v_uses)", "jsonb_build_object('stories', v_stories, 'notifications', v_uses, 'caption_uses', v_notifications)"),
    ('hk-grant-open', FILE, "grant execute on function public.social_housekeeping(int, int) to service_role;", "grant execute on function public.social_housekeeping(int, int) to authenticated, service_role;"),
    # the surface
    ('g-report-anon', FILE, "grant execute on function\n  public.report_create(uuid, text, uuid, text, text), public.cms_reports_list(text, int, int),", "grant execute on function\n  public.report_create(uuid, text, uuid, text, text), public.cms_reports_list(text, int, int), public.moderation_person_profiles(uuid),"),
    ('g-table-open', FILE, "revoke all on table public.site_reports from public, anon, authenticated;", ""),
    ('g-list-anon', FILE, "revoke all on function\n  public.report_create(uuid, text, uuid, text, text), public.cms_reports_list(text, int, int), public.moderation_person_profiles(uuid),", "revoke all on function\n  public.report_create(uuid, text, uuid, text, text), public.moderation_person_profiles(uuid),"),
    ('c-reporter-cascade', FILE, "reporter uuid references public.site_profiles (id) on delete set null,", "reporter uuid references public.site_profiles (id) on delete cascade,"),
    ('c-target-cascade', FILE, "target_profile uuid references public.site_profiles (id) on delete set null,", "target_profile uuid references public.site_profiles (id) on delete cascade,"),
    ('c-unique-report', FILE, "create unique index site_reports_one_per_reporter on public.site_reports (reporter, kind, target) where reporter is not null;", "create index site_reports_one_per_reporter on public.site_reports (reporter, kind, target) where reporter is not null;"),
]
