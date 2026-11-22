(()=>{
 const formats=[['10x15','10×15 см',1181,1772],['15x21','15×21 см',1772,2480],['21x30','21×30 см',2480,3543],['30x40','30×40 см',3543,4724]].map(([key,name,w,h])=>({key,name,w,h}));
 for(const f of PhotoLinks.polaroid.FRAMES)formats.push({key:'p:'+f.key,name:'Полароид '+f.name.replace(' (2 шт. на листе)',''),w:Math.round(f.slots[0].cut[2]),h:Math.round(f.slots[0].cut[3]),frame:f});
 function format(s){if(s.format==='custom')return {key:'custom',name:'Свой размер',w:Math.round(Number(s.width_cm)*300/2.54),h:Math.round(Number(s.height_cm)*300/2.54)};const f=formats.find(f=>f.key===s.format);if(!f)throw new Error('Выберите размер');return f;}
 function dimensions(s){const f=format(s);return !f.frame&&s.orientation==='landscape'?{width:f.h,height:f.w}:{width:f.w,height:f.h};}
 function defaults(img){return {format:'10x15',orientation:img.naturalWidth>img.naturalHeight?'landscape':'portrait',zoom:1,ox:0,oy:0,rot:0,fit:'crop'};}
 function placement(img,s){return {...s,mode:'none',img,iw:img.naturalWidth,ih:img.naturalHeight};}
 function viewport(s){const f=format(s),d=dimensions(s);return f.frame?f.frame.slots[0].win:[0,0,d.width,d.height];}
 function clamp(img,s){if((s.fit||'crop')!=='crop'&&!format(s).frame)return {...s,zoom:Math.max(1,Math.min(8,s.zoom)),ox:Math.max(-1,Math.min(1,s.ox)),oy:Math.max(-1,Math.min(1,s.oy))};const p=PhotoLinks.polaroid.clampPlacement(viewport(s),placement(img,s));return {...s,ox:p.ox,oy:p.oy};}
 function draw(canvas,img,state,maxWidth){const s=clamp(img,state),f=format(s),d=dimensions(s);
  if(f.frame){PhotoLinks.polaroid.renderPolaroid(canvas,f.frame,placement(img,s),null,maxWidth?Math.min(d.width,maxWidth):d.width);return s;}
  const k=maxWidth?Math.min(1,maxWidth/d.width):1;canvas.width=Math.round(d.width*k);canvas.height=Math.round(d.height*k);const c=canvas.getContext('2d');c.fillStyle='#fff';c.fillRect(0,0,canvas.width,canvas.height);
  const [rw,rh]=s.rot%2?[img.naturalHeight,img.naturalWidth]:[img.naturalWidth,img.naturalHeight],scale=((s.fit||'crop')==='crop'?Math.max(d.width/rw,d.height/rh):Math.min(d.width/rw,d.height/rh))*s.zoom;
  if(s.fit==='blur'){c.save();c.scale(k,k);c.filter='blur('+Math.max(d.width,d.height)*.025+'px)';c.translate(d.width/2,d.height/2);c.rotate(s.rot*Math.PI/2);const bg=Math.max(d.width/rw,d.height/rh)*1.12;c.drawImage(img,-img.naturalWidth*bg/2,-img.naturalHeight*bg/2,img.naturalWidth*bg,img.naturalHeight*bg);c.restore();}
  c.scale(k,k);c.translate(d.width/2+s.ox*d.width,d.height/2+s.oy*d.height);c.rotate(s.rot*Math.PI/2);c.imageSmoothingQuality='high';c.drawImage(img,-img.naturalWidth*scale/2,-img.naturalHeight*scale/2,img.naturalWidth*scale,img.naturalHeight*scale);return s;
 }
 function lowResolution(img,s){return PhotoLinks.polaroid.needPx(viewport(s),placement(img,s))>Math.max(img.naturalWidth,img.naturalHeight)*1.05;}
 // Canvas encoders default to 96 dpi. Replace/insert JFIF density without re-encoding pixels.
 async function dpi300(blob){const src=new Uint8Array(await blob.arrayBuffer());if(src[0]!==255||src[1]!==216)throw new Error('Не удалось создать JPG');
  let i=2;while(i+4<src.length&&src[i]===255){const marker=src[i+1],len=(src[i+2]<<8)|src[i+3];if(marker===0xda||marker===0xd9)break;if(len<2||i+len+2>src.length)break;
   if(marker===0xe0&&len>=16&&String.fromCharCode(...src.slice(i+4,i+9))==='JFIF\0'){const out=src.slice();out[i+11]=1;out[i+12]=1;out[i+13]=44;out[i+14]=1;out[i+15]=44;return new Blob([out],{type:'image/jpeg'});}i+=len+2;
  }
  const jfif=new Uint8Array([255,224,0,16,74,70,73,70,0,1,2,1,1,44,1,44,0,0]);return new Blob([src.slice(0,2),jfif,src.slice(2)],{type:'image/jpeg'});
 }
 async function jpeg(img,s){const canvas=document.createElement('canvas');draw(canvas,img,s);const d={width:canvas.width,height:canvas.height};const blob=await new Promise((resolve,reject)=>canvas.toBlob(b=>b?resolve(b):reject(new Error('Не хватает памяти для JPG. Закройте лишние вкладки и повторите.')),'image/jpeg',1));canvas.width=canvas.height=1;return {blob:await dpi300(blob),...d};}
 async function image(blob){const url=URL.createObjectURL(blob),img=new Image();try{await new Promise((resolve,reject)=>{img.onload=resolve;img.onerror=()=>reject(new Error('Браузер не открыл это фото для кадрирования. Оригинал сохранён; для обработки выберите JPG или PNG.'));img.src=url;});return img;}finally{URL.revokeObjectURL(url);}}
 PhotoLinks.crop={formats,format,dimensions,defaults,clamp,draw,lowResolution,dpi300,jpeg,image};
})();
