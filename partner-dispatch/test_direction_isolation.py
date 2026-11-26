import asyncio,tempfile,time,unittest
from datetime import datetime,timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock
from core import Queue
from worker import Worker
class DirectionIsolation(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.q=Queue(self.tmp.name);self.q.join(1,'Branch');self.w=Worker(self.q,{},lambda _:None);self.w.reply=AsyncMock()
 def tearDown(self):self.q.db.close();self.tmp.cleanup()
 def event(self,name):return SimpleNamespace(is_private=True,sender_id=1,chat_id=1,id=100,raw_text='',document=True,photo=False,file=SimpleNamespace(name=name,size=20),date=datetime.now(timezone.utc),message=object())
 def test_other_directions_never_intercepted_by_pending_dtf(self):
  self.w.dtf_review.handle_document=AsyncMock(return_value=True)
  for n,(direction,name) in enumerate([('wideformat','wide.tif'),('workshop','work.pdf'),('photo30','photo.jpg')]):
   self.w.choose(1,direction);event=self.event(name);event.id+=n;asyncio.run(self.w.on_message(event));self.assertEqual(self.q.waiting(direction)[0]['name'],name)
  self.w.dtf_review.handle_document.assert_not_awaited()
 def test_dtf_replacement_still_handled_in_dtf(self):
  self.w.choose(1,'dtf');self.w.dtf_review.handle_document=AsyncMock(return_value=True);asyncio.run(self.w.on_message(self.event('ready.png')));self.w.dtf_review.handle_document.assert_awaited_once();self.assertEqual(self.q.waiting('dtf'),[])
 def test_review_defensively_refuses_non_dtf_direction(self):
  self.w.choose(1,'wideformat');self.w.dtf_review.editing_for=lambda uid:(_ for _ in ()).throw(AssertionError('Wrong direction queried editing state'))
  self.assertFalse(asyncio.run(self.w.dtf_review.handle_document(self.event('wide.tif'))))
