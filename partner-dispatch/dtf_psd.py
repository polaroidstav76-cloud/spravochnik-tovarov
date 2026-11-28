"""Streaming layered Photoshop export; originals stay separate, 300 dpi, no rescaling."""
import json,struct,zlib,tempfile,os
from pathlib import Path
from PIL import Image,ImageCms
from core import UserError,MAX_BYTES
from dtf_layout import Print,arrange
from dtf_render import read_art,inspect_art

def u32(v):return struct.pack('>I',v)
def packbits(data):
 out=bytearray();i=0
 while i<len(data):
  run=1
  while run<128 and i+run<len(data) and data[i+run]==data[i]:run+=1
  if run>=3:out.extend((257-run,data[i]));i+=run;continue
  start=i;i+=run
  while i<len(data) and i-start<128:
   run=1
   while run<3 and i+run<len(data) and data[i+run]==data[i]:run+=1
   if run>=3:break
   i+=min(run,128-(i-start))
  out.append(i-start-1);out.extend(data[start:i])
 return bytes(out)
def export_psd(queue,bid,png):
 rows=queue.batch_files(bid);items=[];sources={};names={}
 for r in rows:
  info=inspect_art(queue.path(r))
  for n in range(r['copies']):
   key=f'{r["id"]}:{n}';items.append(Print(key,info['width'],info['height']));sources[key]=queue.path(r);names[key]=f'{r["name"]} · {n+1}'
 plan=Path(png).with_suffix('.layout.json')
 if plan.exists():
  from dtf_layout import Layout,Placement
  data=json.loads(plan.read_text());layout=Layout(data['width'],data['height'],data['gap'],data['margin'],tuple(Placement(**p) for p in data['prints']))
 else:layout=arrange(items,56,50)
 with open(png,'rb') as source:
  header=source.read(24)
  if header[:8]!=b'\x89PNG\r\n\x1a\n' or struct.unpack('>II',header[16:24])!=(layout.width,layout.height):raise UserError('Холст изменён. Для этого готового макета скачайте PNG; исходная раскладка не совпадает.')
 large=max(layout.width,layout.height)>30000
 dest=Path(png).with_suffix('.psb' if large else '.psd');part=dest.with_suffix(dest.suffix+'.part');length=lambda n:struct.pack('>Q' if large else '>I',n)
 try:
  with tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
   tmp=Path(tmp);records=tmp/'records';channels=tmp/'channels';cache={}
   with records.open('wb') as rec,channels.open('wb') as ch:
    # Photoshop stores layers topmost first; reverse the compositing order.
    for p in reversed(layout.prints):
     identity=(str(sources[p.key]),p.rotated)
     if identity not in cache:
      image,dpi,size=read_art(sources[p.key])
      try:
       profile=image.info.get('icc_profile')
       rgba=ImageCms.profileToProfile(image,ImageCms.ImageCmsProfile(__import__('io').BytesIO(profile)),ImageCms.createProfile('sRGB'),outputMode='RGBA') if profile else image.convert('RGBA')
       if rgba.size!=size:old=rgba;rgba=rgba.resize(size,Image.Resampling.LANCZOS);old.close()
       if p.rotated:old=rgba;rgba=rgba.transpose(Image.Transpose.ROTATE_90);old.close()
       parts=[]
       for band in rgba.split():parts.append(b'\0\2'+zlib.compress(band.tobytes(),6));band.close()
       rgba.close();cache[identity]=parts
      finally:image.close()
     parts=cache[identity]
     rec.write(struct.pack('>iiiiH',p.y,p.x,p.y+p.height,p.x+p.width,4))
     for channel,data in zip((0,1,2,-1),parts):rec.write(struct.pack('>h',channel)+length(len(data)))
     name=names[p.key].encode('utf-16-be');unicode_name=u32(len(name)//2)+name
     extra=u32(0)+u32(0)+b'\0'*4+b'8BIMluni'+u32(len(unicode_name))+unicode_name
     extra+=b'\0'*((-len(unicode_name))%4)
     rec.write(b'8BIMnorm'+bytes([255,0,0,0])+u32(len(extra))+extra)
     for data in parts:ch.write(data)
   layer_size=2+records.stat().st_size+channels.stat().st_size;layer_pad=layer_size%2
   # Stream the generated PNG (filter 0) into planar composite spools.
   planes=[(tmp/str(i)).open('w+b') for i in range(4)]
   try:
    decoder=zlib.decompressobj();pending=bytearray();stride=1+layout.width*4;count=0
    with open(png,'rb') as src:
     src.read(8)
     while True:
      head=src.read(8)
      if not head:break
      n,kind=struct.unpack('>I4s',head);data=src.read(n);src.read(4)
      if kind==b'IDAT':
       # Bounded decompression even for large empty canvases.
       while data:
        pending.extend(decoder.decompress(data,stride*64));data=decoder.unconsumed_tail
        while len(pending)>=stride:
         row=bytes(pending[:stride]);del pending[:stride]
         if row[0]!=0:raise UserError('Этот PNG не подходит для послойного экспорта. Используйте исходный предпросмотр.')
         for i,f in enumerate(planes):f.write(row[1+i::4])
         count+=1
      if kind==b'IEND':break
    if count!=layout.height:raise UserError('Не удалось прочитать весь холст для PSD.')
    resource=struct.pack('>IHHIHH',300*65536,1,1,300*65536,1,1)
    resource=b'8BIM'+struct.pack('>H',1005)+b'\0\0'+u32(len(resource))+resource
    import shutil
    with part.open('wb') as out:
     out.write(b'8BPS'+struct.pack('>H',2 if large else 1)+b'\0'*6+struct.pack('>HIIHH',4,layout.height,layout.width,8,3)+u32(0)+u32(len(resource))+resource)
     out.write(length((8 if large else 4)+layer_size+layer_pad+4));out.write(length(layer_size+layer_pad));out.write(struct.pack('>h',-len(layout.prints)))
     for source in (records,channels):
      with source.open('rb') as f:shutil.copyfileobj(f,out)
     if layer_pad:out.write(b'\0')
     # RLE composite is understood by Photoshop 2021 and older PSD readers.
     # A table of per-channel scanline lengths precedes the PackBits rows.
     out.write(u32(0));out.write(b'\0\1')
     packed=tmp/'merged-rle';lengths=tmp/'merged-lengths'
     with packed.open('wb') as body,lengths.open('wb') as table:
      for f in planes:
       f.seek(0)
       for y in range(layout.height):
        row=packbits(f.read(layout.width));table.write(struct.pack('>I' if large else '>H',len(row)));body.write(row)
     for source in (lengths,packed):
      with source.open('rb') as f:shutil.copyfileobj(f,out)
   finally:
    for f in planes:f.close()
  if part.stat().st_size>MAX_BYTES:raise UserError('Послойный макет больше 500 МБ. Разделите заказ на части.')
  os.replace(part,dest);return dest
 finally:part.unlink(missing_ok=True)
