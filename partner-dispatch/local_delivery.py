"""Durable handoff from the one Telegram handler to the remote 30x40 receiver."""
import asyncio
import hashlib
import time
import uuid
from bridge_client import BridgeClient
from services import Disk
from core import UserError

class LocalDelivery:
    def __init__(self,worker):self.worker=worker;self.q=worker.q
    async def process(self,b):
        bid=b['id'];w=self.worker
        if float(self.q.setting('retry_at:'+bid,'0'))>time.time():return
        if not w.c.get('bridge_token'):return
        if b['state']=='invalidated':self.q.transition(bid,'invalidated','collecting');return
        rows=self.q.batch_files(bid)
        if not rows:self.q.transition(bid,b['state'],'cancelled');return
        row=rows[0]
        if row['state']!='ready':return
        try:
            client=BridgeClient(w.c['bridge_token'])
            if not b.get('link'):
                if not self.q.transition(bid,'collecting','packing'):return
                path=self.q.path(row)
                def verify():
                    with path.open('rb') as file:
                        if path.stat().st_size!=row['size'] or hashlib.file_digest(file,'sha256').hexdigest()!=row['sha256']:raise UserError('Исходник 30×40 изменился.')
                await asyncio.to_thread(verify)
                remote=f'disk:/Cloudshop-Print/{bid}_{uuid.uuid4().hex}/{row["name"]}'
                if not self.q.transition(bid,'packing','uploading',remote_path=remote):return
                link=await asyncio.to_thread(Disk(w.c['disk_token']).upload,path,remote)
                if not self.q.transition(bid,'uploading','ready',link=link):
                    await asyncio.to_thread(Disk(w.c['disk_token']).remove_generated,remote);return
                b=self.q.batch(bid)
            elif b['state']=='collecting':
                if not self.q.transition(bid,'collecting','ready'):return
                b=self.q.batch(bid)
            if b['state']=='ready':
                if not self.q.transition(bid,'ready','dispatching_local'):return
            elif b['state']!='dispatching_local':return
            result=await asyncio.to_thread(client.request,'enqueue',{'id':str(uuid.UUID(bid)),'filename':row['name'],'size':row['size'],'sha256':row['sha256'],'url':b['link'],'source_branch':row['branch']})
            self.q.transition(bid,'dispatching_local','local_saved' if result.get('downloaded') else 'awaiting_download',error=None,notified=0)
            w.log('30×40: файл передан в очередь приёмника. Подтверждение будет после сохранения на его компьютере.')
        except Exception as e:
            current=self.q.batch(bid)['state'];reason=str(e) if isinstance(e,(UserError,ConnectionError)) else 'Не удалось передать файл 30×40.'
            if current in ('packing','uploading','ready'):self.q.transition(bid,current,'collecting',error=reason)
            self.q.set_setting('retry_at:'+bid,time.time()+600);w.log(reason+' Повтор через 10 минут.')
            w.monitor.failure(bid,reason)
    async def status_loop(self):
        w=self.worker
        while w.running:
            try:
                if w.c.get('bridge_token'):
                    with self.q.lock:ids=[r[0] for r in self.q.db.execute("select id from batches where direction='photo30' and state='awaiting_download' order by created limit 100")]
                    if ids:
                        result=await asyncio.to_thread(BridgeClient(w.c['bridge_token']).request,'status',{'ids':[str(uuid.UUID(id)) for id in ids]})
                        for item in result:
                            if item.get('downloaded'):self.q.transition(uuid.UUID(item['id']).hex,'awaiting_download','local_saved',notified=0)
            except asyncio.CancelledError:raise
            except Exception:pass # Receiver acknowledgement remains durable on the cloud side.
            await asyncio.sleep(15)
