"""Queue snapshots, expiring send confirmations and status for connected staff."""
import asyncio
import hashlib
import json
import secrets
import time
from datetime import datetime,timedelta
from core import DIRECTIONS,MOSCOW,UserError,chunks

STATUS='Состояние'

class BotFeatures:
    def __init__(self,q):
        self.q=q
        with q.lock,q.db:
            q.db.executescript('''create table if not exists send_confirmations(
              token text primary key,user integer,direction text,ids text,expires real,used integer default 0);
              create table if not exists queue_delivery(user integer,direction text,revision text,page integer default 0,primary key(user,direction));''')
    def snapshot(self,direction):
        return self.q.waiting(direction)
    def pending_ids(self,direction):
        return [r['id'] for r in self.snapshot(direction) if r['batch'] is None]
    def request(self,uid,direction):
        ids=self.pending_ids(direction)
        if not ids:return None,0
        token=secrets.token_hex(12)
        with self.q.lock,self.q.db:
            self.q.db.execute('delete from send_confirmations where expires<?',(time.time(),))
            self.q.db.execute('insert into send_confirmations(token,user,direction,ids,expires) values(?,?,?,?,?)',(token,uid,direction,json.dumps(ids),time.time()+300))
        return token,len(ids)
    def confirm(self,token,uid,recipient):
        with self.q.lock,self.q.db:
            r=self.q.db.execute('select * from send_confirmations where token=?',(token,)).fetchone()
            if not r or r['user']!=uid or r['used'] or r['expires']<time.time():
                raise UserError('Подтверждение устарело или уже использовано. Нажмите «Отправить сейчас» заново.')
            bid=self.q.claim(recipient,time.time(),manual=True,direction=r['direction'],expected=json.loads(r['ids']))
            self.q.db.execute('update send_confirmations set used=1 where token=?',(token,))
            return bid
    def status(self,direction):
        rows=self.snapshot(direction)
        lines=[DIRECTIONS[direction]['label'],f'В очереди: {len(rows)} файлов.',f'Сохранено: {sum(r["state"]=="ready" for r in rows)}.']
        with self.q.lock:
            batch=self.q.db.execute("select * from batches where direction=? and state not in ('sent','manual_sent','cancelled') order by created limit 1",(direction,)).fetchone()
        labels={'collecting':'Подготовка / ожидание повтора','packing':'Сборка архива','uploading':'Загрузка архива на Диск','ready':'Подготовка письма','submitting':'Передача письма','uncertain':'Нужно проверить получение письма','manual':'Ручная отправка — автоповторы остановлены','invalidated':'Пересборка архива'}
        if batch:
            lines.append('Заказ: '+labels.get(batch['state'],batch['state']))
            retry=float(self.q.setting('retry_at:'+batch['id'],'0'))
            if batch['state']=='collecting' and retry>time.time():lines.append('Повтор не раньше '+datetime.fromtimestamp(retry,MOSCOW).strftime('%H:%M МСК')+'.')
        if self.q.setting('automatic','0')=='1':
            now=datetime.now(MOSCOW);hour,minute=map(int,self.q.setting('dispatch_time','18:00').split(':'))
            days={int(v) for v in self.q.setting('dispatch_days','0,1,2,3,4,5,6').split(',')}
            for offset in range(8):
                slot=(now+timedelta(days=offset)).replace(hour=hour,minute=minute,second=0,microsecond=0)
                if slot>now and slot.weekday() in days:
                    lines.append('Следующая отправка: '+slot.strftime('%d.%m %H:%M МСК')+'.');break
        else:lines.append('Отправка по расписанию выключена.')
        return '\n'.join(lines)
    async def broadcast_loop(self,worker):
        while worker.running:
            try:await self.broadcast(worker.client)
            except asyncio.CancelledError:raise
            except Exception:worker.log('Обновление списка файлов ожидает восстановления связи.')
            await asyncio.sleep(2)
    async def broadcast(self,client):
        with self.q.lock:users=[r[0] for r in self.q.db.execute('select id from users')]
        for direction,value in DIRECTIONS.items():
            if not value['enabled']:continue
            rows=self.snapshot(direction)
            revision=hashlib.sha256(json.dumps([(r['id'],r['name']) for r in rows],ensure_ascii=False).encode()).hexdigest()
            pages=list(chunks(r['name'] for r in rows)) or ['Файлов, ожидающих отправки, нет.']
            for uid in users:
                with self.q.lock:
                    old=self.q.db.execute('select * from queue_delivery where user=? and direction=?',(uid,direction)).fetchone()
                start=old['page'] if old and old['revision']==revision else 0
                if start>=len(pages):continue
                for index in range(start,len(pages)):
                    # Refresh on next cycle if the queue changed while a large list was being sent.
                    if [(r['id'],r['name']) for r in self.snapshot(direction)]!=[(r['id'],r['name']) for r in rows]:break
                    title=f'Актуальная очередь — {value["label"]}\n'
                    try:await client.send_message(uid,title+pages[index],parse_mode=None)
                    except Exception:break
                    with self.q.lock,self.q.db:
                        self.q.db.execute('insert into queue_delivery values(?,?,?,?) on conflict(user,direction) do update set revision=excluded.revision,page=excluded.page',(uid,direction,revision,index+1))
