-- Data, not a shape, for 20261101110000_social_profiles.sql: two people who already have a username when that migration arrives (production has them: the
-- profiles table has had a username column since 20261007100000), so the test can prove the migration puts every existing username on the new one-list-of-names.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000004f1', 'early@soc.example'),
  ('00000000-0000-0000-0000-0000000004f2', 'owl@soc.example');
insert into public.profiles (id, name, email, username) values
  ('00000000-0000-0000-0000-0000000004f1', 'Early Bird', 'early@soc.example', 'preexisting.one'),
  ('00000000-0000-0000-0000-0000000004f2', 'Night Owl', 'owl@soc.example', 'preexisting.two');
