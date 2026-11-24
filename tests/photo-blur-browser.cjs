const {chromium}=require('playwright'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 try{
 const page=await browser.newPage();await page.setContent('<html><body></body></html>');
 await page.addScriptTag({content:'window.PhotoLinks={};'});for(const path of ['photo-polaroid.js','photo-crop-engine.js'])await page.addScriptTag({path});
 const result=await page.evaluate(async()=>{
  const source=document.createElement('canvas');source.width=800;source.height=500;const sc=source.getContext('2d');
  for(let y=0;y<500;y+=20)for(let x=0;x<800;x+=20){sc.fillStyle=(x/20+y/20)%2?'#fff':'#000';sc.fillRect(x,y,20,20);}
  const image=await PhotoLinks.crop.image(await new Promise(r=>source.toBlob(r,'image/png'))),state={...PhotoLinks.crop.defaults(image),orientation:'portrait',fit:'blur'};
  const normal=await PhotoLinks.crop.jpeg(image,state);
  Object.defineProperty(CanvasRenderingContext2D.prototype,'filter',{configurable:true,get(){return 'none'},set(){}});
  const fallback=await PhotoLinks.crop.jpeg(image,state),a=new Uint8Array(await normal.blob.arrayBuffer()),b=new Uint8Array(await fallback.blob.arrayBuffer());
  const decoded=await PhotoLinks.crop.image(fallback.blob),canvas=document.createElement('canvas');canvas.width=decoded.naturalWidth;canvas.height=decoded.naturalHeight;const c=canvas.getContext('2d');c.drawImage(decoded,0,0);
  function deviation(x,y,w,h){const data=c.getImageData(x,y,w,h).data,values=[];for(let i=0;i<data.length;i+=4)values.push(data[i]);const avg=values.reduce((a,b)=>a+b)/values.length;return Math.sqrt(values.reduce((s,v)=>s+(v-avg)**2,0)/values.length);}
  const modes=[];for(const fit of ['white','crop','blur'])for(let rot=0;rot<4;rot++){const out=document.createElement('canvas');PhotoLinks.crop.draw(out,image,{...state,fit,rot},320);modes.push(out.width>0&&out.height>0);}
  return {same:a.length===b.length&&a.every((v,i)=>v===b[i]),w:fallback.width,h:fallback.height,blur:deviation(50,100,1000,150),sharp:deviation(50,700,1000,150),dpi:[a[13],a[14]*256+a[15],a[16]*256+a[17]],version:PhotoLinks.crop.clamp(image,state).blur_version,modes};
 });
 assert.equal(result.same,true,'JPG identical with Canvas filter unavailable');assert.equal(result.w,1181);assert.equal(result.h,1772);assert.deepEqual(result.dpi,[1,300,300]);assert.ok(result.blur<20,JSON.stringify(result));assert.ok(result.sharp>90,JSON.stringify(result));assert.equal(result.version,2);assert.ok(result.modes.every(Boolean));console.log('PASS pixel blur JPEG: filterless browser parity, visibly blurred borders, sharp foreground, rotations, fit modes, dimensions and 300 dpi.',result);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
