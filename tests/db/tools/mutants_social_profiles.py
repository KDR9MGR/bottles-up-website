# Mutants for 20261101100000_feature_flags.sql and 20261101110000_social_profiles.sql:
#   python3 tests/db/tools/mutate_migrations.py tests/db/tools/mutants_social_profiles.py --jobs 3
TARGET = '20261101100000'
TESTS = ['480_feature_flags.sql', '490_social_profiles.sql']
SLOW = []
FF = '20261101100000_feature_flags.sql'
SP = '20261101110000_social_profiles.sql'
MUTANTS = [
    # feature flags
    ('ff-admin-check', FF, "if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;",
     "if auth.uid() is null then raise exception 'Only a BottlesUp admin can change this.'; end if;"),
    ('ff-audit-always', FF, "if v_old is distinct from p_enabled then", "if true then"),
    ('ff-anon-grant', FF, "grant execute on function public.site_features() to anon, authenticated, service_role;", "grant execute on function public.site_features() to authenticated, service_role;"),
    ('ff-internal-grant', FF, "grant execute on function public.feature_enabled(text) to service_role;", "grant execute on function public.feature_enabled(text) to authenticated, service_role;"),
    ('ff-default-on', FF, "enabled boolean not null default false,", "enabled boolean not null default true,"),
    ('ff-null-answer', FF, "if p_enabled is null then raise exception 'Choose on or off.'; end if;", ""),
    # usernames
    ('sp-reserved', SP, "'admin', 'administrator', 'support', 'help',", "'admin', 'administrator', 'help',"),
    ('sp-own-name-free', SP, "where h.handle = v and h.profile_id is distinct from auth.uid());", "where h.handle = v);"),
    ('sp-rename-not-followed', SP, "on conflict (profile_id) do update set handle = excluded.handle;", "on conflict do nothing;"),
    ('sp-trigger-insert-only', SP, "after insert or update of username on public.profiles", "after insert on public.profiles"),
    ('sp-backfill', SP, "insert into public.site_handles (handle, profile_id) select p.username, p.id from public.profiles p where p.username is not null;", ""),
    # who may act
    ('sp-manager-anyone', SP, "or (p.venue_id is not null and public.can_access_venue(p.venue_id, array['manager']))", "or (p.venue_id is not null)"),
    ('sp-manager-dropped', SP, "or (p.venue_id is not null and public.can_access_venue(p.venue_id, array['manager']))", ""),
    ('sp-organizer-dropped', SP, "public.is_org_member(p.org_id, array['owner', 'organizer'])\n", "public.is_org_member(p.org_id, array['owner'])\n"),
    ('sp-suspended-can-act', SP, "and exists (select 1 from public.site_profiles p where p.id = p_profile and p.status = 'active')", "and true"),
    ('sp-block-one-way', SP, "where (b.blocker = p_a and b.blocked = p_b) or (b.blocker = p_b and b.blocked = p_a)", "where (b.blocker = p_a and b.blocked = p_b)"),
    ('sp-suspended-visible', SP, "select exists (select 1 from public.site_profiles p where p.id = p_target and p.status = 'active')", "select exists (select 1 from public.site_profiles p where p.id = p_target)"),
    ('sp-owner-of-private', SP, "or public.profile_is_mine(p_target)\n       or exists", "or exists"),
    ('sp-follower-sees-content', SP, "v_content := p.privacy = 'public' or v_mine or v_follow = 'active';", "v_content := p.privacy = 'public' or v_mine;"),
    ('sp-private-all-see', SP, "v_content := p.privacy = 'public' or v_mine or v_follow = 'active';", "v_content := true;"),
    ('sp-interests-leak', SP, "'interests', case when v_mine then to_jsonb(p.interests) else '[]'::jsonb end,", "'interests', to_jsonb(p.interests),"),
    # business profiles
    ('sp-cap', SP, ">= 5 then", ">= 6 then"),
    ('sp-venue-permission', SP, "if not public.can_access_venue(p_venue, array['owner', 'manager']) then", "if false then"),
    ('sp-org-permission', SP, "if not public.is_org_member(p_org, array['owner', 'organizer']) then", "if false then"),
    ('sp-update-actor', SP, "  perform public.profile_require_actor(p_profile);\n", ""),
    ('sp-photo-kept', SP, "avatar_url = case when p_avatar_url is null then s.avatar_url else nullif(btrim(p_avatar_url), '') end,", "avatar_url = nullif(btrim(coalesce(p_avatar_url, '')), ''),"),
    ('sp-business-handle-list', SP, "    insert into public.site_handles (handle, business_id) values (v_handle, v_id);\n", ""),
    ('sp-personal-needs-profile', SP, "    raise exception 'Finish your name and username first.';", "    null;"),
    # search
    ('sp-escape-underscore', SP, "replace(replace(replace(v_q, '\\', '\\\\'), '%', '\\%'), '_', '\\_')", "replace(replace(v_q, '\\', '\\\\'), '%', '\\%')"),
    ('sp-limit-floor', SP, "least(greatest(coalesce(p_limit, 20), 1), 30)", "least(coalesce(p_limit, 20), 30)"),
    ('sp-search-self', SP, "        and s.id <> p_actor\n", ""),
    ('sp-search-blocked', SP, "        and not public.profile_blocked_between(p_actor, s.id)\n      order by (coalesce(s.handle, pr.username) = v_q) desc", "      order by (coalesce(s.handle, pr.username) = v_q) desc"),
    # following
    ('sp-private-immediate', SP, "case when v_private then 'pending' else 'active' end", "'active'"),
    ('sp-rate-limit', SP, ">= 200 then", ">= 201 then"),
    ('sp-follow-own-other', SP, "if p_target = p_actor or public.profile_is_mine(p_target) then raise exception 'You cannot follow your own profile.'; end if;", "if p_target = p_actor then raise exception 'You cannot follow your own profile.'; end if;"),
    ('sp-accept-any', SP, "update public.site_follows set status = 'active' where follower = p_other and followed = p_actor and status = 'pending';", "update public.site_follows set status = 'active' where follower = p_other and followed = p_actor;"),
    ('sp-list-private', SP, "if not (public.profile_content_visible(p_actor, p_profile) or p_profile = p_actor) then", "if false then"),
    ('sp-list-blocked', SP, "        and not public.profile_blocked_between(p_actor, s.id)\n      order by f.created_at desc\n      limit v_limit", "      order by f.created_at desc\n      limit v_limit"),
    ('sp-list-pending', SP, "      where f.status = 'active'\n        and ((v_kind", "      where true\n        and ((v_kind"),
    ('sp-list-paging', SP, "and (p_before is null or f.created_at < p_before)", ""),
    ('sp-public-accepts-pending', SP, "if v_before = 'private' and v_privacy = 'public' then", "if false then"),
    # blocking
    ('sp-block-keeps-follows', SP, "    delete from public.site_follows\n    where (follower = p_actor and followed = p_target) or (follower = p_target and followed = p_actor);", "    null;"),
    ('sp-block-one-direction', SP, "where (follower = p_actor and followed = p_target) or (follower = p_target and followed = p_actor);", "where (follower = p_actor and followed = p_target);"),
    ('sp-block-self', SP, "if p_target = p_actor or public.profile_is_mine(p_target) then raise exception 'You cannot block your own profile.'; end if;", "if p_target = p_actor then raise exception 'You cannot block your own profile.'; end if;"),
    ('sp-block-reveals', SP, "if not public.profile_visible(p_actor, p_target) then raise exception 'This profile isn''t available.'; end if;", "if not public.profile_visible(p_actor, p_target) then raise exception 'You are blocked.'; end if;"),
    ('sp-my-ids-manager', SP, "where m.role in ('owner', 'organizer') or (m.role = 'manager'", "where m.role in ('owner') or (m.role = 'manager'"),
    ('sp-flag-follow', SP, "    if not public.feature_enabled('social') then raise exception 'Profiles are not open yet.'; end if;\n    if not public.profile_visible(p_actor, p_target)", "    if not public.profile_visible(p_actor, p_target)"),
    ('sp-flag-create', SP, "  if not public.feature_enabled('social') then raise exception 'Profiles are not open yet.'; end if;\n  if v_category not in (", "  if v_category not in ("),
    ('sp-flag-personal', SP, "  if not public.feature_enabled('social') then raise exception 'Profiles are not open yet.'; end if;\n  if v_privacy not in", "  if v_privacy not in"),
    # surface
    ('sp-helper-grant', SP, "public.block_set(uuid, uuid, boolean), public.block_list(uuid)\nto authenticated, service_role;", "public.block_set(uuid, uuid, boolean), public.block_list(uuid), public.profile_can_act_as(uuid)\nto authenticated, service_role;"),
    ('sp-tables-open', SP, "revoke all on table public.site_profiles, public.site_handles, public.site_follows, public.site_blocks from public, anon, authenticated;", "revoke all on table public.site_profiles, public.site_handles, public.site_follows from public, anon, authenticated;"),
    ('sp-follow-cascade', SP, "follower uuid not null references public.site_profiles (id) on delete cascade,", "follower uuid not null references public.site_profiles (id),"),
    ('sp-user-cascade', SP, "user_id uuid references auth.users (id) on delete cascade,\n  -- Business tied", "user_id uuid references auth.users (id),\n  -- Business tied"),
]
