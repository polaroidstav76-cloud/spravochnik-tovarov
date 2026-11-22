-- Extend photo sizes and fit modes; no original files or orders are changed.
create or replace function photo_private.valid_crop(s jsonb) returns boolean language sql immutable set search_path='' as $$
 select coalesce(jsonb_typeof(s)='object' and ((s->>'format' in('10x15','15x21','21x30','30x40','p:6x9','p:8x8','p:10x10','p:10x12','p:10x15','p:7x10','p:10x15-3mm')) or(s->>'format'='custom' and (s->>'width_cm')::numeric between 1 and 42 and (s->>'height_cm')::numeric between 1 and 42))
 and coalesce(s->>'fit','crop') in('crop','white','blur') and s->>'orientation' in('portrait','landscape') and (s->>'zoom')::numeric between 1 and 8
 and (s->>'ox')::numeric between -1 and 1 and (s->>'oy')::numeric between -1 and 1 and (s->>'rot')::integer between 0 and 3,false)
$$;
revoke all on function photo_private.valid_crop(jsonb) from public,anon,authenticated;
create or replace function photo_private.api(p_action text,p_data jsonb,p_actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o photo_private.orders%rowtype; f photo_private.files%rowtype; r photo_private.renders%rowtype; m jsonb; result jsonb; v text; w integer; h integer;
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise sqlstate 'PT403' using message='Нет доступа';end if;
 if p_action not like 'crop_%' and p_action not in('manifest','finish','list') then return photo_private.api_before_crop(p_action,p_data,p_actor);end if;
 if p_action='list' then
  m:=photo_private.api_before_crop(p_action,p_data,p_actor);
  select coalesce(jsonb_agg(item||jsonb_build_object('crop_count',(select count(*) from photo_private.files fl where fl.order_id=(item->>'id')::uuid and fl.render_id is not null))),'[]') into result from jsonb_array_elements(m->'orders') item;
  return jsonb_build_object('orders',result);
 end if;
 select * into o from photo_private.orders where token=p_data->>'token' for update;
 if not found then raise sqlstate 'PT404' using message='Ссылка не найдена';end if;
 if p_action='manifest' then
  m:=photo_private.api_before_crop(p_action,p_data,p_actor);
  select coalesce(jsonb_agg(item||jsonb_build_object('crop_draft',fl.crop_draft,'crop_revision',fl.crop_revision,'render_id',fl.render_id,'render_settings',rr.settings)),'[]') into result
  from jsonb_array_elements(m->'files') item join photo_private.files fl on fl.id=(item->>'id')::uuid left join photo_private.renders rr on rr.id=fl.render_id;
  return m||jsonb_build_object('crop_enabled',o.crop_enabled,'crop_count',(select count(*) from photo_private.files where order_id=o.id and render_id is not null),'files',result);
 elsif p_action='finish' then
  if exists(select 1 from photo_private.files fl left join photo_private.renders rr on rr.id=fl.render_id where fl.order_id=o.id and (fl.publish_until>now() or (fl.crop_draft is not null and (fl.render_id is null or fl.crop_draft<>rr.settings)))) then raise exception 'Сохраните кадрирование выбранных фото или выберите «Оставить оригинал»';end if;
  return photo_private.api_before_crop(p_action,p_data,p_actor);
 elsif p_action='crop_enable' then
  update photo_private.orders set crop_enabled=true where id=o.id;return '{"ok":true}';
 end if;
 if p_action='crop_download_check' then
  if exists(select 1 from photo_private.files where order_id=o.id and publish_until>now()) then raise exception 'JPG ещё сохраняются. Повторите скачивание через несколько секунд';end if;
  return jsonb_build_object('id',o.id,'count',(select count(*) from photo_private.files where order_id=o.id and render_id is not null));
 end if;
 select * into f from photo_private.files where id=(p_data->>'id')::uuid and order_id=o.id and status='ready' for update;
 if not found then raise exception 'Сначала дождитесь загрузки оригинала';end if;
 if p_action='crop_draft' then
  if not photo_private.valid_crop(p_data->'settings') then raise exception 'Некорректные параметры кадрирования';end if;
  if (p_data->>'revision')::integer is distinct from f.crop_revision then raise sqlstate 'PT409' using message='Это фото изменено в другой вкладке. Откройте его заново';end if;
  update photo_private.files set crop_draft=p_data->'settings',crop_revision=crop_revision+1 where id=f.id;
  update photo_private.orders set crop_enabled=true,status='uploading',updated_at=now() where id=o.id;
  return jsonb_build_object('revision',f.crop_revision+1);
 elsif p_action='crop_source' then return to_jsonb(f);
 elsif p_action='crop_reserve' then
  if f.crop_draft is null or f.crop_draft<>p_data->'settings' then raise sqlstate 'PT409' using message='Черновик изменился. Повторите сохранение';end if;
  v:=f.crop_draft->>'format';
  case v when 'custom' then w:=round((f.crop_draft->>'width_cm')::numeric*300/2.54);h:=round((f.crop_draft->>'height_cm')::numeric*300/2.54);when '10x15' then w:=1181;h:=1772;when '15x21' then w:=1772;h:=2480;when '21x30' then w:=2480;h:=3543;when '30x40' then w:=3543;h:=4724;
   when 'p:6x9' then w:=653;h:=980;when 'p:8x8' then w:=898;h:=898;when 'p:10x10' then w:=1181;h:=1157;when 'p:10x12' then w:=1181;h:=1335;when 'p:10x15' then w:=1181;h:=1772;when 'p:7x10' then w:=761;h:=1082;when 'p:10x15-3mm' then w:=1181;h:=1772;else raise exception 'Размер не найден';end case;
  if left(v,2)<>'p:' and f.crop_draft->>'orientation'='landscape' then h:=w+h;w:=h-w;h:=h-w;end if;
  if (p_data->>'width')::integer<>w or (p_data->>'height')::integer<>h then raise exception 'Размер JPG не соответствует формату';end if;
  select * into r from photo_private.renders where id=(p_data->>'render_id')::uuid;
  if found then
   if r.file_id<>f.id or r.settings<>f.crop_draft or r.size<>(p_data->>'size')::bigint then raise exception 'Версия уже существует';end if;
  else
   insert into photo_private.renders(id,order_id,file_id,settings,size,width,height,path,target) values((p_data->>'render_id')::uuid,o.id,f.id,f.crop_draft,(p_data->>'size')::bigint,w,h,
    'disk:/Cloudshop-Client-Crops/'||o.id||'/'||(p_data->>'render_id')||'.jpg',
    'disk:/Cloudshop-Client-Ready/'||o.id||'/'||left(f.id::text,8)||'_'||regexp_replace(regexp_replace(f.name,'\.[^.]+$',''),'[[:cntrl:]/\\:*?"<>|]','_','g')||'.jpg') returning * into r;
  end if;
  return to_jsonb(r);
 elsif p_action in('crop_render','crop_publish','crop_commit') then
  select * into r from photo_private.renders where id=(p_data->>'render_id')::uuid and file_id=f.id and order_id=o.id;
  if not found then raise exception 'Версия кадрирования не найдена';end if;
  if p_action='crop_render' then return to_jsonb(r)||jsonb_build_object('current_render_id',f.render_id);end if;
  if f.publish_until>now() and f.publish_id<>r.id then raise sqlstate 'PT409' using message='Предыдущая версия ещё сохраняется. Подождите немного и повторите';end if;
  if p_action='crop_publish' then
   if r.settings<>f.crop_draft then raise sqlstate 'PT409' using message='Кадрирование изменилось. Сохраните новую версию';end if;
   update photo_private.files set publish_id=r.id,publish_until=now()+interval '3 minutes' where id=f.id;return to_jsonb(r);
  end if;
  if f.publish_id is distinct from r.id or f.publish_until<now() then raise sqlstate 'PT409' using message='Повторите сохранение кадрирования';end if;
  update photo_private.renders set status='ready' where id=r.id;
  update photo_private.files set render_id=r.id,publish_id=null,publish_until=null where id=f.id;
  update photo_private.orders set updated_at=now() where id=o.id;return '{"ok":true}';
 elsif p_action='crop_clear_begin' then
  if f.publish_until>now() and f.publish_id is distinct from (p_data->>'operation_id')::uuid then raise sqlstate 'PT409' using message='Дождитесь сохранения JPG';end if;
  update photo_private.files set publish_id=(p_data->>'operation_id')::uuid,publish_until=now()+interval '3 minutes' where id=f.id;
  select * into r from photo_private.renders where id=f.render_id;return jsonb_build_object('target',r.target);
 elsif p_action='crop_clear' then
  if f.publish_id is distinct from (p_data->>'operation_id')::uuid then raise sqlstate 'PT409' using message='Повторите действие';end if;
  update photo_private.files set render_id=null,crop_draft=null,crop_revision=crop_revision+1,publish_id=null,publish_until=null where id=f.id;
  update photo_private.orders set status='uploading',updated_at=now() where id=o.id;return '{"ok":true}';
 elsif p_action='crop_download_check' then return '{}'::jsonb;
 end if;
 raise exception 'Неизвестное действие';
end $$;
notify pgrst,'reload schema';
