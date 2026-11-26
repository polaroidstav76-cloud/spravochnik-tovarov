import tempfile,unittest,time,hashlib,json
from pathlib import Path
from dataclasses import asdict
from PIL import Image
from core import Queue
from dtf_layout import Layout,Placement
from dtf_render import render_png
from dtf_psd import export_psd
class LayeredExport(unittest.TestCase):
 def test_real_psd_layers_positions_rotation_and_composite(self):
  try:from psd_tools import PSDImage
  except ImportError:PSDImage=None
  with tempfile.TemporaryDirectory() as tmp:
   q=Queue(tmp);q.join(1,'Branch');r=q.add(1,1,1,'Принт.png',1,time.time(),'dtf');path=q.path(r);path.parent.mkdir(parents=True,exist_ok=True)
   with Image.new('RGBA',(12,8),(255,0,0,100)) as im:im.save(path,dpi=(300,300))
   q.downloaded(r['id'],hashlib.sha256(path.read_bytes()).hexdigest());q.set_copies(r['id'],1,2);bid=q.claim('test@example.invalid',time.time(),manual=True,direction='dtf')
   p1=Placement(f'{r["id"]}:0',2,3,12,8,False);p2=Placement(f'{r["id"]}:1',25,3,8,12,True);layout=Layout(50,30,2,2,(p1,p2));png=Path(tmp)/'sheet.png';render_png(png,layout,{p1.key:path,p2.key:path});png.with_suffix('.layout.json').write_text(json.dumps(asdict(layout)))
   result=export_psd(q,bid,png);self.assertEqual(result.read_bytes()[:6],b'8BPS\0\1')
   if PSDImage is None:q.db.close();return
   psd=PSDImage.open(result);self.assertEqual(psd.size,(50,30));self.assertEqual(len(psd),2);self.assertEqual(psd[0].bbox,(25,3,33,15));self.assertEqual(psd[1].bbox,(2,3,14,11));self.assertIn('Принт',psd[0].name)
   self.assertEqual(psd[0].topil().getpixel((0,0)),(255,0,0,100))
   self.assertEqual(psd.topil().getpixel((2,3)),(255,0,0,100));q.db.close()
 def test_long_canvas_uses_psb_without_changing_size(self):
  with tempfile.TemporaryDirectory() as tmp:
   q=Queue(tmp);q.join(1,'Branch');r=q.add(1,1,1,'a.png',1,time.time(),'dtf');path=q.path(r);path.parent.mkdir(parents=True,exist_ok=True)
   with Image.new('RGBA',(2,2),(1,2,3,255)) as im:im.save(path,dpi=(300,300))
   q.downloaded(r['id'],hashlib.sha256(path.read_bytes()).hexdigest());bid=q.claim('test@example.invalid',time.time(),manual=True,direction='dtf');p=Placement(f'{r["id"]}:0',1,1,2,2,False);layout=Layout(10,30001,1,1,(p,));png=Path(tmp)/'long.png';render_png(png,layout,{p.key:path});png.with_suffix('.layout.json').write_text(json.dumps(asdict(layout)));dest=export_psd(q,bid,png);self.assertEqual(dest.suffix,'.psb');self.assertEqual(dest.read_bytes()[:6],b'8BPS\0\2')
   try:from psd_tools import PSDImage
   except ImportError:PSDImage=None
   if PSDImage:self.assertEqual(PSDImage.open(dest).size,(10,30001))
   q.db.close()
