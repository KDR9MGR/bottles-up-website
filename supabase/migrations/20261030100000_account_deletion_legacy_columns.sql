-- Account deletion, the rest: five columns of older tables that 20261029100000 could not cover because no migration in this repository defines them (they exist only in production).
--
-- The read-only audit supabase/audit/18_account_deletion_blockers.sql, run on production on 23 Oct 2026 AFTER 20261029100000 was applied, still listed these five:
--   * admin_audit_log.admin_id          -> auth.users   NOT NULL and "on delete set null" at once: deleting an admin who has audit rows raises "null value violates not-null"
--   * conversations.created_by          -> auth.users   no rule: the person who started a conversation cannot be deleted
--   * event_rsvps.verified_by           -> auth.users   no rule: the staff member who verified a guest-list entry cannot be deleted
--   * vendor_onboarding_data.referrer_id -> vendors     no rule: a vendor who referred another vendor cannot be deleted (their vendors row goes with their account)
--   * venues.manager_id                 -> profiles     no rule: the manager of a (classic) venue cannot be deleted (their profiles row goes with their account)
--
-- Fix, the same as before: the record stays and only the person goes. Each becomes nullable with ON DELETE SET NULL (admin_audit_log.admin_id keeps its rule and loses NOT NULL,
-- which is what makes the rule able to work). The admin log's rows keep their action, target and before/after snapshots; a venue keeps existing without a manager.
--
-- These tables are not defined here, so this file does not trust a shape it cannot see. For each column, when the table and column exist:
--   * the foreign key must point where the audit found it (auth.users, vendors, profiles), is not deferrable, and exists exactly once on that column;
--   * no CHECK constraint, primary key, unique index or partial-index condition may involve the column (setting it to null could break such a rule; nothing here knows what it means);
-- otherwise the migration stops with a message naming it and NOTHING is changed (one statement). A table or column that does not exist is skipped (a database that never had the
-- older tables); a column already fixed is skipped, so it is safe to run twice.
-- It does not look at triggers it cannot see the purpose of; it names the ones on these tables in a notice so they can be read. Locks give up after 10 seconds.

do $migration$
declare
  r record;
  v_rel regclass;
  v_attnum smallint;
  v_notnull boolean;
  v_fk record;
  v_nfk int;
  v_bad text;
  v_refcol name;
  v_fixed int := 0;
  v_nullable int := 0;
  v_trg text;
  v_left text;
