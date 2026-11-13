# Mutants for the team access checks in 20261101110000_social_profiles.sql (profile_is_owner, profile_is_mine, profile_has_permission, profile_require_permission):
#   python3 tests/db/tools/mutate_migrations.py tests/db/tools/mutants_team_access.py --jobs 3
# Run from the repository root. They replay every migration from the profile one on, so they are slower than the rest.
import os

TARGET = '20261101110000'
TESTS = ['570_venue_hire_teams.sql', '490_social_profiles.sql', '560_service_marketplace.sql']
SLOW = []
FILE = '20261101110000_social_profiles.sql'
_SRC = open(os.path.join(os.getcwd(), 'supabase', 'migrations', FILE)).read()


def A(mid, fn, old, new):
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


MUTANTS = [
    A('own-user-id', 'profile_is_owner', "p.user_id = auth.uid()\n        or", "false\n        or"),
    A('own-org-role', 'profile_is_owner', "public.is_org_member(p.org_id, array['owner', 'organizer'])", "public.is_org_member(p.org_id, array['owner', 'organizer', 'manager'])"),
    A('mine-team', 'profile_is_mine', "or (auth.uid() is not null and exists (select 1 from public.site_profile_team t where t.profile = p_profile and t.member = auth.uid() and t.status = 'active'))", ""),
    A('mine-team-status', 'profile_is_mine', "t.member = auth.uid() and t.status = 'active'))", "t.member = auth.uid() and t.status in ('active', 'invited')))"),
    A('mine-team-member', 'profile_is_mine', "t.profile = p_profile and t.member = auth.uid() and t.status = 'active'))", "t.profile = p_profile and t.status = 'active'))"),
    A('perm-owner', 'profile_has_permission', "select public.profile_is_owner(p_profile)\n      or", "select false\n      or"),
    A('perm-member', 'profile_has_permission', "t.profile = p_profile and t.member = auth.uid() and t.status = 'active' and p_permission = any (t.permissions)))", "t.profile = p_profile and t.status = 'active' and p_permission = any (t.permissions)))"),
    A('perm-status', 'profile_has_permission', "t.member = auth.uid() and t.status = 'active' and p_permission = any (t.permissions)))", "t.member = auth.uid() and t.status in ('active', 'invited') and p_permission = any (t.permissions)))"),
    A('perm-kind', 'profile_has_permission', "and p_permission = any (t.permissions)))", "))"),
    A('perm-require', 'profile_require_permission', "if not public.profile_has_permission(p_actor, p_permission) then", "if false then"),
    A('perm-actor', 'profile_require_permission', "perform public.profile_require_actor(p_actor);\n  if not", "if not"),
    A('upd-perm', 'profile_update_business', "perform public.profile_require_permission(p_profile, 'content');", "perform public.profile_require_actor(p_profile);"),
]
