"""Queue snapshots, expiring send confirmations and status for connected staff."""
import asyncio
import hashlib
import json
import math
import secrets
import time
from datetime import datetime,timedelta
from core import DIRECTIONS,MOSCOW,UserError,chunks

STATUS='Состояние'
NEXT='Ближайшая отправка'
UNDO='Отменить последнюю загрузку'

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
        if self.busy(direction):raise UserError('Текущий заказ уже обрабатывается.\n'+self.status(direction))
        rows=[r for r in self.snapshot(direction) if r['batch'] is None]
        ids=[[r['id'],r['copies']] for r in rows]
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
            if self.busy(r['direction']):raise UserError('Текущий заказ уже обрабатывается.\n'+self.status(r['direction']))
            bid=self.q.claim(recipient,time.time(),manual=True,direction=r['direction'],expected=json.loads(r['ids']))
            self.q.db.execute('update send_confirmations set used=1 where token=?',(token,))
            return bid
    def status(self,direction):
        rows=self.snapshot(direction)
        lines=[DIRECTIONS[direction]['label']+' · программа '+self.q.setting('runtime_version','неизвестна'),f'В очереди: {len(rows)} файлов.',f'Сохранено: {sum(r["state"]=="ready" for r in rows)}.']
        if direction=='dtf':lines.append(f'Всего копий: {sum(r["copies"] for r in rows)}.')
        with self.q.lock:
            batch=self.q.db.execute("select * from batches where direction=? and state not in ('sent','manual_sent','cancelled') order by created limit 1",(direction,)).fetchone()
        labels={'review':'Предпросмотр ДТФ · ожидание автоотправки через 5 минут','editing':'Исправление ДТФ · автоматическая отправка на паузе','collecting':'Подготовка / ожидание повтора','packing':'Сборка архива','uploading':'Загрузка архива на Диск','ready':'Подготовка письма','submitting':'Передача письма','uncertain':'Нужно проверить получение письма','dispatching_local':'Передача задания приёмнику','awaiting_download':'Ожидает сохранения на компьютере 30×40','manual':'Ручная отправка — автоповторы остановлены','invalidated':'Пересборка архива'}
        if batch:
            lines.append('Заказ: '+labels.get(batch['state'],batch['state']))
            retry=float(self.q.setting('retry_at:'+batch['id'],'0'))
            if batch['state']=='collecting' and retry>time.time():lines.append('Повтор не раньше '+datetime.fromtimestamp(retry,MOSCOW).strftime('%H:%M МСК')+'.')
        if direction in ('workshop','photo30','masterphoto'):
            if direction=='photo30' and self.q.setting('bridge_connected','0')!='1':lines.append('Основная программа ещё не подключена к приёмнику в Клаудшопе.')
            lines.append('Отправка: автоматически после сохранения, без расписания.')
            return '\n'.join(lines)
        slot=self.next_slot(direction)
        if slot:
            weekday=('понедельник','вторник','среда','четверг','пятница','суббота','воскресенье')[slot.weekday()]
            lines.append('Ближайшая отправка: '+slot.strftime('%d.%m.%Y %H:%M МСК')+' · '+weekday+'.')
        else:lines.append('Отправка по расписанию выключена.')
        return '\n'.join(lines)
    def busy(self,direction):
        with self.q.lock:
            return self.q.db.execute("select 1 from batches where direction=? and state not in ('sent','manual_sent','cancelled','local_saved') limit 1",(direction,)).fetchone() is not None
    def file_lines(self,direction):
        labels={'queued':'получаем','failed':'ожидает загрузки','ready':'сохранён'}
        for row in self.snapshot(direction):
            copies=f' · {row["copies"]} коп.' if direction=='dtf' else ''
            state='в отправке' if row['batch'] else labels.get(row['state'],row['state'])
            yield f'#{row["id"]} {row["name"]}\n{row["branch"]}{copies} · {state}'
    def last_upload(self,uid,direction):
        rows=[r for r in self.snapshot(direction) if r['sender']==uid and r['batch'] is None]
        return max(rows,key=lambda r:(r['received'],r['id']),default=None)
    def undo(self,uid,direction,number):
        with self.q.lock:
            row=self.q.file(number)
            if not row or row['sender']!=uid or row['direction']!=direction or row['batch'] is not None:
                raise UserError('Можно отменить только свою загрузку до начала отправки.')
            return self.q.cancel(number,direction=direction)
    def next_slot(self,direction,now=None):
        if direction not in ('wideformat','dtf'):return None
        prefix='dtf_' if direction=='dtf' else ''
        if self.q.setting(prefix+'automatic','0')!='1':return None
        now=now or datetime.now(MOSCOW)
        hour,minute=map(int,self.q.setting(prefix+'dispatch_time','12:00' if prefix else '18:00').split(':'))
        days={int(v) for v in self.q.setting(prefix+'dispatch_days','0,3' if prefix else '0,1,2,3,4,5,6').split(',') if v}
        for offset in range(8):
            slot=(now+timedelta(days=offset)).replace(hour=hour,minute=minute,second=0,microsecond=0)
            if slot>now and slot.weekday() in days:return slot
    async def broadcast_loop(self,worker):
        # No queue broadcasts on upload/delete/send. Only due schedule reminders.
        while worker.running:
            try:await self.remind(worker.client,worker.recipient)
            except asyncio.CancelledError:raise
            except Exception:worker.log('Напоминание о ближайшей отправке ожидает восстановления связи.')
            await asyncio.sleep(10)
    async def broadcast(self,client):
        # Compatibility for old callers: queue changes no longer send messages.
        return
    async def remind(self,client,recipient,now=None):
        now=now or datetime.now(MOSCOW)
        with self.q.lock,self.q.db:
            self.q.db.execute('create table if not exists schedule_notices(user integer,direction text,due text,primary key(user,direction,due))')
            users=[r[0] for r in self.q.db.execute('select id from users')]
        for direction in ('wideformat','dtf'):
            slot=self.next_slot(direction,now)
            if not slot or not recipient(direction) or not 0<(slot-now).total_seconds()<=1800:continue
            minutes=max(1,math.ceil((slot-now).total_seconds()/60))
            label='ДТФ-печать' if direction=='dtf' else 'Широкоформатная печать'
            text=f'⏰ Через {minutes} минут произойдёт автоматическая отправка файлов на перезаказ — {label}. Если есть файлы для печати, загрузите их сейчас.'
            due=slot.isoformat()
            for uid in users:
                with self.q.lock:
                    delivered=self.q.db.execute('select 1 from schedule_notices where user=? and direction=? and due=?',(uid,direction,due)).fetchone()
                if delivered:continue
                try:await client.send_message(uid,text,parse_mode=None)
                except asyncio.CancelledError:raise
                except Exception as error:
                    if type(error).__name__ not in ('UserIsBlockedError','ChatWriteForbiddenError','PeerIdInvalidError'):continue
                with self.q.lock,self.q.db:
                    self.q.db.execute('insert or ignore into schedule_notices values(?,?,?)',(uid,direction,due))
