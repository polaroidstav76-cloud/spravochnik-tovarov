begin;
do $$declare worker uuid;other uuid;aid bigint;r jsonb;begin
 select user_id into worker from staff_accounts where active and role='staff' limit 1;select user_id into other from staff_accounts where active and role='staff' and user_id<>worker limit 1;
 insert into announcements(title,body,is_active) values('__snooze_fixture','Test',true) returning id into aid;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated')::text,true);execute 'set local role authenticated';
 perform public.announcement_snooze('later',aid);r:=public.announcement_snooze('get');assert exists(select 1 from jsonb_array_elements(r->'snoozes')x where (x->>'id')::bigint=aid);r:=public.announcement_snooze('claim');assert jsonb_array_length(r->'due')=0;
 execute 'reset role';assert (select next_reminder>now()+interval '3 hours 59 minutes' from announcement_private.snoozes where user_id=worker and announcement_id=aid);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',other,'role','authenticated')::text,true);execute 'set local role authenticated';r:=public.announcement_snooze('get');assert not exists(select 1 from jsonb_array_elements(r->'snoozes')x where (x->>'id')::bigint=aid);execute 'reset role';
 update announcement_private.snoozes set next_reminder=now()-interval '1 minute' where user_id=worker and announcement_id=aid;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',worker,'role','authenticated')::text,true);execute 'set local role authenticated';
 r:=public.announcement_snooze('claim');assert r->'due' @> jsonb_build_array(aid);r:=public.announcement_snooze('claim');assert jsonb_array_length(r->'due')=0;
 perform public.announcement_snooze('clear',aid);r:=public.announcement_snooze('get');assert not exists(select 1 from jsonb_array_elements(r->'snoozes')x where (x->>'id')::bigint=aid);
 execute 'reset role';assert not has_table_privilege('authenticated','announcement_private.snoozes','select');
end $$;
rollback;
