-- Account deletion: a person who ever acted can be deleted (Apple requires in-app account deletion to work, and the vendor app offers it).
--
-- The delete-account edge function calls auth.admin.deleteUser, which is DELETE FROM auth.users. 51 columns point at auth.users with NO "on delete" rule (so: refuse), and every
-- one of them says "who did this": the door staff who scanned a ticket (scan_attempts.scanned_by) or checked someone in, the person who accepted an invitation, who created a
-- business (site_organizations.created_by), who recorded a payment flag, a chat message, a stock movement, an audit row... Anyone who ever did any of those got "Failed to delete account".
-- One more sits one step away: deleting the person also deletes their membership (that already cascades), and the invitation they accepted points at that membership
-- (site_invitations.membership_id, no rule), so EVERY invited staff member was refused, whether or not they ever did anything else.
--
-- Fix: every such column becomes ON DELETE SET NULL. The record stays and still says what happened, when, and to what; only the person is gone. audit_log.actor_email stays as it is.
--   * 23 of the columns were NOT NULL ("always say who"); they become nullable. scan_attempts.scanned_by is one of them. Anonymising (pointing them at a placeholder account) was
--     rejected: it needs a fake row in auth.users plus a trigger on the auth schema, and a second deletion would trip the "not their own" checks below (both sides become the placeholder).
--   * 10 CHECK constraints tie the person to the state ("resolved" means resolved_by AND resolved_at are set; "a handover cannot be received by the person who handed it over").
--     SET NULL would break every one of them, so each is replaced by "the old rule, OR the same state with the person gone". A rule is only ever relaxed, never tightened, so every
--     existing row still passes. The function that sets the state still sets the person, as before.
--   * site_invitations.membership_id becomes ON DELETE SET NULL: the invitation stays, accepted, without the membership that went with the person.
--   * Readers need no change: they already left-join profiles and show 'Staff member' / nothing for a missing person. (A row that loses its person is updated once, so a table's
--     own updated_at trigger moves that row's updated_at to the day of the deletion; nothing else about the row changes.)
--
-- Not changed: foreign keys that already cascade or set null; anything that is not a foreign key to auth.users.
--
-- Tables from branches that are not in this database yet (the 14 marked "later" below: refunds, payouts, discounts, table blocks, moves) are skipped when absent. Run this migration
-- again after those arrive: it is safe to repeat (a column already fixed is skipped; a CHECK already replaced is recognised).
--
-- Guards (nothing is changed unless all of them hold): the five core tables exist; each CHECK being replaced is exactly what the earlier migrations created (compared without
-- case, spaces, brackets and casts), or already the replacement; any other shape stops the migration with the actual text in the message. One statement, so all or nothing.
-- A foreign key is re-added under its own name; locks on auth.users are short (small tables) and give up after 10 seconds instead of queueing behind a long transaction.

do $migration$
declare
  r record;
  v_oid oid;
  v_attnum smallint;
  v_notnull boolean;
  v_fk record;
  v_fixed int := 0;
  v_relaxed int := 0;
  v_left text;
  norm constant text := $n$regexp_replace(regexp_replace(lower(%s), '::[a-z]+', '', 'g'), '[^a-z0-9_]', '', 'g')$n$;
  v_cur text;
  v_old text;
  v_new text;
begin
  perform set_config('lock_timeout', '10s', true);

  if to_regclass('auth.users') is null then raise exception 'auth.users does not exist. Nothing was changed.'; end if;
  for r in select * from (values ('site_orders'), ('guest_tickets'), ('scan_attempts'), ('audit_log'), ('site_invitations')) as x(t) loop
    if to_regclass('public.' || r.t) is null then raise exception 'public.% does not exist: run the earlier migrations first. Nothing was changed.', r.t; end if;
  end loop;

  ------------------------------------------------------------------------------------------------ 1. the CHECK constraints that tie a person to a state
  -- (table, constraint, the rule the earlier migrations created (as the catalog prints it), the replacement = the old rule OR the same state with the person gone)
  for r in select * from (values
    ('site_cash_handovers', 'site_cash_handovers_not_own',
       'received_by IS DISTINCT FROM from_user',
       'received_by is null or from_user is null or received_by <> from_user'),
    ('site_cash_handovers', 'site_cash_handovers_received_together',
       '((status = ''submitted''::text) AND (received_by IS NULL) AND (received_at IS NULL) AND (counted_cents IS NULL)) OR ((status = ''acknowledged''::text) AND (received_by IS NOT NULL) AND (received_at IS NOT NULL) AND (counted_cents IS NOT NULL))',
       '(status = ''submitted'' and received_by is null and received_at is null and counted_cents is null) or (status = ''acknowledged'' and received_by is not null and received_at is not null and counted_cents is not null) or (status = ''acknowledged'' and received_by is null and received_at is not null and counted_cents is not null)'),
    ('site_payment_flags', 'site_payment_flags_resolved_together',
       '((status = ''open''::text) AND (resolved_by IS NULL) AND (resolved_at IS NULL) AND (resolution IS NULL)) OR ((status = ''resolved''::text) AND (resolved_by IS NOT NULL) AND (resolved_at IS NOT NULL) AND (resolution IS NOT NULL))',
       '(status = ''open'' and resolved_by is null and resolved_at is null and resolution is null) or (status = ''resolved'' and resolved_by is not null and resolved_at is not null and resolution is not null) or (status = ''resolved'' and resolved_by is null and resolved_at is not null and resolution is not null)'),
    ('site_security_alerts', 'site_security_alerts_resolved_together',
       '(status = ''resolved''::text) = ((resolved_by IS NOT NULL) AND (resolved_at IS NOT NULL))',
       '((status = ''resolved'') = (resolved_by is not null and resolved_at is not null)) or (status = ''resolved'' and resolved_by is null and resolved_at is not null)'),
    ('site_security_alerts', 'site_security_alerts_taken_together',
       '(status <> ALL (ARRAY[''acknowledged''::text, ''responding''::text])) OR ((acknowledged_by IS NOT NULL) AND (acknowledged_at IS NOT NULL))',
       '(status <> all (array[''acknowledged'', ''responding''])) or (acknowledged_by is not null and acknowledged_at is not null) or acknowledged_at is not null'),
    ('site_security_incidents', 'site_security_incidents_not_own_review',
       'reviewed_by IS DISTINCT FROM reported_by',
       'reviewed_by is null or reported_by is null or reviewed_by <> reported_by'),
    ('site_security_incidents', 'site_security_incidents_reviewed_together',
       '(status = ''reviewed''::text) = ((reviewed_by IS NOT NULL) AND (reviewed_at IS NOT NULL))',
       '((status = ''reviewed'') = (reviewed_by is not null and reviewed_at is not null)) or (status = ''reviewed'' and reviewed_by is null and reviewed_at is not null)'),
    ('site_security_tasks', 'site_security_tasks_closed_together',
       '(status = ''open''::text) = ((closed_by IS NULL) AND (closed_at IS NULL))',
       '((status = ''open'') = (closed_by is null and closed_at is null)) or (status <> ''open'' and closed_by is null and closed_at is not null)'),
    ('site_night_closes', 'site_night_closes_reopened_together',
       '(status = ''reopened''::text) = ((reopened_by IS NOT NULL) AND (reopened_at IS NOT NULL))',
       '((status = ''reopened'') = (reopened_by is not null and reopened_at is not null)) or (status = ''reopened'' and reopened_by is null and reopened_at is not null)'),
    ('site_vip_members', 'site_vip_ended_together',
       '(ended_at IS NULL) = (ended_by IS NULL)',
       '((ended_at is null) = (ended_by is null)) or (ended_at is not null and ended_by is null)'),
    -- later: 20261021100000 (table blocks) and 20261024100000 (staff discounts and complimentary bottles)
    ('site_table_blocks', 'site_table_blocks_release_check',
       '(released_at IS NULL) = (released_by IS NULL)',
       '((released_at is null) = (released_by is null)) or (released_at is not null and released_by is null)'),
    ('site_concessions', 'site_concessions_decided_check',
       '(decided_by IS NULL) = (decided_role IS NULL)',
       '((decided_by is null) = (decided_role is null)) or (decided_by is null and decided_role is not null)')
  ) as x(tbl, con, old_rule, new_rule) loop
    if to_regclass('public.' || r.tbl) is null then continue; end if;   -- a table from a branch that is not here yet
    select pg_get_constraintdef(c.oid) into v_cur from pg_constraint c where c.conrelid = to_regclass('public.' || r.tbl) and c.conname = r.con and c.contype = 'c';
    if v_cur is null then
      raise notice 'skipped: % has no constraint %', r.tbl, r.con;
      continue;
    end if;
    execute format('select ' || norm, quote_literal(v_cur)) into v_cur;
    execute format('select ' || norm, quote_literal('CHECK (' || r.old_rule || ')')) into v_old;
    execute format('select ' || norm, quote_literal('CHECK (' || r.new_rule || ')')) into v_new;
    if v_cur = v_new then continue; end if;   -- already replaced
    if v_cur <> v_old then
      raise exception 'constraint % on % is not what the earlier migrations created (now: %); it was not replaced and nothing was changed. Compare it with this file and adjust by hand.',
        r.con, r.tbl, (select pg_get_constraintdef(c.oid) from pg_constraint c where c.conrelid = to_regclass('public.' || r.tbl) and c.conname = r.con);
    end if;
    execute format('alter table public.%I drop constraint %I, add constraint %I check (%s)', r.tbl, r.con, r.con, r.new_rule);
    v_relaxed := v_relaxed + 1;
  end loop;

  ------------------------------------------------------------------------------------------------ 2. every "who did it" column: nullable, ON DELETE SET NULL
  for r in select * from (values
    ('audit_log', 'actor_id'),
    ('guest_tickets', 'checked_in_by'),
    ('scan_attempts', 'scanned_by'),
    ('site_agreement_notes', 'author_id'),
    ('site_agreement_versions', 'organizer_accepted_by'),
    ('site_agreement_versions', 'proposed_by'),
    ('site_agreement_versions', 'venue_accepted_by'),
    ('site_agreements', 'closed_by'),
    ('site_agreements', 'requested_by'),
    ('site_booking_seating', 'estimate_set_by'),
    ('site_booking_seating', 'seated_by'),
    ('site_booking_servers', 'assigned_by'),
    ('site_cash_handovers', 'from_user'),
    ('site_cash_handovers', 'received_by'),
    ('site_chat_messages', 'sender_id'),
    ('site_invitations', 'accepted_by'),
    ('site_invitations', 'invited_by'),
    ('site_invitations', 'revoked_by'),
    ('site_memberships', 'invited_by'),
    ('site_memberships', 'revoked_by'),
    ('site_night_checks', 'checked_by'),
    ('site_night_closes', 'closed_by'),
    ('site_night_closes', 'reopened_by'),
    ('site_orders', 'checked_in_by'),
    ('site_organizations', 'created_by'),
    ('site_payment_flags', 'raised_by'),
    ('site_payment_flags', 'resolved_by'),
    ('site_security_alerts', 'acknowledged_by'),
    ('site_security_alerts', 'escalated_by'),
    ('site_security_alerts', 'raised_by'),
    ('site_security_alerts', 'resolved_by'),
    ('site_security_incident_notes', 'author_id'),
    ('site_security_incidents', 'reported_by'),
    ('site_security_incidents', 'reviewed_by'),
    ('site_security_tasks', 'assigned_to'),
    ('site_security_tasks', 'closed_by'),
    ('site_security_tasks', 'created_by'),
    ('site_service_requests', 'created_by'),
    ('site_shifts', 'created_by'),
    ('site_stock_movements', 'created_by'),
    ('site_stock_thresholds', 'set_by'),
    ('site_table_bookings', 'checked_in_by'),
    ('site_venue_claims', 'requested_by'),
    ('site_venue_claims', 'reviewed_by'),
    ('site_verification_events', 'actor'),
    ('site_verifications', 'reviewed_by'),
    ('site_vip_members', 'created_by'),
    ('site_vip_members', 'ended_by'),
    ('site_vip_perks', 'created_by'),
    ('site_vip_redemptions', 'redeemed_by'),
    ('ticket_otp_codes', 'verified_by'),
    -- later: 20261021100000 (table blocks, booking moves)
    ('site_booking_moves', 'moved_by'),
    ('site_table_blocks', 'created_by'),
    ('site_table_blocks', 'released_by'),
    -- later: 20261023100000 (refund policy and requests)
    ('site_refund_policies', 'updated_by'),
    ('site_refund_requests', 'decided_by'),
    ('site_refund_requests', 'requested_by'),
    -- later: 20261024100000 (staff discounts and complimentary bottles)
    ('site_concessions', 'decided_by'),
    ('site_concessions', 'requested_by'),
    ('site_concessions', 'voided_by'),
    ('site_discount_limits', 'updated_by'),
    -- later: 20261025100000 (payout settings and ledger)
    ('site_payout_accounts', 'updated_by'),
    ('site_payout_items', 'created_by'),
    ('site_payout_overrides', 'updated_by'),
    ('site_payout_settings', 'updated_by')
  ) as x(tbl, col) loop
    v_oid := to_regclass('public.' || r.tbl);
    if v_oid is null then continue; end if;   -- a table from a branch that is not here yet
    select a.attnum, a.attnotnull into v_attnum, v_notnull from pg_attribute a where a.attrelid = v_oid and a.attname = r.col and not a.attisdropped;
    if not found then raise notice 'skipped: % has no column %', r.tbl, r.col; continue; end if;

    select c.conname, c.confdeltype into v_fk from pg_constraint c
     where c.conrelid = v_oid and c.contype = 'f' and c.confrelid = 'auth.users'::regclass and c.conkey = array[v_attnum];
    if not found then raise notice 'skipped: %.% is not a foreign key to auth.users', r.tbl, r.col; continue; end if;

    if v_fk.confdeltype in ('a', 'r') then
      execute format('alter table public.%I drop constraint %I, add constraint %I foreign key (%I) references auth.users (id) on delete set null', r.tbl, v_fk.conname, v_fk.conname, r.col);
      v_fixed := v_fixed + 1;
    elsif v_fk.confdeltype <> 'n' then
      raise notice 'left alone: %.% already has an on-delete rule (%)', r.tbl, r.col, v_fk.confdeltype;
      continue;
    end if;
    if v_notnull then execute format('alter table public.%I alter column %I drop not null', r.tbl, r.col); end if;
  end loop;

  ------------------------------------------------------------------------------------------------ 3. the invitation points at the membership that goes with the person
  if to_regclass('public.site_invitations') is not null and to_regclass('public.site_memberships') is not null then
    select c.conname, c.confdeltype into v_fk from pg_constraint c
     where c.conrelid = 'public.site_invitations'::regclass and c.contype = 'f' and c.confrelid = 'public.site_memberships'::regclass
       and c.conkey = array[(select a.attnum from pg_attribute a where a.attrelid = 'public.site_invitations'::regclass and a.attname = 'membership_id')];
    if found and v_fk.confdeltype in ('a', 'r') then
      execute format('alter table public.site_invitations drop constraint %I, add constraint %I foreign key (membership_id) references public.site_memberships (id) on delete set null', v_fk.conname, v_fk.conname);
      v_fixed := v_fixed + 1;
    end if;
  end if;

  ------------------------------------------------------------------------------------------------ 4. anything still in the way (a table this file does not know) is named, not guessed at
  -- everything deleted together with the person: their accounts, then whatever cascades from those (memberships, door staff, chat membership...)
  with recursive gone(rel) as (
    select 'auth.users'::regclass
    union
    select c.conrelid from pg_constraint c join gone on c.confrelid = gone.rel where c.contype = 'f' and c.confdeltype = 'c'
  )
  select string_agg(c.conrelid::regclass::text || '.' || a.attname, ', ' order by c.conrelid::regclass::text, a.attname) into v_left
    from pg_constraint c join gone on c.confrelid = gone.rel join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
   where c.contype = 'f' and c.confdeltype in ('a', 'r');
  raise notice 'account deletion: % foreign keys changed to set null, % checks relaxed. Still without an on-delete rule: %', v_fixed, v_relaxed, coalesce(v_left, 'none');
end
$migration$;
