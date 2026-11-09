from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as E
import json,html,hashlib,posixpath,re
base=Path('imports/sublimation-20261110-strict');media=base/'media';media.mkdir(exist_ok=True)
W='{http://schemas.openxmlformats.org/wordprocessingml/2006/main}';A='{http://schemas.openxmlformats.org/drawingml/2006/main}';R='{http://schemas.openxmlformats.org/officeDocument/2006/relationships}';V='{urn:schemas-microsoft-com:vml}'
blocks=[];report=[];assets={}
def props(e):
 out={}
 if e is None:return out
 for key in ['color','b','i','u']:
  q=e.find(W+key)
  if q is not None:out[key]=q.get(W+'val','true')
 return out
for name in ['Чехол','Пазл','Подушка','Круглые стикеры','Пленка','Кружки']:
 with ZipFile(Path(r'C:\Users\User\Desktop\ПЕЧАТЬ')/(name+'.docx')) as z:
  doc=E.fromstring(z.read('word/document.xml'));
  for parent in doc.iter():
   for child in list(parent):
    if child.tag=='{http://schemas.openxmlformats.org/markup-compatibility/2006}Fallback':parent.remove(child)
  st=E.fromstring(z.read('word/styles.xml'))
  styles={e.get(W+'styleId'):e for e in st.findall(W+'style')};defaults=props(st.find(W+'docDefaults/'+W+'rPrDefault/'+W+'rPr'))
  def sty(sid,seen=None):
   seen=set() if seen is None else seen
   if not sid or sid in seen or sid not in styles:return {}
   seen.add(sid);el=styles[sid];parent=el.find(W+'basedOn');v=sty(parent.get(W+'val') if parent is not None else None,seen);v.update(props(el.find(W+'rPr')));return v
  rels={el.get('Id'):posixpath.normpath('word/'+el.get('Target')) for el in E.fromstring(z.read('word/_rels/document.xml.rels')) if el.get('TargetMode')!='External'}
  source_media=[n for n in z.namelist() if n.startswith('word/media/')];image_events=0;texts=[];red=0;black=0;start=len(blocks);first=True;counters={}
  def paragraph(p):
   global image_events,red,black,first
   pstart=len(blocks);pp=p.find(W+'pPr');ps=pp.find(W+'pStyle') if pp is not None else None;pv={**defaults,**sty(ps.get(W+'val') if ps is not None else None)};chunks=[];plain=[]
   num=pp.find(W+'numPr') if pp is not None else None
   if num is not None:
    ni=num.find(W+'numId');key=ni.get(W+'val') if ni is not None else 'list';counters[key]=counters.get(key,0)+1;chunks.append(str(counters[key])+'. ');plain.append(str(counters[key])+'. ')
   def flush():
    global first
    if not chunks:return
    text=''.join(plain);tag='h2' if first and text.strip() else 'p';extra='border-top:1px solid #dbe2ea;padding-top:28px;margin-top:36px;' if tag=='h2' else ''
    blocks.append({'type':'text','html':f'<{tag} style="margin:0 0 14px;line-height:1.65;{extra}">'+''.join(chunks)+f'</{tag}>','text':text});texts.append(text);chunks.clear();plain.clear()
    if text.strip():first=False
   for run in p.iter(W+'r'):
    rp=run.find(W+'rPr');rs=rp.find(W+'rStyle') if rp is not None else None;pr={**pv,**sty(rs.get(W+'val') if rs is not None else None),**props(rp)};color=pr.get('color','000000');color=color if re.fullmatch('[0-9a-fA-F]{6}',color) else '000000'
    css='color:#'+color+';'+('font-weight:700;' if pr.get('b') not in (None,'false','0') else '')+('font-style:italic;' if pr.get('i') not in (None,'false','0') else '')+('text-decoration:underline;' if pr.get('u') not in (None,'none','false','0') else '')
    for node in run.iter():
     if node.tag==W+'t':
      t=node.text or '';chunks.append('<span style="'+css+'">'+html.escape(t)+'</span>');plain.append(t)
      if t.strip():
       if color.lower()=='ff0000':red+=1
       if color.lower()=='000000':black+=1
     elif node.tag==W+'tab':chunks.append('&emsp;');plain.append('\t')
     elif node.tag==W+'br':chunks.append('<br>');plain.append('\n')
     elif node.tag in (A+'blip',V+'imagedata'):
      rid=node.get(R+'embed') or node.get(R+'id');target=rels.get(rid)
      if not target:raise ValueError((name,'image relationship missing',rid))
      data=z.read(target);h=hashlib.sha256(data).hexdigest()[:24];filename=h+Path(target).suffix.lower();(media/filename).write_bytes(data);assets[filename]={'file':str(media/filename),'size':len(data)};flush();blocks.append({'type':'image','url':'__ASSET_BASE__/'+filename});image_events+=1
   flush()
  for p in doc.find(W+'body').iter(W+'p'):
   if not any(p is x for outer in doc.find(W+'body').iter(W+'p') if outer is not p for x in outer.iter(W+'p')):paragraph(p)
  expected=sum(1 for e in doc.iter() if e.tag in (A+'blip',V+'imagedata'))
  assert image_events==expected,(name,image_events,expected)
  original=''.join(t.text or '' for t in doc.iter(W+'t'));converted=''.join(texts)
  def norm(s):return re.sub(r'\s+','',s)
  # Numbered paragraphs add their visible numbering, so compare each original run occurrence separately below.
  assert all((html.escape(t.text or '') in ''.join(b.get('html','') for b in blocks[start:])) for t in doc.iter(W+'t'))
  report.append({'file':name+'.docx','blocks':len(blocks)-start,'images':image_events,'embedded_media':len(source_media),'red_runs':red,'black_runs':black,'source_text_chars':len(original)})
(base/'blocks.json').write_text(json.dumps(blocks,ensure_ascii=False),encoding='utf-8');(base/'manifest.json').write_text(json.dumps({'documents':report,'assets':assets},ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'documents':report,'unique_images':len(assets),'blocks':len(blocks)},ensure_ascii=False))
