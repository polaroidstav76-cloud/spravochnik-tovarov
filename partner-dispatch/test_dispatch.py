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
    def file(self,chat=11,mid=1,name=None,data=b'original-tiff',stamp=None):
        name=name or f'самоклейка {chat}-{mid} 50х50 см.tif'
        r=self.q.add(chat,mid,chat,name,len(data),stamp or self.now-10)
        p=self.q.path(r);p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        self.q.downloaded(r['id'],hashlib.sha256(data).hexdigest());return self.q.file(r['id'])
    def test_owner_connection_replies_without_changing_code(self):
        from types import SimpleNamespace
        from unittest.mock import AsyncMock
        worker=Worker(self.q,dict(CONFIG,owner_code='sample-secret'),self.logs.append)
        worker.reply=AsyncMock()
        event=SimpleNamespace(is_private=True,sender_id=99,raw_text='/owner wrong',respond=AsyncMock())
        asyncio.run(worker.on_message(event))
        self.assertEqual(self.q.setting('owner_last_result'),'code_mismatch')
        self.assertFalse(self.q.setting('owner'))
        event.respond.assert_awaited_once()
        self.assertNotIn('sample-secret',' '.join(self.logs))
        event.raw_text='/owner sample-secret'
        asyncio.run(worker.on_message(event))
        self.assertEqual(self.q.setting('owner'),'99')
        self.assertEqual(self.q.setting('owner_last_result'),'connected')
        worker.reply.assert_awaited_once()
        event.sender_id=100
        asyncio.run(worker.on_message(event))
        self.assertEqual(self.q.setting('owner_last_result'),'different_owner')
        self.assertEqual(self.q.setting('owner'),'99')
        self.assertEqual(worker.c['owner_code'],'sample-secret')

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
            self.assertEqual({Path(n).name for n in names},{a['name'],b['name']})
    def test_partner_package_hides_branches_and_has_no_attachments(self):
        from services import email_for
        self.file(name='баннер.tif');self.file(chat=22,name='холст.tif')
        bid=self.q.claim(CONFIG['recipient'],self.now)
        self.q.transition(bid,'collecting','packing')
        archive=build_archive(self.q,bid)
        self.assertEqual(archive.name,'Полароид.zip')
        with zipfile.ZipFile(archive) as z:
            self.assertEqual(set(z.namelist()),{'Полароид/баннер.tif','Полароид/холст.tif'})
        msg=email_for(CONFIG,{**self.q.batch(bid),'link':'https://example.invalid/archive'},self.q.batch_files(bid))
        text=msg.get_content()
        for branch in ['Первый филиал','Второй филиал']:
            self.assertNotIn(branch,text)
        self.assertIn('Полароид.zip',text)
        self.assertIn('https://example.invalid/archive',text)
        self.assertEqual(list(msg.iter_attachments()),[])

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
        self.assertEqual(len(self.q.waiting()),1)
        self.q.db.close();self.q=Queue(self.tmp.name)
        self.assertEqual(self.q.batch(bid)['state'],'uncertain')
        self.assertIsNone(self.q.claim(CONFIG['recipient'],self.now))
        self.q.reset_uncertain(bid,False);self.assertEqual(self.q.batch(bid)['state'],'collecting')
    def test_duplicate_names_rejected_until_order_completed(self):
        self.file(name='Макет.tif')
        with self.assertRaisesRegex(UserError,'Переименуйте'):
            self.q.add(22,9,22,'макет.TIF',12,self.now)
        self.assertEqual(len(self.q.waiting()),1)
        bid=self.q.claim(CONFIG['recipient'],self.now)
        self.q.transition(bid,'collecting','sent')
        self.assertIsNotNone(self.q.add(22,9,22,'Макет.tif',12,self.now))

    def test_duplicate_add_is_atomic_between_two_staff(self):
        from concurrent.futures import ThreadPoolExecutor
        def add(uid):
            try:self.q.add(uid,99,uid,'одинаковое.tif',4,self.now);return True
            except UserError:return False
        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sum(pool.map(add,[11,22])),1)
        self.assertEqual(len(self.q.waiting()),1)

    def test_send_confirmation_expires_and_detects_changed_queue(self):
        from bot_features import BotFeatures
        features=BotFeatures(self.q);self.file()
        token,count=features.request(11,'wideformat');self.assertEqual(count,1)
        with self.assertRaises(UserError):features.confirm(token,22,CONFIG['recipient'])
        self.file(mid=2)
        with self.assertRaisesRegex(UserError,'Очередь изменилась'):features.confirm(token,11,CONFIG['recipient'])
        token,count=features.request(11,'wideformat')
        bid=features.confirm(token,11,CONFIG['recipient'])
        self.assertEqual(len(self.q.batch_files(bid)),2)
        with self.assertRaises(UserError):features.confirm(token,11,CONFIG['recipient'])

    def test_confirmation_timeout_does_not_send(self):
        from bot_features import BotFeatures
        features=BotFeatures(self.q);self.file()
        token,_=features.request(11,'wideformat')
        with patch('bot_features.time.time',return_value=time.time()+301):
            with self.assertRaises(UserError):features.confirm(token,11,CONFIG['recipient'])
        self.assertIsNone(self.q.active_batch())

    def test_queue_broadcast_names_only_updates_and_retries(self):
        from bot_features import BotFeatures
        from unittest.mock import AsyncMock
        features=BotFeatures(self.q);self.file(name='самоклейка.tif')
        client=type('Client',(),{'send_message':AsyncMock(side_effect=ConnectionError())})()
        asyncio.run(features.broadcast(client))
        client.send_message=AsyncMock()
        asyncio.run(features.broadcast(client));asyncio.run(features.broadcast(client))
        self.assertEqual(client.send_message.await_count,8)
        texts=[call.args[1] for call in client.send_message.await_args_list if 'Широкоформатная печать' in call.args[1]]
        self.assertTrue(all('самоклейка.tif' in t and 'Первый филиал' not in t for t in texts))
        bid=self.q.claim(CONFIG['recipient'],self.now);self.q.transition(bid,'collecting','sent')
        asyncio.run(features.broadcast(client))
        self.assertEqual(client.send_message.await_count,10)
        self.assertIn('Файлов, ожидающих отправки, нет',client.send_message.await_args.args[1])
        self.q.db.close();self.q=Queue(self.tmp.name)
        asyncio.run(BotFeatures(self.q).broadcast(client))
        self.assertEqual(client.send_message.await_count,10)

    def test_manual_claim_stops_retries_and_is_single_operator(self):
        self.q.set_setting('owner',11);self.q.set_setting('alert_branch','Ответственный')
        self.q.join(22,'Ответственный');self.q.set_setting('alert_role:22','Ответственный')
        self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        worker=Worker(self.q,CONFIG,self.logs.append)
        taken=worker.handoff.take(bid,22,0)
        self.assertEqual(taken['state'],'manual')
        self.assertIsNone(self.q.active_batch())
        with self.assertRaises(UserError):worker.handoff.take(bid,11,0)
        with self.assertRaises(UserError):self.q.claim(CONFIG['recipient'],self.now,manual=True)
        with patch('worker.Disk') as disk:
            asyncio.run(worker.process_batch(taken));disk.return_value.upload.assert_not_called()
        worker.handoff.finish(bid,22,0)
        self.assertEqual(self.q.batch(bid)['state'],'manual_sent')
        self.assertEqual(self.q.waiting(),[])

    def test_manual_delete_invalidates_link_and_old_buttons(self):
        self.q.set_setting('owner',11)
        row=self.file();self.file(mid=2)
        bid=self.q.claim(CONFIG['recipient'],self.now);worker=Worker(self.q,CONFIG,self.logs.append)
        self.q.transition(bid,'collecting','ready',link='https://example.invalid/old',remote_path='disk:/Cloudshop-Print/'+('a'*32)+'_'+('b'*32)+'/Полароид.zip')
        worker.handoff.pause(bid,'ready','Проверка');worker.handoff.take(bid,11,0)
        self.q.cancel(row['id'])
        batch=self.q.batch(bid)
        self.assertIsNone(batch['link']);self.assertTrue(batch['needs_revoke'])
        self.assertEqual(batch['manual_revision'],1)
        with self.assertRaises(UserError):worker.handoff.finish(bid,11,0)
        worker.handoff.finish(bid,11,1)

    def test_manual_originals_without_disk_and_no_automatic_email(self):
        from types import SimpleNamespace
        from unittest.mock import AsyncMock
        self.q.set_setting('owner',11);row=self.file()
        bid=self.q.claim(CONFIG['recipient'],self.now);worker=Worker(self.q,CONFIG,self.logs.append)
        worker.handoff.take(bid,11,0);worker.handoff.request_files(bid,11,0)
        original=SimpleNamespace(document=object())
        async def send_file(*args,**kw):
            self.assertIs(args[1],original.document);worker.running=False
            return SimpleNamespace(id=100)
        worker.client=SimpleNamespace(get_messages=AsyncMock(return_value=original),send_file=AsyncMock(side_effect=send_file))
        with patch('worker.smtp_connect') as smtp,patch('handoff.Disk') as disk:
            asyncio.run(worker.handoff.file_loop(worker))
            smtp.assert_not_called();disk.assert_not_called()
        self.assertEqual(worker.client.send_file.await_count,1)
        state=self.q.db.execute('select state from handoff_files').fetchone()[0]
        self.assertEqual(state,'done')

    def test_delay_alerts_only_for_active_download_or_started_order(self):
        from monitoring import Monitoring
        self.q.set_setting('owner',11)
        self.q.add(11,5,11,'долго.tif',4,self.now-1000)
        monitor=Monitoring(self.q)
        with patch('monitoring.time.time',return_value=self.now):asyncio.run(monitor.check_delays())
        keys=[r[0] for r in self.q.db.execute('select id from operator_alerts')]
        self.assertTrue(any(k.startswith('file:') for k in keys))
        self.assertFalse(any(k.startswith('delay:') for k in keys))
        bid=self.q.claim(CONFIG['recipient'],self.now)
        with patch('monitoring.time.time',return_value=self.now+1900):asyncio.run(monitor.check_delays())
        self.assertIsNotNone(self.q.db.execute('select 1 from operator_alerts where id=?',('delay:'+bid,)).fetchone())

    def test_operator_alerts_require_separate_role_and_retry_after_offline(self):
        from monitoring import Monitoring
        from unittest.mock import AsyncMock
        self.q.set_setting('owner',11);self.q.set_setting('alert_branch','Ответственный')
        self.q.join(22,'Ответственный')
        monitor=Monitoring(self.q)
        self.assertEqual(monitor.targets(),{11})
        self.q.set_setting('alert_role:22','Ответственный')
        self.assertEqual(monitor.targets(),{11,22})
        self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        monitor.failure(bid,'Ошибка соединения')
        client=type('Client',(),{'send_message':AsyncMock(side_effect=ConnectionError())})()
        asyncio.run(monitor.notify(client))
        self.q.db.close();self.q=Queue(self.tmp.name);monitor=Monitoring(self.q)
        client.send_message=AsyncMock()
        asyncio.run(monitor.notify(client));asyncio.run(monitor.notify(client))
        self.assertEqual(client.send_message.await_count,2)
        self.q.set_setting('alert_branch','Другая точка')
        self.assertEqual(monitor.targets(),{11})

    def test_disk_space_warning_once_per_low_space_episode(self):
        from monitoring import Monitoring
        from unittest.mock import AsyncMock
        self.q.set_setting('owner',11);monitor=Monitoring(self.q)
        client=type('Client',(),{'send_message':AsyncMock()})()
        with patch('monitoring.Disk') as disk,patch('monitoring.time.time',return_value=self.now):
            disk.return_value.check.return_value=1024**3
            asyncio.run(monitor.check_space(CONFIG));asyncio.run(monitor.notify(client))
            self.q.set_setting('space_check_after','0')
            asyncio.run(monitor.check_space(CONFIG));asyncio.run(monitor.notify(client))
            self.assertEqual(client.send_message.await_count,1)
            disk.return_value.check.return_value=20*1024**3
            self.q.set_setting('space_check_after','0');asyncio.run(monitor.check_space(CONFIG))
            self.assertEqual(self.q.setting('low_space_episode'),'')

    def test_responsible_join_does_not_change_owner_and_history_survives(self):
        from types import SimpleNamespace
        from unittest.mock import AsyncMock
        self.q.set_setting('owner',11);self.q.set_setting('alert_branch','Ответственный')
        worker=Worker(self.q,dict(CONFIG,responsible_code='sample-role-secret'),self.logs.append)
        worker.reply=AsyncMock()
        event=SimpleNamespace(is_private=True,sender_id=99,raw_text='/responsible sample-role-secret',respond=AsyncMock())
        asyncio.run(worker.on_message(event))
        self.assertEqual(worker.monitor.targets(),{11,99})
        self.assertEqual(self.q.setting('owner'),'11')
        self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        self.q.db.close();self.q=Queue(self.tmp.name)
        history=self.q.history()
        self.assertEqual(history[0]['id'],bid)
        self.assertEqual(history[0]['file_count'],1)

    def test_custom_schedule_days_time_and_late_arrivals(self):
        self.q.set_setting('dispatch_time','16:30')
        self.q.set_setting('dispatch_days','0,2,4')
        fri=datetime(2026,11,13,16,30,tzinfo=MOSCOW).timestamp()
        self.file(stamp=fri-1)
        self.assertIsNone(self.q.claim(CONFIG['recipient'],fri-1))
        thu=datetime(2026,11,12,18,0,tzinfo=MOSCOW).timestamp()
        self.assertIsNone(self.q.claim(CONFIG['recipient'],thu))
        self.assertIsNotNone(self.q.claim(CONFIG['recipient'],fri))
        self.q.db.execute("update batches set state='sent'");self.q.db.commit()
        self.file(mid=2,stamp=fri)
        self.assertIsNone(self.q.claim(CONFIG['recipient'],fri+60))
        sat=datetime(2026,11,14,18,0,tzinfo=MOSCOW).timestamp()
        self.assertIsNone(self.q.claim(CONFIG['recipient'],sat))
        mon=datetime(2026,11,16,16,30,tzinfo=MOSCOW).timestamp()
        self.assertIsNotNone(self.q.claim(CONFIG['recipient'],mon))

    def test_retry_is_ten_minutes_and_persists_restart(self):
        self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        worker=Worker(self.q,CONFIG,self.logs.append)
        with patch('worker.time.time',return_value=self.now),patch('worker.Disk') as disk:
            disk.return_value.upload.side_effect=UserError('Нет соединения')
            asyncio.run(worker.process_batch(self.q.batch(bid)))
        self.assertEqual(float(self.q.setting('retry_at:'+bid)),self.now+600)
        self.q.db.close();self.q=Queue(self.tmp.name)
        worker=Worker(self.q,CONFIG,self.logs.append)
        with patch('worker.time.time',return_value=self.now+599),patch('worker.Disk') as disk:
            asyncio.run(worker.process_batch(self.q.batch(bid)))
            disk.return_value.upload.assert_not_called()
        self.assertEqual(self.q.batch(bid)['state'],'collecting')

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
            self.assertEqual([b.button.text for row in event.messages[0][1]['buttons'] for b in row],[r['label'] for r in DIRECTIONS.values()]+['Ручная отправка'])
            event=Event(DIRECTIONS['wideformat']['label']);await worker.on_message(event)
            event=Event(BUTTONS[0]);await worker.on_message(event)
            self.assertEqual(event.messages[0][0],self.q.waiting()[0]['name'])
            keyboard=event.messages[0][1]['buttons']
            self.assertEqual([b.button.text for row in keyboard for b in row],[UPLOAD,*BUTTONS,'Состояние',BACK,'Ручная отправка'])
            event=Event(BUTTONS[2]);await worker.on_message(event)
            button=event.messages[0][1]['buttons'][0][0]
            self.assertTrue(button.type.data.startswith(b'delete:'))
            event=Event('/owner не-ASCII');await worker.on_message(event)
            event=Event(BUTTONS[1]);await worker.on_message(event)
            self.assertIsNone(self.q.active_batch())
            self.assertIn('Подтвердить',event.messages[0][1]['buttons'][0][0].text)
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
    def test_dtf_direction_is_enabled_and_has_copy_button(self):
        from core import DIRECTIONS
        class Event:
            is_private=True;sender_id=11;chat_id=11;photo=None;document=None
            raw_text=DIRECTIONS['dtf']['label']
            def __init__(self):self.messages=[]
            async def respond(self,text,**kw):self.messages.append((text,kw))
        worker=Worker(self.q,CONFIG,self.logs.append);event=Event()
        asyncio.run(worker.on_message(event))
        self.assertEqual(worker.direction(11),'dtf')
        keyboard=event.messages[0][1]['buttons']
        self.assertIn('Количество копий',[b.button.text for row in keyboard for b in row])

    def test_test_mode_and_configuration_generation(self):
        from services import email_for
        self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        batch=self.q.batch(bid)
        self.assertEqual(batch['test_mode'],1)
        self.assertTrue(str(email_for(CONFIG,{**batch,'link':'https://example.invalid/zip'},self.q.batch_files(bid))['Subject']).startswith('ТЕСТ'))
        self.q.transition(bid,'collecting','sent')
        self.q.set_setting('first_test_confirmed','1');self.q.set_setting('generation','7')
        self.file(mid=2);second=self.q.claim(CONFIG['recipient'],self.now)
        self.assertEqual(self.q.batch(second)['test_mode'],0)
        self.assertEqual(self.q.batch(second)['generation'],7)
    def test_changed_recipient_pauses_pending_batch(self):
        self.file();bid=self.q.claim(CONFIG['recipient'],self.now)
        worker=Worker(self.q,{**CONFIG,'recipient':'new@example.invalid'},self.logs.append)
        with patch('worker.smtp_connect') as smtp:
            asyncio.run(worker.process_batch(self.q.batch(bid)))
            smtp.assert_not_called()
        self.assertEqual(self.q.batch(bid)['state'],'collecting')
    def test_partial_settings_and_oauth_url_normalization(self):
        from app import App,FIELDS
        class Value:
            def __init__(self,v):self.v=v
            def get(self):return self.v
        app=object.__new__(App);app.c={};app.dtf_recipient=Value('');app.workshop_recipient=Value('')
        app.entries={k:Value('') for k,_,_ in FIELDS}
        app.entries['disk_token']=Value('https://oauth.yandex.ru/verification_code#access_token=fake-token&expires_in=1')
        self.assertEqual(app.config(require_all=False)['disk_token'],'fake-token')
        with self.assertRaises(UserError):app.config(require_all=True)
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
