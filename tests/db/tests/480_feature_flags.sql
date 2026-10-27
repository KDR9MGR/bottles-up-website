-- Feature switches. What matters most: every switch starts off; anyone (even signed out) can ask which are on but only a BottlesUp admin can change one;
-- a change is written to the audit log once, an unchanged one is not; an unknown name or a missing answer is refused; the internal check
-- feature_enabled() cannot be called by the apps.
begin;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  j jsonb;
  n int;
begin
  perform tests.login_anon();
  j := public.site_features();
  perform tests.assert_eq('a signed-out visitor can ask which features are on', jsonb_typeof(j), 'object');
  perform tests.assert_eq('social starts off', (j ->> 'social')::boolean, false);
  perform tests.assert_eq('the marketplace starts off', (j ->> 'marketplace')::boolean, false);
  perform tests.assert_eq('subscriptions start off', (j ->> 'subscriptions')::boolean, false);
  perform tests.assert_eq('all 16 switches exist', (select count(*) from jsonb_object_keys(j))::int, 16);
  perform tests.assert_eq('none is on', (select count(*) from jsonb_each(j) e where e.value = 'true'::jsonb)::int, 0);
  perform tests.assert_raises('a visitor cannot change a switch', $q$select public.cms_set_feature('social', true)$q$, 'permission denied');
  perform tests.assert_raises('a visitor cannot read the table', $q$select * from public.site_feature_flags$q$, 'permission denied');

  perform tests.login(rando, 'rando@test.example');
  perform tests.assert_raises('a signed-in person who is not an admin cannot change a switch', $q$select public.cms_set_feature('social', true)$q$, 'Only a BottlesUp admin');
  perform tests.assert_raises('...or list them with notes', $q$select * from public.cms_list_features()$q$, 'Only a BottlesUp admin');
  perform tests.assert_raises('the internal check cannot be called by the app', $q$select public.feature_enabled('social')$q$, 'permission denied');
  perform tests.assert_eq('it is still off', (public.site_features() ->> 'social')::boolean, false);

  perform tests.login(admin_u, 'admin@test.example');
  j := public.cms_set_feature('social', true);
  perform tests.assert_eq('an admin turns social on and gets the new list', (j ->> 'social')::boolean, true);
  perform tests.assert_eq('...and only that one changed', (select count(*) from jsonb_each(j) e where e.value = 'true'::jsonb)::int, 1);
  perform tests.assert_eq('the list for the CMS shows it with its note', (select enabled from public.cms_list_features() where key = 'social'), true);
  perform tests.assert_true('...every switch has a note', (select bool_and(note is not null) from public.cms_list_features()));
  perform tests.assert_eq('16 rows in the CMS list', (select count(*) from public.cms_list_features())::int, 16);

  perform tests.login_anon();
  perform tests.assert_eq('a visitor now sees social on', (public.site_features() ->> 'social')::boolean, true);

  perform tests.login(admin_u, 'admin@test.example');
  select count(*) into n from public.audit_log where action = 'feature_switched' and entity_id = 'social';
  perform tests.assert_eq('the change was logged once', n, 1);
  perform tests.assert_eq('...with who, from and to', (select details::text from public.audit_log where action = 'feature_switched' and entity_id = 'social'), '{"to": true, "from": false}');
  perform public.cms_set_feature('social', true);
  select count(*) into n from public.audit_log where action = 'feature_switched' and entity_id = 'social';
  perform tests.assert_eq('setting it to what it already is writes nothing', n, 1);
  perform public.cms_set_feature('social', false);
  select count(*) into n from public.audit_log where action = 'feature_switched' and entity_id = 'social';
  perform tests.assert_eq('turning it off again is a second entry', n, 2);

  perform tests.assert_raises('an unknown switch is refused', $q$select public.cms_set_feature('teleport', true)$q$, 'There is no such feature.');
  perform tests.assert_raises('a missing answer is refused', $q$select public.cms_set_feature('social', null)$q$, 'Choose on or off.');
  perform tests.logout();
  perform tests.assert_eq('nothing else moved', (select count(*) from public.site_feature_flags where enabled)::int, 0);

  perform tests.assert_eq('the database function sees the real value', public.feature_enabled('social'), false);
  perform tests.assert_eq('...and false for a name that does not exist', public.feature_enabled('nope'), false);
end $$;

rollback;
