import asyncio
import hashlib
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from core import Queue,UserError
from receiver import Receiver
from services import email_for
from worker import Worker

class TestImmediate(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.q=Queue(self.root/'source');self.q.join(11,'Source')
        self.data=b'original-image-bytes';self.sha=hashlib.sha256(self.data).hexdigest()
        self.config={'recipient':'wide@example.invalid','workshop_recipient':'test@example.invalid','dtf_recipient':'dtf@example.invalid','sender':'sender@example.invalid','smtp_password':'test','disk_token':'test','bridge_token':'a'*64}
    def tearDown(self):self.q.db.close();self.tmp.cleanup()
    def file(self,mid=1,direction='workshop',name=None):
        r=self.q.add(11,mid,11,name or f'print-{mid}.tif',len(self.data),time.time(),direction=direction)
        path=self.q.path(r);path.parent.mkdir(parents=True);path.write_bytes(self.data);self.q.downloaded(r['id'],self.sha);return self.q.file(r['id'])
    def test_workshop_claims_one_ready_file_immediately_without_archive(self):
        self.file();self.file(mid=2)
        bid=self.q.claim_immediate(self.config['workshop_recipient'],time.time(),'workshop')
        rows=self.q.batch_files(bid);self.assertEqual(len(rows),1)
        worker=Worker(self.q,self.config,lambda m:None)
        uploaded=[]
        class Disk:
            def __init__(self,t):pass
            def upload(inner,path,remote):uploaded.append((Path(path).read_bytes(),remote));return 'https://disk.yandex.ru/d/test'
            def remove_generated(inner,path):pass
        smtp=SimpleNamespace(send_message=lambda msg:None,close=lambda:None)
        with patch('worker.Disk',Disk),patch('worker.smtp_connect',return_value=smtp):asyncio.run(worker.process_batch(self.q.batch(bid)))
        self.assertEqual(uploaded[0][0],self.data);self.assertTrue(uploaded[0][1].endswith('/print-1.tif'))
        self.assertEqual(self.q.batch(bid)['state'],'sent')
        msg=email_for(self.config,{**self.q.batch(bid),'link':'https://disk.yandex.ru/d/test'},rows)
        self.assertIn('Мастерская',msg['Subject']);self.assertNotIn('Полароид.zip',msg.get_content());self.assertEqual(list(msg.iter_attachments()),[])
        self.assertIsNotNone(self.q.claim_immediate(self.config['workshop_recipient'],time.time(),'workshop'))
    def test_local_registration_is_idempotent_and_no_smtp_or_premature_success(self):
        row=self.file(direction='photo30');bid=self.q.claim_immediate('local:30x40',time.time(),'photo30')
        worker=Worker(self.q,self.config,lambda m:None);calls=[]
        class Disk:
            def __init__(self,t):pass
            def upload(self,path,remote):return 'https://disk.yandex.ru/d/test'
        class Client:
            attempts=0
            def __init__(self,t):pass
            def request(self,action,payload):
                calls.append(payload);Client.attempts+=1
                if Client.attempts==1:raise ConnectionError('lost response')
                return {'downloaded':False}
        with patch('local_delivery.Disk',Disk),patch('local_delivery.BridgeClient',Client),patch('worker.smtp_connect') as smtp:
            asyncio.run(worker.process_batch(self.q.batch(bid)))
            self.assertEqual(self.q.batch(bid)['state'],'dispatching_local')
            with self.assertRaises(UserError):self.q.cancel(row['id'])
            self.q.set_setting('retry_at:'+bid,'0');asyncio.run(worker.process_batch(self.q.batch(bid)))
            smtp.assert_not_called()
        self.assertEqual(calls[0]['id'],calls[1]['id'])
        self.assertEqual(self.q.batch(bid)['state'],'awaiting_download')
        self.assertEqual(len(self.q.waiting('photo30')),1)
        self.assertFalse(any(b['state']=='local_saved' for b in self.q.pending_notifications()))
    def job(self,name='ready.tif'):
        return {'id':str(uuid.uuid4()),'filename':name,'size':len(self.data),'sha256':self.sha,'url':'https://disk.yandex.ru/d/test'}
    def receiver(self,client=None,download=None):
        if client is None:client=SimpleNamespace(request=lambda action,payload: {'downloaded':True})
        if download is None:download=lambda url,path,size,sha,stopped:Path(path).write_bytes(self.data)
        return Receiver(self.root,self.root/'Desktop'/'30х40',client,download)
    def test_receiver_writes_original_and_acknowledges_only_after_save(self):
        calls=[];receiver=None
        def ack(action,payload):
            self.assertTrue((receiver.root/payload['relative_path']).exists());calls.append(payload)
        receiver=self.receiver(SimpleNamespace(request=ack));job=self.job()
        try:
            relative=receiver.receive(job)
            self.assertEqual((receiver.root/relative).read_bytes(),self.data);self.assertEqual(len(calls),1)
        finally:receiver.db.close()
    def test_receiver_does_not_overwrite_previous_file_with_same_name(self):
        receiver=self.receiver();receiver.root.joinpath('ready.tif').write_bytes(b'old-print')
        try:
            relative=receiver.receive(self.job());self.assertIn('Заказ-',relative)
            self.assertEqual(receiver.root.joinpath('ready.tif').read_bytes(),b'old-print')
            self.assertEqual((receiver.root/relative).read_bytes(),self.data)
        finally:receiver.db.close()
    def test_corrupt_or_partial_download_does_not_report_success(self):
        calls=[];receiver=self.receiver(SimpleNamespace(request=lambda *args:calls.append(args)),lambda url,path,*args:Path(path).write_bytes(b'corrupt'))
        try:
            with self.assertRaises(UserError):receiver.receive(self.job())
            self.assertEqual(calls,[]);self.assertEqual(list(receiver.root.glob('*.tif')),[])
        finally:receiver.db.close()
    def test_lost_ack_is_retried_without_redownload(self):
        downloads=[];calls=[]
        def download(url,path,*args):downloads.append(url);Path(path).write_bytes(self.data)
        def ack(action,payload):
            calls.append(payload)
            if len(calls)==1:raise ConnectionError('offline')
        receiver=self.receiver(SimpleNamespace(request=ack),download);job=self.job()
        try:
            with self.assertRaises(ConnectionError):receiver.receive(job)
            receiver.retry_acks();self.assertEqual(len(downloads),1);self.assertEqual(len(calls),2)
            self.assertEqual(receiver.db.execute('select state from receipts').fetchone()[0],'reported')
        finally:receiver.db.close()
    def test_restart_after_atomic_rename_recovers_same_job(self):
        receiver=self.receiver();job=self.job();target=receiver.root/job['filename'];target.write_bytes(self.data)
        with receiver.db:receiver.db.execute('insert into receipts values(?,?,?,?,?)',(job['id'],str(target),job['sha256'],job['size'],'new'))
        def must_not_download(*args):raise AssertionError('unexpected download')
        receiver.download=must_not_download
        try:self.assertEqual(receiver.receive(job),job['filename'])
        finally:receiver.db.close()

if __name__=='__main__':unittest.main()
