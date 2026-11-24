begin;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$
declare f2 uuid:=gen_random_uuid();pending uuid:=gen_random_uuid();owner uuid;bid bigint;o jsonb;g jsonb;f uuid:=gen_random_uuid();r uuid:=gen_random_uuid();s jsonb:='{"format":"10x15","orientation":"landscape","zoom":1.5,"ox":0,"oy":0,"rot":0}';m jsonb;t text;denied boolean;op uuid:=gen_random_uuid();
begin
 select user_id into owner from staff_accounts where active and role='admin' limit 1;select branch_id into bid from photo_private.branches limit 1;
 o:=public.photo_links_api('create',jsonb_build_object('phone','79000000001','branch_id',bid,'request_id',gen_random_uuid()),owner);t:=o->>'token';
 perform public.photo_links_api('mode',jsonb_build_object('token',t,'mode','same'));g:=public.photo_links_api('group',jsonb_build_object('token',t));
 perform public.photo_links_api('reserve',jsonb_build_object('token',t,'id',f,'group_id',g->>'id','name','Фото.jpg','size',123));perform public.photo_links_api('complete_file',jsonb_build_object('token',t,'id',f));
 perform public.photo_links_api('crop_enable',jsonb_build_object('token',t));
 m:=public.photo_links_api('crop_draft',jsonb_build_object('token',t,'id',f,'revision',0,'settings',s));assert m->>'revision'='1';
 denied:=false;begin perform public.photo_links_api('crop_draft',jsonb_build_object('token',t,'id',f,'revision',0,'settings',s));exception when sqlstate 'PT409' then denied:=true;end;assert denied,'stale tabs cannot overwrite draft';
 denied:=false;begin perform public.photo_links_api('finish',jsonb_build_object('token',t));exception when raise_exception then denied:=true;end;assert denied,'unfinished crops block completion';
 denied:=false;begin perform public.photo_links_api('crop_reserve',jsonb_build_object('token',t,'id',f,'render_id',r,'settings',s,'width',1181,'height',1772,'size',234));exception when raise_exception then denied:=true;end;assert denied,'physical dimensions must match landscape';
 m:=public.photo_links_api('crop_reserve',jsonb_build_object('token',t,'id',f,'render_id',r,'settings',s,'width',1772,'height',1181,'size',234));assert m->>'path' like 'disk:/Cloudshop-Client-Crops/%';assert m->>'target' like 'disk:/Cloudshop-Client-Ready/%';
 perform public.photo_links_api('crop_publish',jsonb_build_object('token',t,'id',f,'render_id',r));
 denied:=false;begin perform public.photo_links_api('crop_download_check',jsonb_build_object('token',t));exception when raise_exception then denied:=true;end;assert denied,'archive must wait for publication';
 perform public.photo_links_api('crop_commit',jsonb_build_object('token',t,'id',f,'render_id',r));

 perform public.photo_links_api('reserve',jsonb_build_object('token',t,'id',f2,'group_id',g->>'id','name','Нетронутое.png','size',345));perform public.photo_links_api('complete_file',jsonb_build_object('token',t,'id',f2));
 m:=public.photo_links_api('delivery_files',jsonb_build_object('token',t));assert jsonb_array_length(m->'files')=2;
 assert exists(select 1 from jsonb_array_elements(m->'files')x where x->>'id'=f::text and (x->>'cropped')::boolean and x->>'path' like 'disk:/Cloudshop-Client-Crops/%' and (x->>'size')::int=234);
 assert exists(select 1 from jsonb_array_elements(m->'files')x where x->>'id'=f2::text and not (x->>'cropped')::boolean and x->>'path' like 'disk:/Cloudshop-Client-Photos/%');
 perform public.photo_links_api('reserve',jsonb_build_object('token',t,'id',pending,'group_id',g->>'id','name','Ещё грузится.jpg','size',10));
 denied:=false;begin perform public.photo_links_api('delivery_files',jsonb_build_object('token',t));exception when raise_exception then denied:=true;end;assert denied;
end $$;
rollback;
