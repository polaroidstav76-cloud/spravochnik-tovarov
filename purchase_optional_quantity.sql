do $patch$
declare d text;
begin
d:=pg_get_functiondef('public.purchase_request_add(bigint,bigint,bigint,bigint,numeric,boolean,text)'::regprocedure);
d:=replace(d,'if p_qty is null or p_qty<=0 or p_qty>999999 or p_qty<>round(p_qty,3) then','if p_qty is not null and (p_qty<=0 or p_qty>999999 or p_qty<>round(p_qty,3)) then');
execute d;
d:=pg_get_functiondef('public.purchase_finish(uuid,jsonb,text)'::regprocedure);
d:=replace(d,'if req.qty is not null and v_qty>greatest(req.qty-req.ordered_qty,0) then raise exception ''Заказано больше остатка заявки''; end if;','');
execute d;
end $patch$;

