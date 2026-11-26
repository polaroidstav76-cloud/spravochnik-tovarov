import asyncio
import hashlib
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock,patch
from PIL import Image
from core import Queue,UserError
from dtf_layout import pixels
from dtf_review import DtfReview,validate_ready
from worker import Worker

class DtfProof(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.files=tempfile.TemporaryDirectory();cls.template=Path(cls.files.name)/'ready.png'
  with Image.new('RGBA',(pixels(56),pixels(50)),(10,40,70,100)) as image:image.save(cls.template,dpi=(300,300))
  cls.payload=cls.template.read_bytes()
 @classmethod
 def tearDownClass(cls):cls.files.cleanup()
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.q=Queue(self.tmp.name);self.q.join(11,'Первый');self.q.join(22,'Второй');self.q.set_setting('owner',11)
  row=self.q.add(11,1,11,'print.png',4,time.time(),direction='dtf');source=self.q.path(row);source.parent.mkdir(parents=True,exist_ok=True);source.write_bytes(b'test');self.q.downloaded(row['id'],hashlib.sha256(b'test').hexdigest())
  self.bid=self.q.claim('dtf@example.invalid',time.time(),manual=True,direction='dtf');self.q.transition(self.bid,'collecting','packing')
  self.worker=Worker(self.q,{'recipient':'wide@example.invalid','dtf_recipient':'dtf@example.invalid','disk_token':'fake','sender':'sender@example.invalid'},lambda _:None)
  self.worker.client=SimpleNamespace(send_message=AsyncMock(),send_file=AsyncMock(),download_media=AsyncMock(side_effect=self.download))
  self.worker.choose(11,'dtf');self.review=self.worker.dtf_review;folder=self.q.root/'archives'/self.bid;folder.mkdir(parents=True);self.sheet=folder/'Полароид-ДТФ.png';shutil.copyfile(self.template,self.sheet);self.review.prepare(self.bid,self.sheet,11)
  self.export_patch=patch('dtf_psd.export_psd',return_value=self.sheet.with_suffix('.psd'));self.export_patch.start();self.addCleanup(self.export_patch.stop)
 def tearDown(self):self.q.db.close();self.tmp.cleanup()
 async def download(self,message,file,**kw):Path(file).write_bytes(self.payload)
 def event(self,action,uid=11,revision=None):
  return SimpleNamespace(data=f'dtf:{self.bid}:{revision or self.review.get(self.bid)["revision"]}:{action}'.encode(),sender_id=uid,answer=AsyncMock(),respond=AsyncMock())
 def incoming(self,filename='corrected.png',uid=11,message=100,size=None):
  return SimpleNamespace(sender_id=uid,chat_id=uid,id=message,document=True,message=object(),file=SimpleNamespace(name=filename,size=len(self.payload) if size is None else size),respond=AsyncMock())
 def test_five_minutes_start_after_delivered_preview_and_survive_restart(self):
  self.assertIsNone(self.review.get(self.bid)['deadline'])
  with patch('dtf_review.time.time',return_value=1000):asyncio.run(self.review.show(self.bid))
  self.assertEqual(self.review.get(self.bid)['deadline'],1300)
  with patch('dtf_review.time.time',return_value=1100):asyncio.run(self.review.show(self.bid,22))
  self.assertEqual(self.review.get(self.bid)['deadline'],1300,'viewing does not extend the window')
  self.q.db.close();self.q=Queue(self.tmp.name);self.worker.q=self.q;self.review=DtfReview(self.worker)
  with patch('dtf_review.time.time',return_value=1299):asyncio.run(self.review.tick(self.bid))
  self.assertEqual(self.q.batch(self.bid)['state'],'review')
  with patch('dtf_review.time.time',return_value=1300):asyncio.run(self.review.tick(self.bid))
  self.assertEqual(self.q.batch(self.bid)['state'],'collecting');self.assertEqual(self.review.get(self.bid)['approved'],1)
 def test_preview_failure_does_not_start_timer(self):
  self.worker.client.send_message.side_effect=ConnectionError()
  with self.assertRaises(ConnectionError):asyncio.run(self.review.show(self.bid))
  self.assertIsNone(self.review.get(self.bid)['deadline']);self.assertEqual(self.q.batch(self.bid)['state'],'review')
 def test_edit_pauses_timer_locks_editor_and_resume_gives_new_five_minutes(self):
  with patch('dtf_review.time.time',return_value=1000):asyncio.run(self.review.show(self.bid))
  asyncio.run(self.review.callback(self.event('edit')))
  self.assertEqual(self.q.batch(self.bid)['state'],'editing')
  with patch('dtf_review.time.time',return_value=9000):asyncio.run(self.review.tick(self.bid))
  self.assertEqual(self.q.batch(self.bid)['state'],'editing')
  with self.assertRaises(UserError):asyncio.run(self.review.callback(self.event('edit',22)))
  with self.assertRaises(UserError):asyncio.run(self.review.callback(self.event('send')))
  with patch('dtf_review.time.time',return_value=10000):asyncio.run(self.review.callback(self.event('resume')))
  self.assertEqual(self.review.get(self.bid)['deadline'],10300)
 def test_ready_file_is_preserved_not_repacked_and_not_readded_on_replay(self):
  asyncio.run(self.review.callback(self.event('edit')));old=self.review.get(self.bid)['revision'];event=self.incoming()
  with patch('dtf_review.time.time',return_value=1000):self.assertTrue(asyncio.run(self.review.handle_document(event)))
  row=self.review.get(self.bid);self.assertEqual(row['revision'],old+1);self.assertIsNone(row['deadline']);self.assertEqual(self.q.batch(self.bid)['state'],'collecting');self.assertEqual(row['approved'],1)
  self.assertEqual(self.review.artifact(self.bid).read_bytes(),self.payload)
  self.assertTrue(asyncio.run(self.review.handle_document(event)));self.assertEqual(len(self.q.batch_files(self.bid)),1)
  with self.assertRaises(UserError):asyncio.run(self.review.callback(self.event('edit',revision=old)))
  with self.assertRaises(UserError):asyncio.run(self.review.callback(self.event('send')))
  uploaded=[]
  class Disk:
   def __init__(self,*a):pass
   def upload(self,path,remote,progress=None):uploaded.append(Path(path).read_bytes());return 'https://disk.yandex.ru/d/ready'
  smtp=SimpleNamespace(send_message=lambda _:None,close=lambda:None)
  with patch('worker.Disk',Disk),patch('worker.smtp_connect',return_value=smtp),patch('worker.build_sheet') as build:
   asyncio.run(self.worker.process_batch(self.q.batch(self.bid)));build.assert_not_called()
  self.assertEqual(uploaded,[self.payload]);self.assertEqual(self.q.batch(self.bid)['state'],'sent')
 def test_invalid_replacement_does_not_enter_print_queue_and_stays_paused(self):
  asyncio.run(self.review.callback(self.event('edit')))
  with self.assertRaises(UserError):asyncio.run(self.review.handle_document(self.incoming('wrong.jpg')))
  with patch('dtf_review.validate_ready',side_effect=UserError('wrong size')):
   with self.assertRaises(UserError):asyncio.run(self.review.handle_document(self.incoming(message=101)))
  self.assertEqual(self.q.batch(self.bid)['state'],'editing');self.assertEqual(len(self.q.waiting('dtf')),1);self.assertEqual(self.review.get(self.bid)['uploading'],0)
 def test_cancelled_order_rejects_stale_preview(self):
  self.q.cancel(self.q.batch_files(self.bid)[0]['id'],direction='dtf')
  with self.assertRaises(UserError):asyncio.run(self.review.callback(self.event('send')))
 def test_ready_png_validation(self):
  width,height,digest=validate_ready(self.template);self.assertEqual((width,height),(pixels(56),pixels(50)));self.assertEqual(digest,hashlib.sha256(self.payload).hexdigest())
  for size,dpi,mode in [((100,100),300,'RGBA'),((pixels(56),pixels(50)),72,'RGBA'),((pixels(56),pixels(50)),300,'RGB')]:
   path=Path(self.tmp.name)/'bad.png'
   with Image.new(mode,size) as image:image.save(path,dpi=(dpi,dpi))
   with self.assertRaises(UserError):validate_ready(path)
 def test_original_proof_phase_never_sends_mail(self):
  # Rebuild the original through the actual worker boundary, then hold it.
  self.q.db.execute('delete from dtf_reviews where batch=?',(self.bid,));self.q.db.execute("update batches set state='collecting' where id=?",(self.bid,));self.q.db.commit()
  with patch('worker.build_sheet',return_value=self.sheet),patch('worker.smtp_connect') as smtp,patch('worker.Disk') as disk:
   asyncio.run(self.worker.process_batch(self.q.batch(self.bid)));smtp.assert_not_called();disk.return_value.upload.assert_not_called()
  self.assertEqual(self.q.batch(self.bid)['state'],'review')
