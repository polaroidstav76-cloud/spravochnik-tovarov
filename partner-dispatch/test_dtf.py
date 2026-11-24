import asyncio
import hashlib
from pathlib import Path
import tempfile
import time
import unittest
from datetime import datetime
from unittest.mock import patch
from PIL import Image
from core import Queue,UserError,MOSCOW
from dtf_layout import Layout,Placement,pixels,arrange,Print
from dtf_render import inspect_art,render_png,build_sheet
from bot_features import BotFeatures
from services import email_for
from worker import Worker

class TestDTF(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.q=Queue(self.root)
        self.q.join(11,'Первый');self.q.join(22,'Второй')
        self.monday=datetime(2026,11,16,12,0,tzinfo=MOSCOW).timestamp()
    def tearDown(self):self.q.db.close();self.tmp.cleanup()
    def source(self,mid=1,size=(118,177),dpi=(300,300),copies=1):
        name=f'print-{mid}.png';src=self.root/name
        image=Image.new('RGBA',size,(255,0,0,128));image.putpixel((0,0),(0,0,0,0))
        image.save(src,**({'dpi':dpi} if dpi else {}));image.close()
        row=self.q.add(11,mid,11,name,src.stat().st_size,self.monday-5,direction='dtf')
        path=self.q.path(row);path.parent.mkdir(parents=True);path.write_bytes(src.read_bytes())
        self.q.downloaded(row['id'],hashlib.sha256(path.read_bytes()).hexdigest())
        if copies is not None:self.q.set_copies(row['id'],11,copies)
        return self.q.file(row['id'])
    def test_dpi_defines_physical_size_and_missing_dpi_rejected(self):
        row=self.source(size=(200,400),dpi=(600,600))
        info=inspect_art(self.q.path(row));self.assertEqual((info['width'],info['height']),(100,200))
        row=self.source(mid=2,dpi=None)
        with self.assertRaisesRegex(UserError,'DPI'):inspect_art(self.q.path(row))
    def test_one_copy_default_and_only_author_or_owner_can_edit(self):
        row=self.source(copies=None)
        self.assertEqual(row['copies'],1)
        self.assertEqual(row['copies_set'],1)
        token,count=BotFeatures(self.q).request(11,'dtf');self.assertEqual(count,1)
        with self.assertRaises(UserError):self.q.set_copies(row['id'],22,3)
        self.q.set_copies(row['id'],11,3)
        bid=self.q.claim('test@example.invalid',self.monday,direction='dtf');self.assertIsNotNone(bid)
        with self.assertRaises(UserError):self.q.set_copies(row['id'],11,4)
    def test_separate_schedule_mon_thu_and_editable(self):
        self.source()
        self.assertIsNone(self.q.claim('test@example.invalid',self.monday-1,direction='dtf'))
        tue=datetime(2026,11,17,13,0,tzinfo=MOSCOW).timestamp()
        self.assertIsNone(self.q.claim('test@example.invalid',tue,direction='dtf'))
        self.q.set_setting('dtf_dispatch_days','1');self.q.set_setting('dtf_dispatch_time','13:00')
        self.assertIsNotNone(self.q.claim('test@example.invalid',tue,direction='dtf'))
        self.assertEqual(self.q.setting('dispatch_time','18:00'),'18:00')
    def test_copy_edit_invalidates_send_confirmation(self):
        row=self.source(copies=2);features=BotFeatures(self.q)
        token,count=features.request(11,'dtf');self.assertEqual(count,1)
        self.q.set_copies(row['id'],11,3)
        with self.assertRaisesRegex(UserError,'Очередь изменилась'):features.confirm(token,11,'test@example.invalid')
    def test_streaming_png_preserves_rgba_and_dpi(self):
        row=self.source(size=(2,3));path=self.q.path(row);out=self.root/'render.png'
        layout=Layout(16,16,1,1,(Placement('a',2,3,2,3,False),))
        render_png(out,layout,{'a':path})
        with Image.open(out) as image:
            self.assertEqual(image.mode,'RGBA');self.assertEqual(image.size,(16,16))
            self.assertEqual(image.getpixel((0,0)),(0,0,0,0))
            self.assertEqual(image.getpixel((3,4)),(255,0,0,128))
            self.assertAlmostEqual(image.info['dpi'][0],300,places=2)
    def test_embedded_rgb_profile_and_alpha_are_supported(self):
        from PIL import ImageCms
        src=self.root/'profile.png';out=self.root/'profile-out.png'
        profile=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
        image=Image.new('RGBA',(2,3),(20,100,200,128));image.save(src,dpi=(300,300),icc_profile=profile);image.close()
        render_png(out,Layout(8,8,1,1,(Placement('a',1,1,2,3,False),)),{'a':src})
        with Image.open(out) as result:self.assertEqual(result.getpixel((1,1)),(20,100,200,128))

    def test_build_actual_sheet_copies_full_width_and_link_only_mail(self):
        self.source(copies=2);self.source(mid=2,copies=1)
        bid=self.q.claim('dtf-test@example.invalid',self.monday,manual=True,direction='dtf')
        self.q.transition(bid,'collecting','packing')
        with patch('dtf_render.arrange',wraps=arrange) as nesting:
            output=build_sheet(self.q,bid)
        self.assertEqual(len(nesting.call_args.args[0]),3)
        with Image.open(output) as image:
            self.assertEqual(image.width,pixels(56));self.assertLess(image.height,pixels(50))
            self.assertGreater(image.getchannel('A').getbbox()[3],image.height-pixels(1))
            self.assertEqual(image.mode,'RGBA');self.assertAlmostEqual(image.info['dpi'][0],300,places=2)
        batch={**self.q.batch(bid),'link':'https://example.invalid/sheet'}
        msg=email_for({'sender':'sender@example.invalid'},batch,self.q.batch_files(bid))
        self.assertIn('ДТФ',msg['Subject']);self.assertIn('Полароид-ДТФ.png',msg.get_content())
        self.assertIn('2 шт.',msg.get_content());self.assertNotIn('Первый',msg.get_content())
        self.assertEqual(list(msg.iter_attachments()),[])
    def test_full_working_width_55_cm_fits_without_rescaling(self):
        item=Print('full-width',pixels(55),pixels(10));layout=arrange([item],56)
        self.assertEqual(layout.prints[0].width,pixels(55))
        self.assertEqual(layout.width-2*layout.margin,pixels(55))
    def test_changed_source_prevents_sheet_build(self):
        row=self.source();bid=self.q.claim('test@example.invalid',self.monday,manual=True,direction='dtf')
        self.q.transition(bid,'collecting','packing');self.q.path(row).write_bytes(b'changed')
        with self.assertRaises(UserError):build_sheet(self.q,bid)
    def test_dtf_uses_own_test_confirmation_generation(self):
        self.q.set_setting('first_test_confirmed','1');self.q.set_setting('generation','8')
        self.source();bid=self.q.claim('test@example.invalid',self.monday,manual=True,direction='dtf')
        batch=self.q.batch(bid);self.assertEqual(batch['test_mode'],1);self.assertEqual(batch['generation'],0)
    def test_two_directions_use_different_recipients(self):
        worker=Worker(self.q,{'recipient':'wide@example.invalid','dtf_recipient':'dtf@example.invalid'},lambda m:None)
        self.assertEqual(worker.recipient('dtf'),'dtf@example.invalid')
        self.assertEqual(worker.recipient('wideformat'),'wide@example.invalid')

if __name__=='__main__':unittest.main()
