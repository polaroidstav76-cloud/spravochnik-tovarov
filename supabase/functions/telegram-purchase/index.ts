import { createClient } from "jsr:@supabase/supabase-js@2";
const esc=(s:unknown)=>String(s??"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
const keyboard={keyboard:[[{text:"🛒 Закупка"},{text:"📥 Приход"}],[{text:"Отмена"}]],resize_keyboard:true,is_persistent:true};
Deno.serve(async(req)=>{
if(req.method!=="POST")return new Response("Method not allowed",{status:405});
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
const cfg=await db.rpc("telegram_purchase_config");
if(cfg.error||!cfg.data?.token||!cfg.data?.secret)return new Response("Configuration unavailable",{status:503});
if(req.headers.get("X-Telegram-Bot-Api-Secret-Token")!==cfg.data.secret)return new Response("Forbidden",{status:403});
let update;try{update=await req.json()}catch{return new Response("Invalid JSON",{status:400})}
const msg=update.message;
if(!msg?.chat?.id||typeof msg.text!=="string")return new Response("ok");
const text=msg.text.trim();
const purchase=/^(🛒\s*)?закупка$/i.test(text)||/^\/(purchase|start)(@\w+)?(?:\s|$)/i.test(text);
const receipt=/^(📥\s*)?приход$/i.test(text)||/^\/receipt(@\w+)?$/i.test(text);
const cancel=/^отмена$/i.test(text)||/^\/cancel(@\w+)?$/i.test(text);
const result=await db.rpc("telegram_purchase_data",{p_chat_id:msg.chat.id});
if(result.error)return new Response("Database unavailable",{status:503});
if(result.data===null)return new Response("ok");
const send=async(body:string)=>{
const response=await fetch("https://api.telegram.org/bot"+cfg.data.token+"/sendMessage",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({chat_id:msg.chat.id,text:body,parse_mode:"HTML",reply_markup:keyboard})});
const value=await response.json();if(!response.ok||!value.ok)throw new Error("Telegram send failed");
};
// В личном чате принимаем только записи после кнопки «Приход».
if(!purchase){
  if(msg.chat.type!=="private")return new Response("ok");
  const match=text.match(/^(.+?)\s+[-–—]\s+(\d+(?:[.,]\d{1,3})?)\s*шт\.?\s+[-–—]\s+((?:\d{1,3}(?:[ \u00a0]\d{3})+|\d+)(?:[.,]\d{1,2})?)\s*(?:₽|руб\.?|р\.?)?$/iu);
  const name=match?.[1].trim();
  const qty=match?Number(match[2].replace(",",".")):null;
  const amount=match?Number(match[3].replace(/[ \u00a0]/g,"").replace(",",".")):null;
  const saved=await db.rpc("telegram_workshop_receipt",{p_chat_id:msg.chat.id,p_message_id:msg.message_id,p_action:receipt?"start":cancel?"cancel":"save",p_name:name??null,p_amount:amount,p_qty:qty});
  if(saved.error)return new Response("Database unavailable",{status:503});
  if(!saved.data||saved.data.status==="inactive")return new Response("ok");
  const status=saved.data.status;
  const body=status==="ready"?"📥 <b>Приход · только мастерская</b>\nНапишите: наименование — количество шт — сумма руб.\nНапример: Клей — 5 шт — 1 250,50 руб\nКоличество поступит на остаток мастерской. Сумма — общая стоимость всей покупки. Можно отправить несколько покупок отдельными сообщениями. Для выхода нажмите «Отмена»."
    :status==="cancelled"?"Ввод прихода завершён."
    :status==="expired"?"Время ввода истекло. Нажмите «📥 Приход» снова."
    :status==="saved"?"✅ Приход №"+esc(saved.data.id)+" записан в мастерскую.\n"+esc(name)+" — "+esc(qty)+" шт — "+esc(amount)+" ₽\nОстаток мастерской увеличен на указанное количество.\nМожно отправить следующую покупку или нажать «Отмена»."
    :status==="unit_mismatch"?"У этого материала единица измерения не «шт». Укажите название материала, который учитывается в штуках; приход не записан."
    :status==="inactive_material"?"Материал отключён. Включите его на сайте или уточните название; приход не записан."
    :"Не удалось разобрать запись. Напишите: Клей — 5 шт — 1250,50 руб. Количество должно быть больше нуля (до 3 знаков после запятой). Сумма — больше нуля, не более 999 999 999,99 ₽; название — до 200 символов.";
  try{await send(body);return new Response("ok")}catch{return new Response("Telegram unavailable",{status:503})}
}
// Кнопка закупки также завершает ввод прихода.
if(msg.chat.type==="private"){
  const stopped=await db.rpc("telegram_workshop_receipt",{p_chat_id:msg.chat.id,p_message_id:msg.message_id,p_action:"cancel"});
  if(stopped.error)return new Response("Database unavailable",{status:503});
}
const rows=result.data as {name:string;branch:string;code:string;urgent:boolean;qty:number|null;unit:string;comment:string}[];
const now=new Date().toLocaleString("ru-RU",{timeZone:"Europe/Moscow"});
const header="🛒 <b>Нужно купить · "+rows.length+"</b>\n<i>"+now+" МСК</i>\n";
const field=(v:unknown)=>esc(String(v??"").slice(0,100));
const cards=rows.map((r,i)=>"\n"+(r.urgent?"🔴 СРОЧНО":"▫️ Обычная")+" · "+(i+1)+"\n<b>"+field(r.name)+"</b>\n📍 "+field(r.branch||"Без филиала")+"\n🔖 Код: <code>"+field(r.code||"—")+"</code>"+(r.qty!=null?"\n📦 "+field(r.qty)+" "+field(r.unit):"")+(r.comment?"\n💬 "+field(r.comment):"")+"\n");
try{let page=header;for(const card of cards){if(page.length+card.length>3900){await send(page);page="🛒 <b>Закупка · продолжение</b>\n"}page+=card}await send(page+(rows.length?"":"\n✅ Всё куплено. Открытых заявок нет."));return new Response("ok")}catch{return new Response("Telegram unavailable",{status:503})}
});
