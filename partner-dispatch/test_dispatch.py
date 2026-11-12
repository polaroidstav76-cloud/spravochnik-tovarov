import asyncio
import hashlib
import os
import sqlite3
import tempfile
import time
import unittest
import zipfile
from datetime import datetime
from pathlib import Path
from unittest.mock import patch
from core import Queue,UserError,MOSCOW,MAX_BYTES,due_day,safe_name,build_archive
from worker import Worker

CONFIG={'recipient':'test-recipient@example.invalid','sender':'test-recipient@example.invalid','smtp_password':'test','disk_token':'test'}

class TestDispatch(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.q=Queue(self.tmp.name);self.q.join(11,'Первый филиал');self.q.join(22,'Второй филиал')
        self.now=datetime(2026,11,12,18,0,tzinfo=MOSCOW).timestamp()
        self.logs=[]
    def tearDown(self):self.q.db.close();self.tmp.cleanup()
    def file(self,chat=11,mid=1,name='самоклейка 50х50 см.tif',data=b'original-tiff',stamp=None):
        r=self.q.add(chat,mid,chat,name,len(data),stamp or self.now-10)
        p=self.q.path(r);p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        self.q.downloaded(r['id'],hashlib.sha256(data).hexdigest());return self.q.file(r['id'])
    def test_cutoff_and_duplicates(self):
        self.assertEqual(due_day(self.now-1),'2026-11-12')
        self.assertEqual(due_day(self.now),'2026-11-13')
        r=self.file();self.file()
        self.assertEqual(len(self.q.waiting()),1)
        self.assertEqual(self.q.waiting()[0]['id'],r['id'])
        with self.assertRaises(UserError):self.q.add(999,1,999,'a.tif',1,self.now)
        for size in [0,MAX_BYTES+1]:
            with self.assertRaises(UserError):self.q.add(11,9,11,'a.tif',size,self.now)
    def test_names_and_unchanged_archives(self):
        a=self.file();b=self.file(chat=22,data=b'different original')
        self.assertEqual(safe_name('../../a.tif'),'a.tif')
        batch=self.q.claim(CONFIG['recipient'],self.now)
        self.assertTrue(self.q.transition(batch,'collecting','packing'))
        p=build_archive(self.q,batch)
        with zipfile.ZipFile(p) as z:
            names=[n for n in z.namelist() if n.endswith('.tif')]
            self.assertEqual(len(names),2)
            self.assertEqual(z.read(names[0]),b'original-tiff')
            self.assertEqual(z.read(names[1]),b'different original')
            self.assertTrue(all(Path(n).name==a['name'] for n in names))
    def test_cancel_rebuilds_same_snapshot(self):
        a=self.file();b=self.file(mid=2)
        batch=self.q.claim(CONFIG['recipient'],self.now,manual=True)
        self.q.transition(batch,'collecting','uploading')
        self.q.cancel(a['id'])
        self.assertEqual(self.q.batch(batch)['state'],'invalidated')
        self.assertEqual([r['id'] for r in self.q.batch_files(batch)],[b['id']])
        self.assertFalse(self.q.accept_smtp(batch))
        self.q.transition(batch,'invalidated','collecting');self.q.transition(batch,'collecting','packing')
        with zipfile.ZipFile(build_archive(self.q,batch)) as z:self.assertEqual(len([n for n in z.namelist() if n.endswith('.tif')]),1)
    def test_send_boundary_and_crash(self):
        a=self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        self.q.transition(bid,'collecting','ready');self.assertTrue(self.q.accept_smtp(bid))
        with self.assertRaises(UserError):self.q.cancel(a['id'])
        self.assertEqual(len(self.q.waiting()),0)
        self.q.db.close();self.q=Queue(self.tmp.name)
        self.assertEqual(self.q.batch(bid)['state'],'uncertain')
        self.assertIsNone(self.q.claim(CONFIG['recipient'],self.now))
        self.q.reset_uncertain(bid,False);self.assertEqual(self.q.batch(bid)['state'],'collecting')
    def test_empty_and_after_cutoff(self):
        self.assertIsNone(self.q.claim(CONFIG['recipient'],self.now))
        self.file(stamp=self.now+10)
        self.assertIsNone(self.q.claim(CONFIG['recipient'],self.now))
        self.assertIsNotNone(self.q.claim(CONFIG['recipient'],self.now,manual=True))
    def test_tampering_stops_send(self):
        a=self.file();self.q.path(a).write_bytes(b'tampered-data')
        bid=self.q.claim(CONFIG['recipient'],self.now);self.q.transition(bid,'collecting','packing')
        with self.assertRaises(UserError):build_archive(self.q,bid)
    def test_delete_while_upload_prevents_email(self):
        a=self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        queue=self.q;deleted=[]
        class FakeDisk:
            def __init__(self,token):pass
            def remove_generated(self,remote):deleted.append(remote)
            def upload(self,file,remote):queue.cancel(a['id']);return 'https://disk.yandex.ru/test'
        worker=Worker(self.q,CONFIG,self.logs.append)
        with patch('worker.Disk',FakeDisk),patch('worker.smtp_connect') as smtp:
            asyncio.run(worker.process_batch(self.q.batch(bid)))
            smtp.assert_not_called()
        self.assertEqual(self.q.batch(bid)['state'],'invalidated')
        self.assertTrue(deleted)
    def test_smtp_ambiguity_does_not_auto_retry(self):
        self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        class FakeDisk:
            def __init__(self,token):pass
            def remove_generated(self,remote):pass
            def upload(self,file,remote):return 'https://disk.yandex.ru/test'
        class FakeSMTP:
            def send_message(self,msg):raise TimeoutError()
            def close(self):pass
        worker=Worker(self.q,CONFIG,self.logs.append)
        with patch('worker.Disk',FakeDisk),patch('worker.smtp_connect',return_value=FakeSMTP()):
            asyncio.run(worker.process_batch(self.q.batch(bid)))
        self.assertEqual(self.q.batch(bid)['state'],'uncertain')
        self.assertIsNone(self.q.active_batch())
    def test_success_and_notification_deduplication(self):
        self.file();self.file(chat=22);self.q.set_setting('owner',11)
        bid=self.q.claim(CONFIG['recipient'],self.now)
        class FakeDisk:
            def __init__(self,token):pass
            def remove_generated(self,remote):pass
            def upload(self,file,remote):return 'https://disk.yandex.ru/test'
        class FakeSMTP:
            def send_message(self,msg):self.msg=msg;return {}
            def close(self):pass
        sent=[]
        class FakeTelegram:
            async def send_message(self,chat,text,**kw):
                sent.append((chat,text))
                if chat==22:raise TimeoutError()
        worker=Worker(self.q,CONFIG,self.logs.append);worker.client=FakeTelegram()
        with patch('worker.Disk',FakeDisk),patch('worker.smtp_connect',return_value=FakeSMTP()):
            asyncio.run(worker.process_batch(self.q.batch(bid)))
        self.assertEqual(self.q.batch(bid)['state'],'sent')
        asyncio.run(worker.notify());asyncio.run(worker.notify())
        self.assertEqual(len([m for m in sent if m[0]==11]),1)
        self.assertNotIn('https://',next(m[1] for m in sent if m[0]==22))
    def test_telegram_buttons_and_names_only(self):
        try:
            import telethon
        except ImportError:self.skipTest('Install pinned local wheels first')
        from core import BUTTONS,DIRECTIONS,UPLOAD,BACK
        class Event:
            is_private=True;sender_id=11;chat_id=11;photo=None;document=None
            def __init__(self,text):self.raw_text=text;self.messages=[]
            async def respond(self,text,**kw):self.messages.append((text,kw))
        self.file();self.q.set_setting('owner',11)
        worker=Worker(self.q,{**CONFIG,'owner_code':'owner','join_code':'staff'},self.logs.append)
        async def check():
            event=Event('/start');await worker.on_message(event)
            self.assertEqual([b.button.text for row in event.messages[0][1]['buttons'] for b in row],[r['label'] for r in DIRECTIONS.values()])
            event=Event(DIRECTIONS['wideformat']['label']);await worker.on_message(event)
            event=Event(BUTTONS[0]);await worker.on_message(event)
            self.assertEqual(event.messages[0][0],'самоклейка 50х50 см.tif')
            keyboard=event.messages[0][1]['buttons']
            self.assertEqual([b.button.text for row in keyboard for b in row],[UPLOAD,*BUTTONS,BACK])
            event=Event(BUTTONS[2]);await worker.on_message(event)
            button=event.messages[0][1]['buttons'][0][0]
            self.assertTrue(button.type.data.startswith(b'delete:'))
            event=Event('/owner не-ASCII');await worker.on_message(event)
            event=Event(BUTTONS[1]);await worker.on_message(event)
            self.assertIsNotNone(self.q.active_batch())
        asyncio.run(check())
    def test_direction_queues_do_not_mix(self):
        wide=self.file()
        dtf=self.q.add(22,55,22,'dtf.png',4,self.now-10,direction='dtf')
        self.assertEqual([r['id'] for r in self.q.waiting()],[wide['id']])
        self.assertEqual([r['id'] for r in self.q.waiting('dtf')],[dtf['id']])
        bid=self.q.claim(CONFIG['recipient'],self.now,manual=True)
        self.assertEqual([r['id'] for r in self.q.batch_files(bid)],[wide['id']])
        self.assertIsNone(self.q.file(dtf['id'])['batch'])
        with self.assertRaises(UserError):self.q.cancel(dtf['id'],direction='wideformat')
    def test_dtf_placeholder_does_not_accept_files(self):
        try:import telethon
        except ImportError:self.skipTest('Install pinned local wheels first')
        from core import DIRECTIONS
        class Event:
            is_private=True;sender_id=11;chat_id=11;photo=None;document=True
            def __init__(self,text):self.raw_text=text;self.messages=[]
            async def respond(self,text,**kw):self.messages.append((text,kw))
        worker=Worker(self.q,{**CONFIG,'owner_code':'owner','join_code':'staff'},self.logs.append)
        async def check():
            worker.choose(11,'wideformat')
            event=Event(DIRECTIONS['dtf']['label']);await worker.on_message(event)
            self.assertIsNone(worker.direction(11))
            event=Event('');await worker.on_message(event)
            self.assertIn('Сначала выберите',event.messages[0][0])
            self.assertEqual(len(self.q.waiting()),0)
        asyncio.run(check())
    @unittest.skipUnless(os.environ.get('TEST_LARGE_FILE')=='1','Explicit 500 MiB streaming test')
    def test_500_mib_original(self):
        r=self.q.add(11,99,11,'баннер 500 МБ.tif',MAX_BYTES,self.now-1)
        p=self.q.path(r);p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('wb') as f:f.truncate(MAX_BYTES)
        with p.open('rb') as f:sha=hashlib.file_digest(f,'sha256').hexdigest()
        self.q.downloaded(r['id'],sha)
        bid=self.q.claim(CONFIG['recipient'],self.now);self.q.transition(bid,'collecting','packing')
        p=build_archive(self.q,bid)
        with zipfile.ZipFile(p) as z:
            entry=next(i for i in z.infolist() if i.filename.endswith('.tif'))
            self.assertEqual(entry.file_size,MAX_BYTES)
            with z.open(entry) as f:self.assertEqual(hashlib.file_digest(f,'sha256').hexdigest(),sha)

if __name__=='__main__':unittest.main(verbosity=2)