begin
  perform set_config('lock_timeout', '10s', true);

  if to_regclass('auth.users') is null then raise exception 'auth.users does not exist. Nothing was changed.'; end if;

  for r in select * from (values
    ('admin_audit_log',        'admin_id',    'auth.users'),
    ('conversations',          'created_by',  'auth.users'),
    ('event_rsvps',            'verified_by', 'auth.users'),
    ('vendor_onboarding_data', 'referrer_id', 'public.vendors'),
    ('venues',                 'manager_id',  'public.profiles')
  ) as x(tbl, col, target) loop
    v_rel := to_regclass('public.' || r.tbl);
    if v_rel is null then raise notice 'skipped: public.% does not exist', r.tbl; continue; end if;
    select a.attnum, a.attnotnull into v_attnum, v_notnull from pg_attribute a where a.attrelid = v_rel and a.attname = r.col and not a.attisdropped;
    if not found then raise notice 'skipped: public.% has no column %', r.tbl, r.col; continue; end if;

    select count(*) into v_nfk from pg_constraint c where c.conrelid = v_rel and c.contype = 'f' and v_attnum = any (c.conkey);
    if v_nfk = 0 then raise notice 'skipped: %.% is not a foreign key', r.tbl, r.col; continue; end if;
    select c.conname, c.confdeltype, c.confrelid, c.confkey, c.condeferrable, array_length(c.conkey, 1) as ncols into v_fk
      from pg_constraint c where c.conrelid = v_rel and c.contype = 'f' and v_attnum = any (c.conkey) limit 1;
    if v_nfk > 1 or v_fk.ncols <> 1 then
      raise exception 'public.%.% is part of % foreign keys (or of one over several columns); this file does not know what to do with that. Nothing was changed.', r.tbl, r.col, v_nfk;
    end if;
    if v_fk.confrelid <> to_regclass(r.target) then
      raise exception 'public.%.% points at %, not at % as the audit found. Nothing was changed.', r.tbl, r.col, v_fk.confrelid::regclass, r.target;
    end if;
    if v_fk.condeferrable then raise exception 'the foreign key % on public.% is deferrable; this file does not know what to do with that. Nothing was changed.', v_fk.conname, r.tbl; end if;

    select string_agg(what, '; ') into v_bad from (
      select 'CHECK ' || c.conname as what from pg_constraint c where c.conrelid = v_rel and c.contype = 'c' and v_attnum = any (c.conkey)
      union all select 'constraint ' || c.conname from pg_constraint c where c.conrelid = v_rel and c.contype in ('p', 'u', 'x') and v_attnum = any (c.conkey)
      union all select 'unique index ' || i.indexrelid::regclass::text from pg_index i where i.indrelid = v_rel and i.indisunique and v_attnum = any (i.indkey::smallint[])
      union all select 'index condition on ' || i.indexrelid::regclass::text from pg_index i where i.indrelid = v_rel and i.indpred is not null and pg_get_expr(i.indpred, i.indrelid) ~ ('\m' || r.col || '\M')
    ) q;
    if v_bad is not null then
      raise exception 'public.%.% is involved in a rule this file cannot judge (%); setting it to null might break it. Nothing was changed.', r.tbl, r.col, v_bad;
    end if;

    if v_fk.confdeltype in ('a', 'r') then
      select a.attname into v_refcol from pg_attribute a where a.attrelid = v_fk.confrelid and a.attnum = v_fk.confkey[1];
      execute format('alter table public.%I drop constraint %I, add constraint %I foreign key (%I) references %s (%I) on delete set null',
                     r.tbl, v_fk.conname, v_fk.conname, r.col, v_fk.confrelid::regclass, v_refcol);
      v_fixed := v_fixed + 1;
    elsif v_fk.confdeltype <> 'n' then
      raise notice 'left alone: %.% already has an on-delete rule (%)', r.tbl, r.col, v_fk.confdeltype;
      continue;
    end if;
    if v_notnull then execute format('alter table public.%I alter column %I drop not null', r.tbl, r.col); v_nullable := v_nullable + 1; end if;
  end loop;

  select string_agg(t.tgrelid::regclass::text || '.' || t.tgname, ', ' order by t.tgrelid::regclass::text, t.tgname) into v_trg
    from pg_trigger t
   where not t.tgisinternal and t.tgrelid in (select to_regclass('public.' || x) from unnest(array['admin_audit_log', 'conversations', 'event_rsvps', 'vendor_onboarding_data', 'venues']) x where to_regclass('public.' || x) is not null);

  -- everything deleted together with the person, then whatever cascades from those: anything still without an on-delete rule is named, not guessed at
  with recursive gone(rel) as (
    select 'auth.users'::regclass
    union
    select c.conrelid from pg_constraint c join gone on c.confrelid = gone.rel where c.contype = 'f' and c.confdeltype = 'c'
  )
  select string_agg(c.conrelid::regclass::text || '.' || a.attname, ', ' order by c.conrelid::regclass::text, a.attname) into v_left
    from pg_constraint c join gone on c.confrelid = gone.rel join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
   where c.contype = 'f' and (c.confdeltype in ('a', 'r') or (c.confdeltype = 'n' and a.attnotnull));
  raise notice 'account deletion (older tables): % foreign keys changed to set null, % columns made nullable. Triggers on these tables, to be read: %. Still in the way: %', v_fixed, v_nullable, coalesce(v_trg, 'none'), coalesce(v_left, 'none');
end
$migration$;
