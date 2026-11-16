"""Persist operator alerts; ordinary branch names never grant alert access."""
import asyncio
import time
from services import Disk

class Monitoring:
    def __init__(self,queue):
        self.q=queue
        with queue.lock,queue.db:
            queue.db.executescript('''
            create table if not exists operator_alerts(id text primary key,body text not null,batch text);
            create table if not exists operator_alert_delivery(alert text,chat integer,primary key(alert,chat));
            ''')
    def targets(self):
        owner=self.q.setting('owner')
        targets={int(owner)} if owner else set()
        branch=self.q.setting('alert_branch')
        if branch:
            with self.q.lock:
                for r in self.q.db.execute("select id from users"):
                    if self.q.setting('alert_role:'+str(r[0]))==branch:targets.add(r[0])
        return targets
    def add(self,key,body,batch=None):
        with self.q.lock,self.q.db:
            self.q.db.execute('insert or ignore into operator_alerts values(?,?,?)',(key,body,batch))
    def failure(self,bid,reason):
        self.add('failure:'+bid,'Не удалось отправить заказ '+bid[:8]+'.\n'+reason+'\nФайлы сохранены. Повтор каждые 10 минут, пока программа работает. При полном отсутствии интернета уведомление придёт после восстановления связи.',bid)
    async def check_space(self,config):
        now=time.time()
        if now<float(self.q.setting('space_check_after','0')):return
        self.q.set_setting('space_check_after',now+3600)
        try:free=await asyncio.to_thread(Disk(config['disk_token']).check)
        except Exception:return
        self.q.set_setting('disk_free_bytes',free)
        threshold=float(self.q.setting('space_threshold_gb','10'))*1024**3
        if free<threshold:
            episode=self.q.setting('low_space_episode')
            if not episode:
                episode=str(int(now));self.q.set_setting('low_space_episode',episode)
            self.add('space:'+episode,f'На Яндекс Диске осталось {free/1024**3:.1f} ГБ. Порог предупреждения: {threshold/1024**3:g} ГБ. Освободите место или проверьте подключённый аккаунт. Файлы автоматически не удаляются.')
        else:self.q.set_setting('low_space_episode','')
    async def notify(self,client):
        with self.q.lock:
            alerts=[dict(r) for r in self.q.db.execute('select * from operator_alerts')]
        for a in alerts:
            if a['batch']:
                batch=self.q.batch(a['batch'])
                if not batch or batch['state'] in ('sent','cancelled','uncertain'):continue
            elif not self.q.setting('low_space_episode') or a['id']!='space:'+self.q.setting('low_space_episode'):continue
            for chat in self.targets():
                with self.q.lock:
                    if self.q.db.execute('select 1 from operator_alert_delivery where alert=? and chat=?',(a['id'],chat)).fetchone():continue
                try:await client.send_message(chat,a['body'],parse_mode=None)
                except Exception:continue
                with self.q.lock,self.q.db:
                    self.q.db.execute('insert or ignore into operator_alert_delivery values(?,?)',(a['id'],chat))
