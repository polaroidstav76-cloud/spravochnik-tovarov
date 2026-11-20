/* Byte-preserving upload helpers shared by the public page and Cloudshop. */
(function(root){
 const endpoint='https://tmxluzvymwldtxbaiekn.supabase.co/functions/v1/photo-links';
 async function api(action,data={},jwt=''){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),110000);
  try{
   const r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json',...(jwt?{Authorization:'Bearer '+jwt}:{})},body:JSON.stringify({action,data}),signal:controller.signal});
   const b=await r.json();if(!r.ok||b.error){const e=new Error(b.error||'Не удалось выполнить запрос');e.status=r.status;throw e;}return b;
  }catch(e){if(e.name==='AbortError'||e instanceof TypeError)throw new Error('Связь прервалась. Проверьте интернет и повторите — сохранённые фото останутся.');throw e;}finally{clearTimeout(timer)}
 }
 function el(tag,text,attrs={}){const e=document.createElement(tag);if(text!==null&&text!==undefined)e.textContent=text;for(const [k,v]of Object.entries(attrs)){if(k==='class')e.className=v;else if(k==='hidden')e.hidden=!!v;else e.setAttribute(k,v);}return e;}
 function button(text,fn,primary=false){const b=el('button',text,{type:'button',...(primary?{class:'photo-primary'}:{})});b.onclick=fn;return b;}
 function size(bytes){return bytes>=1e9?(bytes/1e9).toFixed(2)+' ГБ':bytes>=1e6?(bytes/1e6).toFixed(1)+' МБ':Math.ceil(bytes/1000)+' КБ';}
 function link(token){return new URL('photos.html',location.href).href.split('#')[0].split('?')[0]+'#'+token;}
 async function copy(text,input){try{await navigator.clipboard.writeText(text);return true;}catch{if(input){input.focus();input.select();try{return document.execCommand('copy')}catch{}}return false;}}
 function validPhoto(file){return /\.(jpe?g|png|heic|heif|tiff?|webp|avif|bmp|dng|cr2|nef|arw)$/i.test(file.name)&&file.size>0&&file.size<=536870912;}
 function put(href,file,progress){return new Promise((resolve,reject)=>{
  const x=new XMLHttpRequest();x.open('PUT',href);x.timeout=20*60*1000;
  x.upload.onprogress=e=>{if(e.lengthComputable)progress(e.loaded/e.total);};
  x.onload=()=>x.status>=200&&x.status<300?resolve():reject(new Error('Диск не принял файл. Нажмите «Повторить».'));
  x.onerror=()=>reject(new Error('Не удалось загрузить файл. Проверьте интернет и повторите.'));
  x.ontimeout=()=>reject(new Error('Загрузка заняла слишком долго. Нажмите «Повторить».'));
  x.send(file); // Raw File: no canvas, transcoding, compression or EXIF edits.
 });}
 root.PhotoLinks={api,el,button,size,link,copy,validPhoto,put};
})(typeof window==='undefined'?globalThis:window);
