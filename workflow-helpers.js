/* Shared deterministic rules for cashdesk UI and regression tests. */
(function(root){
 'use strict';
 const money=value=>Math.round((Number(value)||0)*100)/100;
 function pointLimit(afterDiscount,balance){return Math.max(0,Math.min(Math.round(Math.max(0,Number(afterDiscount)||0)*30),Math.floor(Math.max(0,Number(balance)||0)*100+1e-6)))/100;}
 function moscowDay(value){const date=new Date(value);if(!Number.isFinite(date.getTime()))return null;return new Date(date.getTime()+3*3600000).toISOString().slice(0,10);}
 function deadline(row){
  const text=String(row.deadline||'').trim().toLowerCase().replace(/ё/g,'е').replace(/,/g,'.');if(!text)return null;
  const start=new Date(row.created_at).getTime();let end=null;
  const date=text.match(/\b(\d{1,2})[./](\d{1,2})(?:[./](\d{4}))?\b/),clock=text.match(/\b([01]?\d|2[0-3]):([0-5]\d)\b/);
  const base=row.check_date||moscowDay(row.created_at);
  const durations=[...text.matchAll(/(\d+(?:\.\d+)?)(?:\s*[-–—]\s*(\d+(?:\.\d+)?))?\s*(мин|час|ч(?![а-я])|дн|день|дня|дней|сут|д(?![а-я]))/g)];
  if(durations.length&&Number.isFinite(start)){
   end=start+durations.reduce((total,m)=>total+Number(m[2]||m[1])*(m[3].startsWith('мин')?60000:m[3].startsWith('ч')?3600000:86400000),0);
  }else if(date){
   const year=date[3]||(base||'').slice(0,4);const day=date[1].padStart(2,'0'),month=date[2].padStart(2,'0');
   const iso=`${year}-${month}-${day}`;const hour=clock?clock[1].padStart(2,'0'):'23',minute=clock?clock[2]:'59';
   const parsed=Date.parse(`${iso}T${hour}:${minute}:00+03:00`);if(Number.isFinite(parsed)&&moscowDay(parsed)===iso)end=parsed;
  }else if(clock&&base){
   let day=base;if(/завтра/.test(text))day=new Date(Date.parse(base+'T12:00:00Z')+86400000).toISOString().slice(0,10);
   end=Date.parse(`${day}T${clock[1].padStart(2,'0')}:${clock[2]}:00+03:00`);
  }
  return Number.isFinite(end)&&end!==null?{end,warn:end-3600000}:null;
 }
 const api={money,pointLimit,deadline,moscowDay};root.CloudshopWorkflow=api;if(typeof module==='object'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
