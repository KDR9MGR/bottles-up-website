# Mutants for 20261104100000_inbox_notifications.sql:
#   python3 tests/db/tools/mutate_migrations.py tests/db/tools/mutants_inbox_notifications.py --jobs 3
# Run from the repository root.
import os

TARGET = '20261104100000'
TESTS = ['520_inbox_notifications.sql']
SLOW = []
FILE = '20261104100000_inbox_notifications.sql'
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


# Known equivalent (so it survives, by design): closed-other-only. dm_direct_closed joins the conversation's members without excluding the actor, but the actor is always in
# good standing here (profile_require_actor) and never blocks themselves, so including them changes nothing.
# Known equivalent changes (nothing in the database can tell them apart), kept out on purpose: every caller checks the profile is in good standing before asking whether it
# is a member (member-acts), and a tag on an event or venue has no profile to tell, so notify_profile returns at once (tag-profile-only).
MUTANTS = [
    # who is in
    M('member-left', 'dm_is_member', "m.status in ('active', 'request')", "m.status in ('active', 'request', 'left')"),
    M('status-follow', 'dm_new_member_status', "f.follower = p_member and f.followed = p_inviter and f.status = 'active'", "f.follower = p_inviter and f.followed = p_member and f.status = 'active'"),
    M('status-pending', 'dm_new_member_status', "and f.status = 'active') then 'active' else 'request' end", ") then 'active' else 'request' end"),
    # starting
    M('direct-flag', 'dm_start_direct', "perform public.dm_require_inbox();\n", ""),
    M('direct-self', 'dm_start_direct', "if p_other is null or p_other = p_actor or public.profile_is_mine(p_other) then", "if p_other is null or p_other = p_actor then"),
    M('direct-blocked', 'dm_start_direct', "if not public.profile_visible(p_actor, p_other) then raise exception 'This profile isn''t available.'; end if;", ""),
    M('direct-key', 'dm_start_direct', "v_key := least(p_actor::text, p_other::text) || ':' || greatest(p_actor::text, p_other::text);", "v_key := p_actor::text || ':' || p_other::text;"),
    M('direct-status', 'dm_start_direct', "values (v_id, p_other, public.dm_new_member_status(p_actor, p_other))", "values (v_id, p_other, 'active')"),
    M('group-name', 'dm_start_group', "if char_length(v_title) < 1 or char_length(v_title) > 60 then", "if false then"),
    M('group-words', 'dm_start_group', "if not public.social_text_ok(v_title) then raise exception 'That text goes against our community rules.'; end if;", ""),
    M('group-min', 'dm_start_group', "if cardinality(v_members) < 1 then", "if false then"),
    M('group-max', 'dm_start_group', "if cardinality(v_members) > 49 then", "if cardinality(v_members) > 50 then"),
    M('group-visible', 'dm_start_group', "if public.profile_is_mine(v_m) or not public.profile_visible(p_actor, v_m) then", "if public.profile_is_mine(v_m) then"),
    M('group-admin', 'dm_start_group', "values (v_id, p_actor, 'admin', 'active')", "values (v_id, p_actor, 'member', 'active')"),
    M('group-status', 'dm_start_group', "values (v_id, v_m, public.dm_new_member_status(p_actor, v_m))", "values (v_id, v_m, 'active')"),
    M('add-admin', 'dm_group_add', "and m.profile = p_actor and m.role = 'admin' and m.status = 'active') then", "and m.profile = p_actor and m.status = 'active') then"),
    M('add-visible', 'dm_group_add', "if p_member is null or public.profile_is_mine(p_member) or not public.profile_visible(p_actor, p_member) then", "if p_member is null or public.profile_is_mine(p_member) then"),
    M('add-max', 'dm_group_add', "m.status <> 'left') >= 50 then", "m.status <> 'left') >= 51 then"),
    M('add-rejoin', 'dm_group_add', "where public.site_dm_members.status = 'left';", ";"),
    M('remove-admin', 'dm_group_remove', "and m.profile = p_actor and m.role = 'admin' and m.status = 'active') then", "and m.profile = p_actor and m.status = 'active') then"),
    M('remove-self', 'dm_group_remove', "if p_member = p_actor or public.profile_is_mine(p_member) then", "if false then"),
    M('rename-admin', 'dm_group_rename', "and m.profile = p_actor and m.role = 'admin' and m.status = 'active') then", "and m.profile = p_actor and m.status = 'active') then"),
    M('rename-words', 'dm_group_rename', "if not public.social_text_ok(v_title) then raise exception 'That text goes against our community rules.'; end if;", ""),
    M('leave-group-only', 'dm_leave', "if not exists (select 1 from public.site_dm_conversations c where c.id = p_conversation and c.kind = 'group') then raise exception 'You can only leave a group.'; end if;", ""),
    M('leave-promote', 'dm_leave', "if v_next is not null then update public.site_dm_members set role = 'admin' where conversation = p_conversation and profile = v_next; end if;", ""),
    M('leave-demote', 'dm_leave', "set status = 'left', role = 'member'", "set status = 'left'"),
    M('booking-owner', 'dm_start_booking', "and lower(b.customer_email) = lower(coalesce(auth.email(), '')) and coalesce(auth.email(), '') <> '';", ";"),
    M('booking-paid', 'dm_start_booking', "where b.id = p_booking and b.status = 'paid' and", "where b.id = p_booking and"),
    M('booking-business', 'dm_start_booking', "if exists (select 1 from public.site_profiles s where s.id = p_actor and s.kind = 'business') then raise exception 'Only a person''s own profile can message about a booking.'; end if;", ""),
    M('booking-venue-profile', 'dm_start_booking', "if v_venue_profile is null then raise exception 'This venue has not set up messages yet.'; end if;", ""),
    M('booking-first-message', 'dm_start_booking', "insert into public.site_dm_messages (conversation, sender, kind, ref_id) values (v_id, p_actor, 'booking', p_booking);", ""),
    # sending
    M('send-rules', 'dm_send', "perform public.social_require_rules();\n", ""),
    M('send-flag', 'dm_send', "perform public.dm_require_inbox();\n", ""),
    M('send-member', 'dm_send', "if not found or not public.dm_is_member(p_actor, p_conversation) then", "if not found then"),
    M('send-closed', 'dm_send', "if public.dm_direct_closed(p_actor, p_conversation) then", "if false then"),
    M('send-retry', 'dm_send', "if v_id is not null then return public.dm_message_card(p_actor, v_id); end if;", ""),
    M('send-empty', 'dm_send', "if v_body is null then raise exception 'Write something first.'; end if;", ""),
    M('send-post-visible', 'dm_send', "if v_kind = 'post' and not public.post_visible(p_actor, p_ref_id) then raise exception 'You cannot share that post.'; end if;", ""),
    M('send-event-published', 'dm_send', "e.id = p_ref_id and e.status = 'published'", "e.id = p_ref_id"),
    M('send-venue-published', 'dm_send', "v.id = p_ref_id and v.status = 'published'", "v.id = p_ref_id"),
    M('send-booking-own', 'dm_send', "if v_kind = 'booking' and not (v_conv.kind = 'booking' and v_conv.booking_id = p_ref_id) then", "if v_kind = 'booking' and false then"),
    M('send-length', 'dm_send', "case when v_kind = 'text' then 2000 else 500 end) then", "case when v_kind = 'text' then 2001 else 500 end) then"),
    M('send-words', 'dm_send', "if not public.social_text_ok(v_body) then raise exception 'That text goes against our community rules.'; end if;", ""),
    M('send-rate', 'dm_send', ">= 30 then", ">= 31 then"),
    M('send-request-cap', 'dm_send', ">= 3 then\n      raise exception 'Wait for them to reply before sending more.';", ">= 4 then\n      raise exception 'Wait for them to reply before sending more.';"),
    M('send-accept', 'dm_send', "update public.site_dm_members set status = 'active', last_read_at = clock_timestamp() where conversation = p_conversation and profile = p_actor;", "update public.site_dm_members set last_read_at = clock_timestamp() where conversation = p_conversation and profile = p_actor;"),
    M('send-touch', 'dm_send', "update public.site_dm_conversations set last_message_at = clock_timestamp() where id = p_conversation;", ""),
    # reading
    M('read-member', 'dm_messages', "if not public.dm_is_member(p_actor, p_conversation) or public.dm_direct_closed(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;\n  return coalesce((\n    select jsonb_agg(public.dm_message_card", "return coalesce((\n    select jsonb_agg(public.dm_message_card"),
    M('read-closed', 'dm_messages', "if not public.dm_is_member(p_actor, p_conversation) or public.dm_direct_closed(p_actor, p_conversation) then", "if not public.dm_is_member(p_actor, p_conversation) then"),
    M('read-joined', 'dm_messages', "and m.created_at >= (select mm.joined_at from public.site_dm_members mm where mm.conversation = p_conversation and mm.profile = p_actor)", ""),
    M('read-paging', 'dm_messages', "(m.created_at, m.id) < (p_before,", "(m.created_at, m.id) > (p_before,"),
    M('card-removed', 'dm_message_card', "'body', case when m.deleted_at is null then m.body end,", "'body', m.body,"),
    M('card-ref-removed', 'dm_message_card', "case when m.deleted_at is null and m.kind <> 'text' then", "case when m.kind <> 'text' then"),
    M('ref-post', 'dm_ref_card', "if p_ref is not null and public.post_visible(p_viewer, p_ref) then", "if p_ref is not null then"),
    M('ref-event', 'dm_ref_card', "from public.site_events e where e.id = p_ref and e.status = 'published'", "from public.site_events e where e.id = p_ref"),
    M('ref-booking-code', 'dm_ref_card', "'status', b.status)", "'status', b.status, 'code', b.confirmation_code, 'paid', b.amount_paid_cents)"),
    M('inbox-box', 'dm_inbox', "((v_box = 'main' and m.status = 'active') or (v_box = 'requests' and m.status = 'request'))", "(m.status in ('active', 'request'))"),
    M('inbox-closed', 'dm_inbox', "and not public.dm_direct_closed(p_actor, c.id)", ""),
    M('inbox-unread-own', 'dm_conversation_json', "um.deleted_at is null and um.sender <> p_actor and um.created_at > m.last_read_at", "um.deleted_at is null and um.created_at > m.last_read_at"),
    M('inbox-unread-deleted', 'dm_conversation_json', "um.conversation = c.id and um.deleted_at is null and um.sender <> p_actor", "um.conversation = c.id and um.sender <> p_actor"),
    M('inbox-order', 'dm_inbox', "order by x.last_message_at desc, x.id desc)", "order by x.last_message_at, x.id)"),
    M('conversation-member', 'dm_conversation', "if not public.dm_is_member(p_actor, p_conversation) or public.dm_direct_closed(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;\n  return public.dm_conversation_json", "return public.dm_conversation_json"),
    M('conversation-closed', 'dm_conversation', "if not public.dm_is_member(p_actor, p_conversation) or public.dm_direct_closed(p_actor, p_conversation) then", "if not public.dm_is_member(p_actor, p_conversation) then"),
    # a direct conversation is closed for a person who is suspended or blocked either way, and only a direct one
    M('closed-suspended', 'dm_direct_closed', "(s.status <> 'active' or public.profile_blocked_between(p_actor, o.profile))", "(public.profile_blocked_between(p_actor, o.profile))"),
    M('closed-blocked', 'dm_direct_closed', "(s.status <> 'active' or public.profile_blocked_between(p_actor, o.profile))", "(s.status <> 'active')"),
    M('closed-direct-only', 'dm_direct_closed', "where c.id = p_conversation and c.kind = 'direct'", "where c.id = p_conversation"),
    M('closed-other-only', 'dm_direct_closed', "join public.site_dm_members o on o.conversation = c.id and o.profile <> p_actor", "join public.site_dm_members o on o.conversation = c.id"),
    M('inbox-paging', 'dm_inbox', "(c.last_message_at, c.id) < (p_before,", "(c.last_message_at, c.id) > (p_before,"),
    M('inbox-box-check', 'dm_inbox', "if v_box not in ('main', 'requests') then raise exception 'Choose main or requests.'; end if;", ""),
    M('read-mark-member', 'dm_mark_read', "if not public.dm_is_member(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;\n  update", "update"),
    M('mute-member', 'dm_mute', "if not public.dm_is_member(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;\n  update", "update"),
    M('answer-needs-request', 'dm_answer_request', "m.profile = p_actor and m.status = 'request') then", "m.profile = p_actor) then"),
    M('answer-decline', 'dm_answer_request', "set status = case when p_accept then 'active' else 'left' end", "set status = 'active'"),
    M('delete-own', 'dm_delete_message', "if v_sender is null or v_sender <> p_actor or not public.dm_is_member(p_actor, v_conv) then", "if v_sender is null then"),
    M('people-member', 'dm_people', "if not public.dm_is_member(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;\n  return coalesce((\n    select jsonb_agg(public.profile_mini(m.profile)", "return coalesce((\n    select jsonb_agg(public.profile_mini(m.profile)"),
    M('unread-muted', 'dm_unread', "where m.profile = p_actor and m.status = 'active' and not m.muted and not public.dm_direct_closed(p_actor, m.conversation)", "where m.profile = p_actor and m.status = 'active' and not public.dm_direct_closed(p_actor, m.conversation)"),
    M('unread-closed', 'dm_unread', "and not m.muted and not public.dm_direct_closed(p_actor, m.conversation)", "and not m.muted"),
    M('unread-requests-closed', 'dm_unread', "m.status = 'request' and not public.dm_direct_closed(p_actor, m.conversation)", "m.status = 'request'"),
    M('unread-requests', 'dm_unread', "where m.profile = p_actor and m.status = 'request' and", "where m.profile = p_actor and m.status = 'active' and"),
    # notifications
    M('notify-self', 'notify_profile', "if p_recipient is null or p_actor is null or p_recipient = p_actor then return; end if;", "if p_recipient is null or p_actor is null then return; end if;"),
    M('notify-blocked', 'notify_profile', "if public.profile_blocked_between(p_recipient, p_actor) then return; end if;", ""),
    M('notify-suspended', 'notify_profile', "if not exists (select 1 from public.site_profiles s where s.id = p_recipient and s.status = 'active') then return; end if;", ""),
    M('notify-once', 'notify_profile', "on conflict (recipient, dedupe_key) do nothing;", "on conflict (recipient, dedupe_key) do update set read_at = null;"),
    M('follow-kind', 'notify_on_follow', "case new.status when 'active' then 'follow' else 'follow_request' end", "'follow'"),
    M('follow-accepted', 'notify_on_follow', "perform public.notify_profile(new.follower, 'follow_accepted', new.followed);", ""),
    M('like-story', 'notify_on_like', "where p.id = new.post and p.kind <> 'story'", "where p.id = new.post"),
    M('comment-reply', 'notify_on_comment', "perform public.notify_profile((select c.author from public.site_comments c where c.id = new.reply_to), 'reply', new.author, new.post, new.id);", "perform public.notify_profile((select p.author from public.site_posts p where p.id = new.post), 'reply', new.author, new.post, new.id);"),
    M('tag-visible', 'notify_on_tag', "if public.post_visible(new.profile_id, new.post) then", "if true then"),
    M('list-blocked', 'notifications_list', "and not public.profile_blocked_between(p_actor, x.actor)", ""),
    M('list-suspended', 'notifications_list', "join public.site_profiles s on s.id = x.actor and s.status = 'active'", "join public.site_profiles s on s.id = x.actor"),
    M('list-post-visible', 'notifications_list', "case when n.post is not null and public.post_visible(p_actor, n.post) then", "case when n.post is not null then"),
    M('list-paging', 'notifications_list', "(x.created_at, x.id) < (p_before,", "(x.created_at, x.id) > (p_before,"),
    M('list-order', 'notifications_list', "order by n.created_at desc, n.id desc)", "order by n.created_at, n.id)"),
    M('unread-hidden', 'notifications_unread', "where n.recipient = p_actor and n.read_at is null and not public.profile_blocked_between(p_actor, n.actor)", "where n.recipient = p_actor and n.read_at is null"),
    M('read-upto', 'notifications_read', "and (p_up_to is null or created_at <= p_up_to)", ""),
    M('purge-read', 'notifications_purge', "where read_at is not null and created_at", "where created_at"),
    # surface
    ('grant-member', FILE, "public.notifications_list(uuid, int, timestamptz, uuid), public.notifications_unread(uuid), public.notifications_read(uuid, timestamptz)\nto authenticated, service_role;", "public.notifications_list(uuid, int, timestamptz, uuid), public.notifications_unread(uuid), public.notifications_read(uuid, timestamptz), public.dm_is_member(uuid, uuid)\nto authenticated, service_role;"),
    ('grant-purge', FILE, "grant execute on function public.notifications_purge(int) to service_role;", "grant execute on function public.notifications_purge(int) to authenticated, service_role;"),
    ('tables-open', FILE, "revoke all on table public.site_dm_conversations, public.site_dm_members, public.site_dm_messages, public.site_notifications from public, anon, authenticated;", "revoke all on table public.site_dm_conversations, public.site_dm_members, public.site_dm_messages from public, anon, authenticated;"),
    ('booking-cascade', FILE, "booking_id uuid references public.site_table_bookings (id) on delete cascade,", "booking_id uuid references public.site_table_bookings (id),"),
]
