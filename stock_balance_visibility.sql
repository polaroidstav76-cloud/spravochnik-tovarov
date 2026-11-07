-- Отображение остатков ограничено в index.html (STK_BALANCE_MATERIALS_BY_SKU).
-- Остальные материалы, движения и нормы остаются без изменений.
-- 079 = пенокартон; по подтверждению владельца для 131 создан материал с нулевым остатком.
begin;
insert into public.stock_materials(name,unit,min_qty,in_workshop)
select 'Пластик (ПВХ) толщина 3 мм, 30х42 см','шт',0,false
where not exists(select 1 from public.stock_materials where name='Пластик (ПВХ) толщина 3 мм, 30х42 см' and not archived);
insert into public.stock_norms(catalog_id,material_id,qty)
select c.id,m.id,1 from public.sales_catalog c cross join public.stock_materials m
where c.sku='131' and c.name='Пластик (ПВХ) толщина 3 мм, 30х42 см'
and m.name=c.name and not m.archived
on conflict(catalog_id,material_id) do nothing;
commit;
-- В рабочем проекте создан material_id=171. Начальное количество вводится инвентаризацией.
