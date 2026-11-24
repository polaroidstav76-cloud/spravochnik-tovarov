const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const base=process.env.PHOTO_TEST_URL||'http://127.0.0.1:8795';
(async()=>{
 const browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 let checks=0;
 async function fixture({offline=false,mobile=false}={}){
  const page=await browser.newPage({viewport:mobile?{width:390,height:844}:{width:1100,height:900}});
  const state={id:'order1',branch:'Тухачевского 26/4',phone_hint:'1234',order_number:'',source:offline?'offline':'staff',status:'uploading',mode:null,comment:'',groups:[],files:[],configured:true,revision:0,needs_size_advice:false,contacts:{whatsapp:'https://wa.me/79000000001',telegram:'https://t.me/test_branch'}};
  const uploads=[],calls=[];let simultaneous=0,maxActive=0,downloadRounds=0;
  await page.route('**/upload.disk.yandex.net/**',async route=>{simultaneous++;maxActive=Math.max(maxActive,simultaneous);uploads.push(route.request().postDataBuffer());await new Promise(r=>setTimeout(r,25));await route.fulfill({status:201,body:''});simultaneous--;});
  await page.route('**/functions/v1/photo-links',async route=>{
   const b=route.request().postDataJSON();calls.push(b);const d=b.data;let result={ok:true};
   switch(b.action){
    case 'branches':result={branches:[{id:5,name:'Тухачевского 26/4',slug:'branch1',contacts:{whatsapp:'https://wa.me/79000000001',telegram:'https://t.me/test_branch'}}],configured:true,admin:true};break;
    case 'create':result={id:'order1',token:'a'.repeat(64)};break;
    case 'manifest':result=state;break;
    case 'consultation':state.needs_size_advice=d.needed;break;
    case 'mode':state.mode=d.mode;break;
    case 'group':{let g=state.mode==='same'&&state.groups[0];if(!g){g={id:'g'+(state.groups.length+1),label:d.label||'Фотографии',position:state.groups.length+1};state.groups.push(g);}result=g;break;}
    case 'reserve':if(!state.files.some(f=>f.id===d.id))state.files.push({...d,status:'pending'});result={id:d.id,href:'https://upload.disk.yandex.net/'+d.id};break;
    case 'complete_file':state.files.find(f=>f.id===d.id).status='ready';break;
    case 'remove_photo':state.files=state.files.filter(f=>f.id!==d.id);break;
    case 'skip':state.files=state.files.filter(f=>f.id!==d.id);break;
    case 'finish':state.status='complete';state.comment=d.comment;state.completed_at=new Date().toISOString();state.revision++;break;
    case 'reopen':state.status='uploading';break;
    case 'list':result={orders:[]};break;
    case 'download':downloadRounds++;result=downloadRounds===1?{preparing:true,done:8,total:9,cursor:8,snapshot:'test-snapshot'}:{href:'https://download.disk.yandex.net/photos.zip'};break;
    case 'configure':result={ok:true,total:2e12,used:1e11};break;
   }
   await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(result)});
  });
  return {page,state,uploads,calls,get maxActive(){return maxActive;}};
 }
 const f=await fixture({mobile:true}),{page,state}=f;
 await page.goto(base+'/photos.html#'+'a'.repeat(64));
 assert.equal(await page.locator('.photo-support').count(),0);assert.equal(await page.locator('.photo-advice').count(),0);checks+=2;
 await page.getByRole('button',{name:'Один размер',exact:false}).click();
 await page.getByRole('button',{name:'Выбрать фото'}).waitFor();
 assert.equal(await page.locator('input[type=tel]').count(),0);assert.equal(await page.locator('input[placeholder*="10×15"]').count(),0);checks+=2;
 const original=Buffer.from([255,216,255,225,0,12,69,88,73,70,0,0,0,254,128,250,255,217]);
 await page.locator('input[type=file]').setInputFiles({name:'Оригинал.JPG',mimeType:'image/jpeg',buffer:original});
 await page.waitForFunction(()=>!document.querySelector('#photoFinish').disabled);
 assert.deepEqual(f.uploads[0],original);checks++;
 await page.locator('#photoComment').fill('Без полей, пожалуйста');
 await page.getByRole('button',{name:'Завершить загрузку фото',exact:true}).click();
 await page.getByText('Фотографии отправлены!',{exact:true}).waitFor();assert.equal(state.comment,'Без полей, пожалуйста');await page.waitForTimeout(900);assert.ok(await page.locator('.photo-success').evaluate(e=>e.getBoundingClientRect().top<100),'confirmation is scrolled into view');assert.ok(await page.getByText('Сотрудник фотоцентра свяжется с вами в ближайшее время для оформления заказа.',{exact:true}).isVisible());checks+=3;
 await page.screenshot({path:'/tmp/cloudshop-photos-mobile.png',fullPage:true});await page.context().route('**/download.disk.yandex.net/photos.zip',r=>r.fulfill({contentType:'text/plain',body:'mock archive'}));await page.getByRole('button',{name:'Скачать все фото ZIP',exact:true}).click();await page.getByText('Архив готов.',{exact:true}).waitFor();assert.equal(f.calls.filter(x=>x.action==='download').length,2);assert.ok(f.calls.filter(x=>x.action==='download').every(x=>x.data.variant==='ready'));checks+=2;
 await page.getByRole('button',{name:'Добавить ещё фото',exact:true}).click();
 await page.getByRole('button',{name:'Выбрать фото'}).waitFor();
 await page.locator('input[type=file]').setInputFiles({name:'Оригинал.JPG',mimeType:'image/jpeg',buffer:original});
 await page.waitForFunction(()=>document.querySelector('#photoUploadSummary')?.textContent.includes('Сохранено 2 фото')&&!document.querySelector('#photoFinish').disabled);
 assert.equal(state.files.length,2);assert.notEqual(state.files[0].id,state.files[1].id);checks+=2;
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);checks++;
 const d=await fixture();await d.page.goto(base+'/photos.html#'+'a'.repeat(64));await d.page.getByRole('button',{name:'Разные размеры',exact:false}).click();
 const sizeInput=d.page.getByRole('textbox',{name:'Размер фотографий'});await sizeInput.fill('10×15');await d.page.getByRole('button',{name:'Добавить размер',exact:true}).click();
 await d.page.getByRole('heading',{name:'10×15',exact:true}).waitFor();
 const batch=Array.from({length:100},(_,i)=>({name:'Фото '+i+'.jpg',mimeType:'image/jpeg',buffer:original}));
 await d.page.locator('input[type=file]').setInputFiles(batch);
 await d.page.waitForFunction(()=>document.querySelector('#photoUploadSummary')?.textContent.includes('Сохранено 100 фото')&&!document.querySelector('#photoFinish').disabled,{},{timeout:30000});
 assert.equal(d.uploads.length,100);assert.ok(d.maxActive>3 && d.maxActive<=100);checks+=2;
 await sizeInput.fill('21×30');await d.page.getByRole('button',{name:'Добавить размер',exact:true}).click();await d.page.getByRole('heading',{name:'21×30',exact:true}).waitFor();assert.equal(d.state.groups.length,2);checks++;
 await d.page.screenshot({path:'/tmp/cloudshop-photos-desktop.png',fullPage:true});
 const o=await fixture({offline:true});await o.page.goto(base+'/photos.html?branch=branch1');await o.page.locator('.photo-support summary').click();assert.equal(await o.page.getByRole('link',{name:'WhatsApp',exact:true}).getAttribute('href'),'https://wa.me/79000000001');checks++;await o.page.getByRole('button',{name:'Нужна консультация по размеру',exact:true}).click();await o.page.locator('#offlinePhone').fill('89001231234');await o.page.locator('#offlineMessenger').selectOption('max');await o.page.getByRole('button',{name:'Перейти к фотографиям'}).click();await o.page.getByRole('heading',{name:'Какие размеры фотографий?'}).waitFor();
 assert.equal(o.calls.find(x=>x.action==='create').data.needs_size_advice,true);assert.equal(o.calls.find(x=>x.action==='create').data.messenger,'max');assert.equal(new URL(o.page.url()).search,'');assert.equal(new URL(o.page.url()).hash.length,65);checks+=3;
 assert.equal(await o.page.locator('.photo-support').count(),1);checks++;
 // Staff UI uses a signed employee session, while the public page never needs one.
 const s=await fixture();await s.page.route('**/staff-fixture.html',r=>r.fulfill({contentType:'text/html',body:`<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="photo-links.css"></head><body><div class="desk-group"><button id="photoLinksBtn">Ссылка для фото</button></div><script>var staffAccount={user_id:'staff1'};var salesSession={shiftId:1,branchId:5,branchName:'Тухачевского 26/4'};var db={auth:{getSession:async()=>({data:{session:{access_token:'test-staff-jwt'}}})}};</script><script src="vendor/qrcode.js"></script><script src="photo-common.js"></script><script src="photo-staff.js"></script></body></html>`}));

 let deletedLink=false;await s.page.route('**/functions/v1/photo-links',async route=>{const b=route.request().postDataJSON();if(b.action==='delete_link'){s.calls.push(b);deletedLink=true;return route.fulfill({status:200,contentType:'application/json',body:'{"ok":true}'});}if(b.action!=='list')return route.fallback();if(deletedLink)return route.fulfill({status:200,contentType:'application/json',body:'{"orders":[]}'});await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({orders:[{id:'offline1',token:'a'.repeat(64),phone:'79001231234',source:'offline',branch_name:'Тестовый филиал',status:'complete',file_count:2,crop_count:1,bytes:2048,is_new:true,needs_size_advice:true,updated_at:new Date().toISOString()}]})});});
 await s.page.goto(base+'/staff-fixture.html');await s.page.locator('#photoLinksBtn').click();await s.page.getByRole('heading',{name:'Ссылки для фото',exact:true}).waitFor();assert.equal(await s.page.getByRole('heading',{name:'Онлайн заказ',exact:true}).count(),1);assert.equal(await s.page.getByRole('heading',{name:'Оффлайн заказ',exact:true}).count(),1);checks+=2;assert.ok(await s.page.getByAltText('QR: загрузить фото · Тухачевского 26/4').getAttribute('src'));checks++;
 await s.page.getByLabel('Телефон клиента',{exact:true}).fill('89001231234');await s.page.getByRole('button',{name:'Получить ссылку'}).click();await s.page.getByText('✓ Ссылка создана. Отправьте её клиенту.').waitFor();assert.ok(s.calls.find(x=>x.action==='create'));assert.equal(s.calls.find(x=>x.action==='create').data.phone,'+79001231234');assert.equal(await s.page.getByLabel('Телефон клиента',{exact:true}).inputValue(),'9001231234');await s.page.evaluate(()=>Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>window.testCopied=text}}));const message=await s.page.getByLabel('Сообщение для клиента',{exact:true}).inputValue();assert.ok(message.includes('при необходимости сделает это за вас бесплатно.'));assert.ok(message.includes('/photos.html#'+'a'.repeat(64)));assert.ok(message.includes('💬 Если возникнут вопросы, пишите мне!'));assert.equal(await s.page.getByRole('button',{name:'Открыть',exact:true}).count(),0);await s.page.getByRole('button',{name:'Скопировать сообщение',exact:true}).click();assert.equal(await s.page.evaluate(()=>window.testCopied),message);checks+=7;

 assert.ok((await s.page.getByRole('link',{name:'Открыть фото',exact:true}).getAttribute('href')).endsWith('/photos.html#'+'a'.repeat(64)));checks++;
 assert.equal(await s.page.locator('.photo-new').count(),1);assert.equal(await s.page.locator('.photo-advice-note').count(),1);await s.page.evaluate(()=>document.querySelector('.photo-order a').addEventListener('click',e=>e.preventDefault()));await s.page.getByRole('link',{name:'Открыть фото',exact:true}).click();await s.page.locator('.photo-viewed').waitFor();assert.ok(s.calls.some(x=>x.action==='seen'&&x.data.id==='offline1'));checks+=3;
 assert.equal(await s.page.locator('.photo-order button').count(),1);assert.equal(await s.page.locator('.photo-order a').count(),1);assert.equal(s.calls.some(x=>x.action==='download'),false);checks+=3;
 s.page.once('dialog',d=>d.dismiss());await s.page.getByRole('button',{name:'Удалить ссылку',exact:true}).click();assert.equal(s.calls.some(x=>x.action==='delete_link'),false);s.page.once('dialog',d=>d.accept());await s.page.getByRole('button',{name:'Удалить ссылку',exact:true}).click();await s.page.getByText('✓ Ссылка удалена. Фотографии на Диске сохранены.').waitFor();assert.equal(await s.page.locator('.photo-order').count(),0);assert.equal(s.calls.find(x=>x.action==='delete_link').data.id,'offline1');checks+=3;
 await browser.close();console.log('Photo links browser: '+checks+' assertions passed (mobile, originals, 100 files, parallelism, extra photos, sizes, offline, staff and QR).');
})().catch(e=>{console.error(e);process.exit(1)});
