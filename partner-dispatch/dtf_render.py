"""Render DTF sheets as streaming 300 dpi RGBA PNGs, without a full-sheet bitmap."""
import hashlib
import io
import math
import os
import shutil
from pathlib import Path
import struct
import tempfile
import warnings
import zlib
from PIL import Image,ImageOps,ImageCms
from core import UserError
from dtf_layout import Print,arrange,DPI

MAX_IMAGE_PIXELS=80000000

def read_art(path):
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('error',Image.DecompressionBombWarning)
            image=Image.open(path)
            if image.format not in ('PNG','TIFF','JPEG'):raise UserError('Для ДТФ используйте PNG, TIF или JPG с указанным DPI.')
            if getattr(image,'n_frames',1)!=1:raise UserError('Сохраните каждый принт отдельным однослойным файлом.')
            if image.width*image.height>MAX_IMAGE_PIXELS:raise UserError('Слишком большой исходный растр. Разделите макет на отдельные принты.')
            dpi=image.info.get('dpi')
            if not dpi or len(dpi)<2 or any(not math.isfinite(float(v)) or float(v)<=0 for v in dpi[:2]):
                raise UserError('В файле не указан DPI. Пересохраните макет в нужном физическом размере с разрешением 300 dpi.')
            dpi=tuple(map(float,dpi[:2]))
            orientation=image.getexif().get(274,1)
            original=image
            image=ImageOps.exif_transpose(original);original.close()
            if orientation in (5,6,7,8):dpi=dpi[::-1]
            width=round(image.width*DPI/dpi[0]);height=round(image.height*DPI/dpi[1])
            if width<=0 or height<=0 or width*height>MAX_IMAGE_PIXELS:
                image.close();raise UserError('Размер принта при 300 dpi слишком велик. Проверьте DPI и физические размеры файла.')
            return image,dpi,(width,height)
    except UserError:
        if 'image' in locals():image.close()
        raise
    except Exception:
        if 'image' in locals():image.close()
        raise UserError('Не удалось прочитать изображение ДТФ. Сохраните обычный однослойный PNG/TIF с DPI 300.') from None

def inspect_art(path):
    image,dpi,size=read_art(path)
    try:return {'width':size[0],'height':size[1],'width_cm':size[0]/DPI*2.54,'height_cm':size[1]/DPI*2.54,'dpi':dpi,'transparent':'A' in image.getbands() or 'transparency' in image.info}
    finally:image.close()

def write_chunk(file,kind,data):
    file.write(struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff))

def render_png(destination,layout,sources,valid=lambda:True):
    """sources maps each placement key to a verified source file path."""
    destination=Path(destination);destination.parent.mkdir(parents=True,exist_ok=True)
    part=destination.with_suffix('.part')
    try:
        with tempfile.TemporaryDirectory(dir=destination.parent,prefix='dtf-') as tmp:
            spools={}
            for p in layout.prints:
                path=Path(sources[p.key]);identity=(str(path),p.rotated)
                if identity in spools:continue
                if not valid():raise UserError('Состав заказа изменён. Холст будет пересобран.')
                image,dpi,size=read_art(path)
                try:
                    profile=image.info.get('icc_profile')
                    if profile:
                        try:rgba=ImageCms.profileToProfile(image,ImageCms.ImageCmsProfile(io.BytesIO(profile)),ImageCms.createProfile('sRGB'),outputMode='RGBA')
                        except Exception:raise UserError('Не удалось преобразовать цветовой профиль. Сохраните принт в RGB sRGB.') from None
                    else:rgba=image.convert('RGBA')
                    if rgba.size!=size:
                        resized=rgba.resize(size,Image.Resampling.LANCZOS);rgba.close();rgba=resized
                    if p.rotated:
                        rotated=rgba.transpose(Image.Transpose.ROTATE_90);rgba.close();rgba=rotated
                    if rgba.size!=(p.width,p.height):raise UserError('Размер исходника изменился во время сборки.')
                    spool=Path(tmp)/str(len(spools))
                    with spool.open('wb') as raw:
                        for y in range(0,rgba.height,64):raw.write(rgba.crop((0,y,rgba.width,min(y+64,rgba.height))).tobytes())
                    rgba.close();spools[identity]=spool
                finally:image.close()
            compressor=zlib.compressobj(6);pending=bytearray()
            with part.open('wb') as out:
                out.write(b'\x89PNG\r\n\x1a\n')
                write_chunk(out,b'IHDR',struct.pack('>IIBBBBB',layout.width,layout.height,8,6,0,0,0))
                write_chunk(out,b'pHYs',struct.pack('>IIB',round(DPI/.0254),round(DPI/.0254),1))
                write_chunk(out,b'sRGB',b'\0')
                for top in range(0,layout.height,64):
                    if not valid():raise UserError('Состав заказа изменён. Холст будет пересобран.')
                    bottom=min(top+64,layout.height);stride=layout.width*4
                    band=bytearray(stride*(bottom-top))
                    for p in layout.prints:
                        begin=max(top,p.y);end=min(bottom,p.y+p.height)
                        if begin>=end:continue
                        with spools[(str(Path(sources[p.key])),p.rotated)].open('rb') as raw:
                            raw.seek((begin-p.y)*p.width*4)
                            for y in range(begin,end):
                                offset=(y-top)*stride+p.x*4
                                band[offset:offset+p.width*4]=raw.read(p.width*4)
                    for y in range(bottom-top):pending.extend(compressor.compress(b'\0'+band[y*stride:(y+1)*stride]))
                    if len(pending)>=65536:write_chunk(out,b'IDAT',pending);pending.clear()
                pending.extend(compressor.flush())
                if pending:write_chunk(out,b'IDAT',pending)
                write_chunk(out,b'IEND',b'')
        os.replace(part,destination)
        return destination
    finally:part.unlink(missing_ok=True)

def build_sheet(queue,bid):
    rows=queue.batch_files(bid)
    if not rows or any(r['state']!='ready' or not r['copies_set'] for r in rows):raise UserError('Дождитесь загрузки всех принтов и укажите количество копий.')
    items=[];sources={}
    for row in rows:
        path=queue.path(row)
        with path.open('rb') as file:
            if hashlib.file_digest(file,'sha256').hexdigest()!=row['sha256']:raise UserError('Исходник изменился. Загрузите его заново.')
        info=inspect_art(path)
        for copy in range(row['copies']):
            key=f'{row["id"]}:{copy}';items.append(Print(key,info['width'],info['height']));sources[key]=path
    layout=arrange(items,56,50)
    required=layout.width*layout.height*4+sum(r['size'] for r in rows)+1024**3
    if shutil.disk_usage(queue.root).free<required:raise UserError('На компьютере недостаточно свободного места для холста ДТФ. Освободите место или разделите заказ.')
    with queue.lock,queue.db:
        queue.set_setting('dtf_layout:'+bid,f'{layout.width/DPI*2.54:.2f} × {layout.height/DPI*2.54:.2f} см; {len(items)} копий; промежуток {layout.gap/DPI*25.4:.1f} мм')
    return render_png(queue.root/'archives'/bid/'Полароид-ДТФ.png',layout,sources,valid=lambda:queue.batch(bid)['state']=='packing')
