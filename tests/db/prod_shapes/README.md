# Production-only shapes

Some tables and columns exist only in the production database: they were made by hand or by a migration that was never committed
here (`supabase db pull` has not been run yet). A migration that builds on them cannot be replayed on an empty test database.

A file named `<migration timestamp>_<anything>.sql` in this folder is applied by `tests/db/run.sh` **right before** the migration with
that timestamp. It creates the minimum shape that migration assumes, copied from what production reported (the read-only script
`supabase/audit/06_server_desk_definitions.sql`, run on 14 Oct 2026), and nothing else.

When `supabase db pull` brings the real definitions into `supabase/migrations`, delete the matching file here.
Nothing in this folder is ever applied to a real project.
