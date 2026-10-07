-- Shared test data, loaded once. Test files run inside transactions that are
-- rolled back, so they can change this freely without affecting each other.
--
-- Fixed ids so tests can refer to people and events by name:
--   a1 staff (door_staff)   a2 admin (cms_admins)   a3 rando (signed in, no role)   a4 customer

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'staff@test.example'),
  ('00000000-0000-0000-0000-0000000000a2', 'admin@test.example'),
  ('00000000-0000-0000-0000-0000000000a3', 'rando@test.example'),
  ('00000000-0000-0000-0000-0000000000a4', 'customer@test.example');

insert into public.cms_admins (id, email) values ('00000000-0000-0000-0000-0000000000a2', 'admin@test.example');
insert into public.door_staff (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'staff@test.example');

-- Events (ids ...e1 to ...e4)
insert into public.site_events (id, title, description, venue_name, start_date, end_date, status) values
  ('00000000-0000-0000-0000-0000000000e1', 'Future Night',          'd', 'The Club', now() + interval '1 day',   now() + interval '2 days',  'published'),
  ('00000000-0000-0000-0000-0000000000e2', 'Ended Event',           'd', 'The Club', now() - interval '3 days',  now() - interval '2 days',  'published'),
  ('00000000-0000-0000-0000-0000000000e3', 'No end, long ago',      'd', 'The Club', now() - interval '13 hours', null,                      'published'),
  ('00000000-0000-0000-0000-0000000000e4', 'No end, just started',  'd', 'The Club', now() - interval '1 hour',   null,                      'published');

-- Tiers: t1 ordinary, t2 non-transferable
insert into public.site_ticket_tiers (id, event_id, name, price_cents, capacity) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000e1', 'General',  5000, 100),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000e1', 'VIP Named', 9000, 20),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000e2', 'General',  5000, 100),
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000e3', 'General',  5000, 100),
  ('00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000e4', 'General',  5000, 100);

-- Orders, one per scenario. ticket_code is what the door scans.
insert into public.site_orders
  (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, is_non_transferable, access_code_verified)
values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1', 'Ada Lovelace', 'customer@test.example', 2, 10000, 'paid',     'T-PAID',          false, false),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1', 'Bo Bennett',   'bo@test.example',       1,  5000, 'paid',     'T-PAID2',         false, false),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1', 'Cy Pending',   'cy@test.example',       1,  5000, 'pending',  'T-PENDING',       false, false),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1', 'Di Failed',    'di@test.example',       1,  5000, 'failed',   'T-FAILED',        false, false),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1', 'Ed Refunded',  'ed@test.example',       1,  5000, 'refunded', 'T-REFUNDED',      false, false),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000b3', 'Fay Ended',    'fay@test.example',      1,  5000, 'paid',     'T-ENDED',         false, false),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000b3', 'Gus Unpaid',   'gus@test.example',      1,  5000, 'pending',  'T-UNPAID-ENDED',  false, false),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000b4', 'Hal Stale',    'hal@test.example',      1,  5000, 'paid',     'T-STALE',         false, false),
  ('00000000-0000-0000-0000-0000000000e4', '00000000-0000-0000-0000-0000000000b5', 'Ivy Live',     'ivy@test.example',      1,  5000, 'paid',     'T-LIVE',          false, false),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b2', 'Jo Named',     'jo@test.example',       1,  9000, 'paid',     'T-NT',            true,  false),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b2', 'Kai Verified', 'kai@test.example',      1,  9000, 'paid',     'T-NT-OK',         true,  true),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1', 'Lee Race',     'lee@test.example',      1,  5000, 'paid',     'C-1',             false, false);
