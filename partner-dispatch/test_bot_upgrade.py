import asyncio
import io
import struct
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from datetime import datetime
from PIL import Image
from core import Queue,UserError,MOSCOW
from file_formats import validate_content
from dtf_render import inspect_art
from worker import Worker
from progress_cards import ProgressCards
from vpn_reminder import VpnReminder

class Upgrade(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.q=Queue(self.tmp.name);self.q.join(1,'Филиал')
    def tearDown(self):self.q.db.close();self.tmp.cleanup()
    def add(self,name,direction,mid=1):return self.q.add(1,mid,1,name,32,time.time(),direction)
    def test_formats_rejected_before_queued_and_workshop_any(self):
        for direction,names in {'wideformat':['x.png','x.jpg','x.pdf','x.psd'],'dtf':['x.jpg','x.pdf','x.exe'],'photo30':['x.tif','x.psd','x.pdf']}.items():
            for name in names:
                with self.assertRaisesRegex(UserError,'не добавлен'):self.add(name,direction)
        self.assertEqual(self.q.waiting('wideformat'),[])
        self.assertEqual(self.add('архив.zip','workshop')['name'],'архив.zip')
    def test_duplicate_dtf_names_and_default_one_copy(self):
        a=self.add('same.PNG','dtf');b=self.add('same.PNG','dtf',2)
        self.assertNotEqual(a['id'],b['id']);self.assertEqual(a['copies'],1);self.assertEqual(a['copies_set'],1)
        self.q.set_copies(b['id'],1,3);self.assertEqual(self.q.file(a['id'])['copies'],1)
        self.add('same.tif','wideformat',3)
        with self.assertRaises(UserError):self.add('same.tif','wideformat',4)
    def test_content_is_not_extension(self):
        p=Path(self.tmp.name)/'fake.tif';p.write_bytes(b'%PDF-not-a-tiff')
        with self.assertRaisesRegex(UserError,'не соответствует'):validate_content(p,'wideformat','fake.tif')
        validate_content(p,'workshop','fake.tif')
    def test_psd_composite_dpi_and_alpha(self):
        p=Path(self.tmp.name)/'test.psd';resolution=struct.pack('>IHHIHH',300*65536,1,1,300*65536,1,1)
        resources=b'8BIM'+struct.pack('>H',1005)+b'\0\0'+struct.pack('>I',len(resolution))+resolution
        header=b'8BPS'+struct.pack('>H',1)+b'\0'*6+struct.pack('>HIIHH',4,2,3,8,3)
        p.write_bytes(header+struct.pack('>I',0)+struct.pack('>I',len(resources))+resources+struct.pack('>I',0)+b'\0\0'+bytes([255]*6+[0]*6+[0]*6+[128]*6))
        validate_content(p,'dtf',p.name);info=inspect_art(p)
        self.assertEqual((info['width'],info['height']),(3,2));self.assertTrue(info['transparent']);self.assertEqual(info['dpi'],(300,300))
    def test_invalid_download_removed_without_staff_deletion(self):
        row=self.add('broken.tif','wideformat');w=Worker(self.q,{},lambda x:None);messages=[]
        class Card:
            async def edit(self,text,**kw):messages.append(text)
        class Client:
            async def send_message(self,chat,text,**kw):messages.append(text);return Card()
            async def download_media(self,msg,file,progress_callback):
                Path(file).write_bytes(b'x'*32);w.running=False
        w.client=Client();w.cached[(1,1)]=SimpleNamespace(document=True)
        asyncio.run(w.download_loop())
        self.assertIsNone(self.q.file(row['id']));self.assertEqual(self.q.waiting(),[]);self.assertFalse(self.q.path(row).exists())
        self.assertTrue(any('автоматически' in m for m in messages))
    def test_progress_card_is_edited_not_spammed(self):
        sent=[];edits=[]
        class Card:
            async def edit(self,text,**kw):edits.append(text)
        class Client:
            async def send_message(self,chat,text,**kw):sent.append(text);return Card()
        w=SimpleNamespace(client=Client());cards=ProgressCards(w)
        async def run():
            await cards.update('a',1,'File','Загрузка',50,100,force=True)
            await cards.update('a',1,'File','Загрузка',70,100)
            await cards.update('a',1,'File','Сохранён',force=True)
        asyncio.run(run());self.assertEqual(len(sent),1);self.assertEqual(len(edits),1);self.assertIn('50%',sent[0])
    def test_vpn_slots_follow_days_time_queue_and_no_manual(self):
        self.add('x.tif','wideformat');self.q.set_setting('automatic','1');self.q.set_setting('dispatch_time','18:00')
        w=Worker(self.q,{'recipient':'test@example.invalid'},lambda x:None);v=VpnReminder(w)
        now=datetime(2026,11,17,17,45,tzinfo=MOSCOW)
        slots=v.slots(now);self.assertEqual(slots[0]['due_at'],'2026-11-17T18:00:00+03:00');self.assertTrue(all(x['direction']=='wideformat' for x in slots))
        self.q.set_setting('dispatch_time','19:00');self.assertEqual(v.slots(now)[0]['due_at'],'2026-11-17T19:00:00+03:00')
        self.q.set_setting('automatic','0');self.assertEqual(v.slots(now),[])
