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
    async def check_delays(self):
        now=time.time()
        download_minutes=float(self.q.setting('download_delay_minutes','15'))
        send_minutes=float(self.q.setting('send_delay_minutes','30'))
        with self.q.lock:
            files=[dict(r) for r in self.q.db.execute("select f.* from files f left join batches b on b.id=f.batch where f.state in ('queued','downloading','failed') and (f.batch is null or b.state not in ('sent','local_saved','manual_sent','cancelled'))")]
            batches=[dict(r) for r in self.q.db.execute("select * from batches where state in ('collecting','packing','uploading','ready','invalidated')")]
        for r in files:
            if now-r['received']>=download_minutes*60 or r['attempts']>=5:
                self.add('file:'+str(r['id']),f'Файл «{r["name"]}» долго не сохраняется. Проверьте связь с Telegram и свободное место на компьютере. Если исходник недоступен, попросите филиал загрузить его заново.',None)
        for b in batches:
            if now-b['created']>=send_minutes*60:
                self.add('delay:'+b['id'],f'Заказ {b["id"][:8]} не отправлен более {send_minutes:g} минут после начала подготовки. Проверьте состояние. Проверьте соединение и настройки программы; файлы сохранены.',b['id'])

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
                if not batch or batch['state'] in ('sent','local_saved','manual_sent','manual','cancelled','uncertain'):continue
            elif a['id'].startswith('file:'):
                row=self.q.file(int(a['id'].split(':')[1]))
                if not row or row['state'] in ('ready','cancelled'):continue
            elif not self.q.setting('low_space_episode') or a['id']!='space:'+self.q.setting('low_space_episode'):continue
            for chat in self.targets():
                with self.q.lock:
                    if self.q.db.execute('select 1 from operator_alert_delivery where alert=? and chat=?',(a['id'],chat)).fetchone():continue
                buttons=None
                if a['batch'] and batch['state']=='collecting' and batch['direction']!='photo30':
                    from handoff import Handoff
                    buttons=[[Handoff.button('Взять отправку вручную','take',batch)]]
                try:await client.send_message(chat,a['body'],parse_mode=None,buttons=buttons)
                except Exception:continue
                with self.q.lock,self.q.db:
                    self.q.db.execute('insert or ignore into operator_alert_delivery values(?,?)',(a['id'],chat))
