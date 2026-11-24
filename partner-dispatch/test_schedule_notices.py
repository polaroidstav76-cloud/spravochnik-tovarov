import asyncio
import tempfile
import unittest
from datetime import datetime,timedelta
from unittest.mock import AsyncMock
from types import SimpleNamespace
from core import Queue,MOSCOW,UserError
from bot_features import BotFeatures

class ScheduleNotices(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.q=Queue(self.tmp.name);self.q.join(11,'Первый');self.q.join(22,'Второй');self.f=BotFeatures(self.q)
  self.now=datetime(2026,11,23,17,30,tzinfo=MOSCOW);self.q.set_setting('automatic','1');self.q.set_setting('dispatch_time','18:00');self.q.set_setting('dispatch_days','0');self.client=SimpleNamespace(send_message=AsyncMock())
 def tearDown(self):self.q.db.close();self.tmp.cleanup()
 def tick(self,now=None):asyncio.run(self.f.remind(self.client,lambda _: 'test@example.invalid',now or self.now))
 def add(self,uid=11,direction='wideformat',mid=1):return self.q.add(uid,mid,uid,'test.png' if direction=='dtf' else f'test-{uid}-{mid}.tif',10,self.now.timestamp(),direction)
 def test_empty_queue_all_staff_once_and_restart(self):
  self.tick(self.now-timedelta(seconds=1));self.assertEqual(self.client.send_message.await_count,0)
  self.tick();self.assertEqual(self.client.send_message.await_count,2);self.assertEqual({c.args[0] for c in self.client.send_message.await_args_list},{11,22})
  self.assertIn('Через 30 минут',self.client.send_message.await_args.args[1]);self.assertIn('Широкоформатная печать',self.client.send_message.await_args.args[1])
  self.add();self.tick();self.q.db.close();self.q=Queue(self.tmp.name);self.f=BotFeatures(self.q);self.tick();self.assertEqual(self.client.send_message.await_count,2)
 def test_retry_only_undelivered_user(self):
  self.client.send_message.side_effect=[None,ConnectionError()];self.tick();self.client.send_message.side_effect=None;self.tick();self.assertEqual(self.client.send_message.await_count,3);self.assertEqual(self.client.send_message.await_args.args[0],22)
 def test_edited_time_days_disabled_and_dtf(self):
  self.q.set_setting('dispatch_time','19:00');self.tick();self.assertEqual(self.client.send_message.await_count,0)
  self.q.set_setting('dispatch_days','1');self.tick(self.now+timedelta(hours=1));self.assertEqual(self.client.send_message.await_count,0)
  self.q.set_setting('dtf_automatic','1');self.q.set_setting('dtf_dispatch_days','0,3');self.q.set_setting('dtf_dispatch_time','18:00');self.tick();self.assertEqual(self.client.send_message.await_count,2);self.assertIn('ДТФ-печать',self.client.send_message.await_args.args[1])
  self.q.set_setting('dtf_automatic','0');self.tick(self.now+timedelta(days=3));self.assertEqual(self.client.send_message.await_count,2)
 def test_no_reminder_after_slot_and_late_start_actual_minutes(self):
  self.tick(self.now+timedelta(minutes=30));self.assertEqual(self.client.send_message.await_count,0)
  self.tick(self.now+timedelta(minutes=10));self.assertIn('Через 20 минут',self.client.send_message.await_args.args[1])
 def test_next_slot_after_midnight(self):
  self.q.set_setting('dispatch_days','1');self.q.set_setting('dispatch_time','00:10');now=self.now.replace(hour=23,minute=40);self.tick(now);self.assertEqual(self.client.send_message.await_count,2);self.assertIn('Через 30 минут',self.client.send_message.await_args.args[1])
 def test_undo_only_own_unclaimed_and_newest(self):
  other=self.add(22);mine=self.add();self.assertEqual(self.f.last_upload(11,'wideformat')['id'],mine['id'])
  with self.assertRaises(UserError):self.f.undo(22,'wideformat',mine['id'])
  self.f.undo(11,'wideformat',mine['id']);self.assertEqual(len(self.q.waiting()),1);self.assertEqual(self.q.waiting()[0]['id'],other['id'])
  bid=self.q.claim('test@example.invalid',self.now.timestamp(),manual=True)
  with self.assertRaises(UserError):self.f.undo(22,'wideformat',other['id'])
  with self.assertRaisesRegex(UserError,'обрабатывается'):self.f.request(11,'wideformat')
 def test_two_confirmations_do_not_duplicate_order(self):
  self.add();one,_=self.f.request(11,'wideformat');two,_=self.f.request(22,'wideformat');self.f.confirm(one,11,'test@example.invalid')
  with self.assertRaises(UserError):self.f.confirm(two,22,'test@example.invalid')
  self.assertEqual(self.q.db.execute('select count(*) from batches').fetchone()[0],1)
 def test_names_branch_dtf_copies_and_snapshot_updates(self):
  row=self.add(direction='dtf');self.q.set_copies(row['id'],11,3);text='\n'.join(self.f.file_lines('dtf'));self.assertIn('Первый',text);self.assertIn('3 коп.',text);self.assertIn('test.png',text)
  self.f.undo(11,'dtf',row['id']);self.assertEqual(list(self.f.file_lines('dtf')),[])
