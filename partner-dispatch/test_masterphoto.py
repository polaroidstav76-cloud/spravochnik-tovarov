import asyncio,hashlib,tempfile,time,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock,Mock,patch
from PIL import Image
from core import Queue,UserError
from worker import Worker
from masterphoto import validate_card

class Cards(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.q=Queue(self.tmp.name);self.q.join(1,'A');self.q.join(2,'B');self.w=Worker(self.q,{'sender':'sender@example.invalid','masterphoto_recipient':'cards@example.invalid'},lambda _:None);self.w.client=SimpleNamespace(send_message=AsyncMock());self.order=self.w.masterphoto
 def tearDown(self):self.q.db.close();self.tmp.cleanup()
 def event(self,uid=1,**kw):return SimpleNamespace(sender_id=uid,chat_id=uid,respond=AsyncMock(),document=False,**kw)
 def upload(self,uid,n):
  oid=self.order.current(uid)['id'];r=self.q.add(uid,n,uid,'same.jpg',100,time.time(),'masterphoto');p=self.q.path(r);p.parent.mkdir(parents=True,exist_ok=True)
  with Image.new('RGB',(1110,638),'red') as im:im.save(p,'JPEG',dpi=(300,300))
  with self.q.db:self.q.db.execute('update files set size=? where id=?',(p.stat().st_size,r['id']));self.q.db.execute('insert into business_files values(?,?)',(r['id'],oid))
  self.q.downloaded(r['id'],hashlib.sha256(p.read_bytes()).hexdigest());return r
 def callback(self,oid,qty=310,uid=1):return SimpleNamespace(sender_id=uid,chat_id=uid,data=f'card:{oid}:{qty}'.encode(),answer=AsyncMock(),edit=AsyncMock())
 def test_two_sides_isolated_and_quantity_once_attachments_original(self):
  asyncio.run(self.order.handle(self.event(),'Двусторонние визитки'));o=self.order.current(1);r=self.upload(1,10)
  with self.assertRaises(UserError):asyncio.run(self.order.callback(self.callback(o['id'])))
  asyncio.run(self.order.handle(self.event(2),'Односторонние визитки'));other=self.upload(2,20);r2=self.upload(1,11)
  with self.assertRaises(UserError):asyncio.run(self.order.callback(self.callback(o['id'],uid=2)))
  e=self.callback(o['id']);asyncio.run(self.order.callback(e));asyncio.run(self.order.callback(e));self.assertEqual(self.q.db.execute('select count(*) from batches').fetchone()[0],1)
  self.assertIsNone(self.q.file(other['id'])['batch']);b=self.q.active_batch('masterphoto');rows=self.q.batch_files(b['id']);m=self.order.email(b,rows)
  parts=list(m.iter_attachments());self.assertEqual(len(parts),2);self.assertIn('310 шт.',m.get_body().get_content());self.assertNotIn('ТЕСТ',str(m));self.assertEqual(parts[0].get_payload(decode=True),self.q.path(r).read_bytes());self.assertNotIn('application/zip',str(m));self.assertIn('Оборотная',parts[1].get_filename())
  smtp=SimpleNamespace(send_message=Mock(),close=Mock())
  with patch('masterphoto.smtp_connect',return_value=smtp):asyncio.run(self.order.process(b))
  self.assertEqual(self.q.batch(b['id'])['state'],'sent');smtp.send_message.assert_called_once();asyncio.run(self.order.process(self.q.batch(b['id'])));smtp.send_message.assert_called_once()
 def test_validation(self):
  p=Path(self.tmp.name)/'file.jpg'
  for size,dpi in [((1110,638),300),((638,1110),300)]:
   with Image.new('RGB',size) as im:im.save(p,'JPEG',dpi=(dpi,dpi))
   validate_card(p)
  for size,dpi,fmt in [((1110,638),72,'JPEG'),((100,100),300,'JPEG'),((1110,638),300,'PNG')]:
   with Image.new('RGB',size) as im:im.save(p,fmt,dpi=(dpi,dpi))
   with self.assertRaises(UserError):validate_card(p)
 def test_bad_quantity_and_missing_recipient_stay_pending(self):
  asyncio.run(self.order.handle(self.event(),'Односторонние визитки'));o=self.order.current(1);self.upload(1,1)
  with self.assertRaises(UserError):asyncio.run(self.order.callback(self.callback(o['id'],999)))
  self.w.c['masterphoto_recipient']=''
  with self.assertRaises(UserError):asyncio.run(self.order.callback(self.callback(o['id'])))
  self.assertIsNotNone(self.order.current(1))
