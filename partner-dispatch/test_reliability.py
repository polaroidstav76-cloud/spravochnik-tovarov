import asyncio,tempfile,time,unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock
from core import Queue
from worker import Worker
from progress_cards import ProgressCards
class Reliability(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.q=Queue(self.tmp.name);self.q.join(1,'Test');self.w=Worker(self.q,{},lambda _:None)
 def tearDown(self):self.q.db.close();self.tmp.cleanup()
 def test_replayed_and_concurrent_message_is_processed_once(self):
  self.w._on_message=AsyncMock();event=SimpleNamespace(is_private=True,chat_id=1,id=100)
  async def run():await asyncio.gather(self.w.on_message(event),self.w.on_message(event))
  asyncio.run(run());self.w._on_message.assert_awaited_once()
  other=Worker(self.q,{},lambda _:None);other._on_message=AsyncMock();asyncio.run(other.on_message(event));other._on_message.assert_not_awaited()
 def test_callback_replay_only_answers_without_second_action(self):
  self.w._on_callback=AsyncMock();event=SimpleNamespace(query=SimpleNamespace(query_id=100),answer=AsyncMock())
  async def run():await self.w.on_callback(event);await self.w.on_callback(event)
  asyncio.run(run());self.w._on_callback.assert_awaited_once();event.answer.assert_awaited_once()
 def test_rejected_file_removed_and_id_never_reused(self):
  r=self.q.add(1,1,1,'bad.png',10,time.time(),'dtf');p=self.q.path(r);p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'bad');self.q.download_failed(r['id'],time.time(),'DPI');self.q.cancel(r['id']);self.q.discard_rejected(r['id'])
  self.assertFalse(p.exists());self.assertIsNone(self.q.file(r['id']));self.assertFalse(self.q.accept_event('message','1:1'))
  new=self.q.add(1,2,1,'good.png',10,time.time(),'dtf');self.assertGreater(new['id'],r['id'])
 def test_progress_parallel_calls_send_one_card(self):
  sent=[]
  async def send(*a,**kw):await asyncio.sleep(.01);sent.append(1);return SimpleNamespace(edit=AsyncMock())
  w=SimpleNamespace(client=SimpleNamespace(send_message=send));cards=ProgressCards(w)
  async def run():await asyncio.gather(cards.update('same',1,'A','Loading',force=True),cards.update('same',1,'A','Done',force=True))
  asyncio.run(run());self.assertEqual(len(sent),1)
 def test_dtf_callback_routes_without_selected_direction(self):
  self.w.dtf_review.callback=AsyncMock();event=SimpleNamespace(is_private=True,sender_id=1,data=b'dtf:abc:1:edit',answer=AsyncMock())
  asyncio.run(self.w.on_callback(event));self.w.dtf_review.callback.assert_awaited_once();event.answer.assert_not_awaited()
 def test_main_keyboard_has_two_buttons_per_row_max_five(self):
  self.q.set_setting('owner',1);self.w.choose(1,'dtf');event=SimpleNamespace(sender_id=1,respond=AsyncMock())
  asyncio.run(self.w.reply(event,'Menu'));buttons=event.respond.call_args.kwargs['buttons'];self.assertLessEqual(len(buttons),5);self.assertTrue(all(len(row)==2 for row in buttons))
