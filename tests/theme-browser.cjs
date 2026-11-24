const fs=require('fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
(async()=>{const browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});try{
 const ctx=await browser.newContext({viewport:{width:1280,height:900},colorScheme:'dark'});
 const html=fs.readFileSync('index.html','utf8').replace(/<script\b([^>]*)>[\s\S]*?<\/script>/gi,(all,attrs)=>attrs.includes('theme.js')?all:'').replace(/<link[^>]+https:\/\/fonts[^>]+>/g,'');
 await ctx.route('**/theme-fixture.html',r=>r.fulfill({contentType:'text/html; charset=utf-8',body:html}));
 const page=await ctx.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto('http://127.0.0.1:8795/theme-fixture.html');
 const theme=()=>page.evaluate(()=>document.documentElement.dataset.theme);
 assert.equal(await theme(),'light','existing staff keep light until they choose');await page.getByRole('button',{name:'☾ Тёмная тема',exact:true}).click();assert.equal(await theme(),'dark');
 assert.equal(await page.locator('#themeToggle').getAttribute('aria-pressed'),'true');
 const colours=await page.evaluate(()=>{const read=s=>{const c=getComputedStyle(document.querySelector(s));return {bg:c.backgroundColor,text:c.color}};return {body:read('body'),button:read('.primary'),input:read('input'),tile:read('.tile')}});
 assert.equal(colours.body.bg,'rgb(20, 23, 28)');assert.notEqual(colours.button.bg,colours.button.text);assert.notEqual(colours.input.bg,colours.input.text);
 await page.waitForTimeout(220);await page.screenshot({path:'/tmp/cloudshop-dark-home.png'});
 await page.evaluate(()=>document.getElementById('saleModal').classList.add('show'));assert.equal(await page.locator('#saleModal .dialog').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(32, 37, 45)');assert.equal(await page.locator('#saleModal .sales-workspace-right').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(32, 37, 45)');await page.screenshot({path:'/tmp/cloudshop-dark-sale.png'});await page.evaluate(()=>document.getElementById('saleModal').classList.remove('show'));
 await page.evaluate(()=>{const card=document.createElement('div');card.id='legacyThemeFixture';card.style.cssText='background:#fff;color:#111;padding:20px';card.textContent='Новая строка закупки';document.body.append(card);});await page.waitForFunction(()=>document.getElementById('legacyThemeFixture').hasAttribute('data-theme-inline-bg'));
 assert.equal(await page.locator('#legacyThemeFixture').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(32, 37, 45)');
 await page.reload();assert.equal(await theme(),'dark','reload retains choice');
 const tab=await ctx.newPage();await tab.goto('http://127.0.0.1:8795/theme-fixture.html');await tab.locator('#themeToggle').click();await page.waitForFunction(()=>document.documentElement.dataset.theme==='light');
 await page.evaluate(()=>{const home=document.createElement('div');home.className='desktop-home-actions';document.body.append(home);});
 // Separate desktop fixture mounts the same control in its own visible dashboard.
 await ctx.route('**/theme-desktop-fixture.html',r=>r.fulfill({contentType:'text/html',body:html.replace('</head>','<link rel="stylesheet" href="desktop-pos.css"></head>').replace('<body>','<body class="desktop-pos">').replace('</body>','<section id="desktopHome"><div class="desktop-home-actions"></div></section></body>')}));
 const desktop=await ctx.newPage();await desktop.goto('http://127.0.0.1:8795/theme-desktop-fixture.html');await desktop.locator('#desktopThemeToggle').click();assert.equal(await desktop.evaluate(()=>document.documentElement.dataset.theme),'dark');await desktop.locator('#desktopThemeToggle').click();
 await desktop.emulateMedia({media:'print'});assert.equal(await desktop.evaluate(()=>getComputedStyle(document.documentElement).colorScheme),'light');assert.deepEqual(errors,[]);
 await page.setViewportSize({width:390,height:844});await page.locator('#themeToggle').click();assert.equal(await page.locator('#themeToggle').isVisible(),true);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);await page.waitForTimeout(220);await page.screenshot({path:'/tmp/cloudshop-dark-mobile.png'});
 console.log('PASS theme: default light, accessible toggle, dark inputs/buttons/tiles, dynamic inline windows, reload, cross-tab sync, desktop control, mobile layout, print.');
 }finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)});
