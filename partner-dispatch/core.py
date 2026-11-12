"""Durable print queue. No cloud credentials and no network in this module."""
from __future__ import annotations
import csv
import hashlib
import io
import os
import re
import shutil
import sqlite3
import threading
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

MOSCOW = timezone(timedelta(hours=3))
MAX_BYTES = 500 * 1024 * 1024
BUTTONS = ('Просмотр файлов', 'Отправить сейчас', 'Удалить файл')
DIRECTIONS = {
    'wideformat': {'label': 'Широкоформатная печать', 'enabled': True},
    'dtf': {'label': 'ДТФ-печать', 'enabled': False},
}
UPLOAD = 'Загрузить файл'
BACK = 'Назад'

class UserError(Exception):
    pass


def safe_name(name: str) -> str:
    # Paths supplied by Telegram must never escape the local inbox or ZIP.
    name = re.split(r'[/\\]', str(name))[-1]
    name = re.sub(r'[\x00-\x1f<>:"|?*]', '_', name).strip(' .')[:180]
    if not name:
        raise UserError('У файла нет названия.')
    if name.split('.')[0].upper() in {'CON','PRN','AUX','NUL',*(f'COM{i}' for i in range(1,10)),*(f'LPT{i}' for i in range(1,10))}:
        name = '_' + name
    return name


def due_day(timestamp: float) -> str:
    dt = datetime.fromtimestamp(timestamp, MOSCOW)
    return (dt.date() + timedelta(days=int(dt.hour >= 18))).isoformat()


def chunks(lines, limit=3500):
    page = ''
    for line in lines:
        line = str(line)[:500]
        if page and len(page) + len(line) + 1 > limit:
            yield page
            page = ''
        page += line + '\n'
    if page:
        yield page.rstrip()


class Queue:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root/'files').mkdir(exist_ok=True)
        (self.root/'archives').mkdir(exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.root/'queue.sqlite3', check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute('pragma journal_mode=WAL')
        self.db.execute('pragma foreign_keys=ON')
        self.db.executescript('''
        create table if not exists users(id integer primary key, branch text not null);
        create table if not exists settings(key text primary key,value text not null);
        create table if not exists batches(
          id text primary key,state text not null,created real not null,
          recipient text not null,link text,remote_path text,error text,notified integer not null default 0);
        create table if not exists files(
          id integer primary key,chat integer not null,message integer not null,sender integer not null,
          branch text not null,name text not null,size integer not null,received real not null,
          due text not null,state text not null default 'queued',attempts integer not null default 0,
          next_try real not null default 0,error text,sha256 text,ack integer not null default 0,
          batch text references batches(id),unique(chat,message));
        create table if not exists notices(batch text not null references batches(id),chat integer not null,done integer not null default 0,primary key(batch,chat));
        create index if not exists files_batch on files(batch);
        create index if not exists files_waiting on files(state,due);
        ''')
        # Keep old local queues compatible when upgrading the desktop program.
        for table in ('files','batches'):
            if 'direction' not in {r[1] for r in self.db.execute('pragma table_info('+table+')')}:
                self.db.execute("alter table "+table+" add column direction text not null default 'wideformat'")
        if 'test_mode' not in {r[1] for r in self.db.execute('pragma table_info(batches)')}:
            self.db.execute('alter table batches add column test_mode integer not null default 1')
        if 'generation' not in {r[1] for r in self.db.execute('pragma table_info(batches)')}:
            self.db.execute('alter table batches add column generation integer not null default 0')
        self.db.execute('create index if not exists files_direction_waiting on files(direction,state,due)')
        # We never automatically resend after an ambiguous SMTP result or crash.
        self.db.execute("update batches set state='uncertain',error='Программа закрылась во время передачи письма. Требуется проверить почту.' where state='submitting'")
        self.db.execute("update files set state='queued' where state='downloading'")
        self.db.execute("update batches set state='collecting' where state in ('packing','uploading','ready')")
        self.db.commit()

    def setting(self, key, default=''):
        with self.lock:
            r=self.db.execute('select value from settings where key=?',(key,)).fetchone()
            return r[0] if r else default

    def set_setting(self,key,value):
        with self.lock,self.db:
            self.db.execute('insert into settings values(?,?) on conflict(key) do update set value=excluded.value',(key,str(value)))

    def join(self, user, branch):
        branch = str(branch).strip()[:80]
        if not branch: raise UserError('После кода укажите название филиала.')
        with self.lock,self.db:
            self.db.execute('insert into users values(?,?) on conflict(id) do update set branch=excluded.branch',(user,branch))

    def user(self,user):
        with self.lock:
            r=self.db.execute('select branch from users where id=?',(user,)).fetchone()
            return r[0] if r else None

    def add(self,chat,message,sender,name,size,received,direction='wideformat'):
        if direction not in DIRECTIONS:raise UserError('Неизвестное направление.')
        branch=self.user(sender)
        if branch is None: raise UserError('Сначала подключитесь с кодом филиала.')
        name=safe_name(name)
        if Path(name).suffix.lower() not in {'.tif','.tiff','.pdf','.jpg','.jpeg','.png'}:
            raise UserError('Принимаются TIF, TIFF, PDF, JPG и PNG. Отправляйте макеты документом, без сжатия.')
        if not 0<size<=MAX_BYTES: raise UserError('Размер файла должен быть от 1 байта до 500 МБ.')
        with self.lock,self.db:
            self.db.execute('insert or ignore into files(chat,message,sender,branch,name,size,received,due,direction) values(?,?,?,?,?,?,?,?,?)',
                (chat,message,sender,branch,name,size,received,due_day(received),direction))
            return dict(self.db.execute('select * from files where chat=? and message=?',(chat,message)).fetchone())

    def file(self,id):
        with self.lock:
            r=self.db.execute('select * from files where id=?',(id,)).fetchone()
            return dict(r) if r else None

    def path(self,row):
        return self.root/'files'/str(row['id'])/row['name']

    def waiting(self,direction='wideformat'):
        with self.lock:
            return [dict(x) for x in self.db.execute("select f.* from files f left join batches b on b.id=f.batch where f.state!='cancelled' and (f.batch is null or b.state not in ('sent','submitting','uncertain')) and f.direction=? order by f.received,f.id",(direction,))]

    def download_candidate(self,now):
        with self.lock,self.db:
            r=self.db.execute("select * from files where state in ('queued','failed') and attempts<5 and next_try<=? order by received,id limit 1",(now,)).fetchone()
            if not r:return None
            self.db.execute("update files set state='downloading',attempts=attempts+1 where id=?",(r['id'],))
            return dict(r)

    def downloaded(self,id,sha):
        with self.lock,self.db:
            self.db.execute("update files set state='ready',sha256=?,error=null where id=? and state!='cancelled'",(sha,id))

    def download_failed(self,id,now,message):
        with self.lock,self.db:
            self.db.execute("update files set state='failed',error=?,next_try=? where id=? and state!='cancelled'",(message,now+120,id))

    def cancel(self,id,direction=None):
        with self.lock,self.db:
            r=self.db.execute('select f.*,b.state batch_state from files f left join batches b on b.id=f.batch where f.id=?',(id,)).fetchone()
            if not r or r['state']=='cancelled':raise UserError('Этот файл уже удалён или не найден.')
            if direction is not None and r['direction']!=direction:raise UserError('Этот файл относится к другому направлению. Откройте нужный раздел.')
            if r['batch_state'] in ('sent','submitting','uncertain'):
                raise UserError('Письмо уже передано на отправку. Удалить файл из него нельзя. При неопределённом результате сначала проверьте почту.')
            self.db.execute("update files set state='cancelled' where id=?",(id,))
            if r['batch']:
                self.db.execute("update batches set state='invalidated' where id=?",(r['batch'],))
            return dict(r)

    def claim(self,recipient,now,manual=False,direction='wideformat'):
        with self.lock,self.db:
            existing=self.db.execute("select * from batches where state in ('collecting','packing','uploading','ready','invalidated','submitting','uncertain') and direction=? order by created limit 1",(direction,)).fetchone()
            if existing:
                if manual:raise UserError('Предыдущая отправка ещё не завершена. Проверьте её состояние на основном компьютере.')
                return None
            dt=datetime.fromtimestamp(now,MOSCOW)
            if not manual and dt.hour<18:return None
            query="select id from files where state!='cancelled' and batch is null and direction=?"
            args=[direction]
            if not manual:
                query+=' and due<=?';args.append(dt.date().isoformat())
            ids=[r[0] for r in self.db.execute(query,args)]
            if not ids:return None
            bid=uuid.uuid4().hex
            self.db.execute("insert into batches(id,state,created,recipient,direction,test_mode,generation) values(?,'collecting',?,?,?,?,?)",(bid,now,recipient,direction,int(self.setting('first_test_confirmed','0')!='1'),int(self.setting('generation','0'))))
            self.db.executemany('update files set batch=? where id=?',[(bid,i) for i in ids])
            return bid

    def active_batch(self,direction='wideformat'):
        with self.lock:
            r=self.db.execute("select * from batches where state in ('collecting','packing','uploading','ready','invalidated') and direction=? order by created limit 1",(direction,)).fetchone()
            return dict(r) if r else None

    def batch(self,id):
        with self.lock:
            r=self.db.execute('select * from batches where id=?',(id,)).fetchone()
            return dict(r) if r else None

    def batch_files(self,id):
        with self.lock:
            return [dict(r) for r in self.db.execute("select * from files where batch=? and state!='cancelled' order by received,id",(id,))]

    def transition(self,id,old,new,**fields):
        if set(fields)-{'link','remote_path','error','notified'}:raise ValueError('Unknown field')
        sets=['state=?']+[k+'=?' for k in fields]
        with self.lock,self.db:
            return self.db.execute('update batches set '+','.join(sets)+' where id=? and state=?',[new,*fields.values(),id,old]).rowcount==1

    def accept_smtp(self,id):
        with self.lock,self.db:
            r=self.db.execute('select state from batches where id=?',(id,)).fetchone()
            if not r or r[0]!='ready':return False
            self.db.execute("update batches set state='submitting' where id=?",(id,))
            return True

    def pending_notifications(self):
        with self.lock:
            return [dict(r) for r in self.db.execute("select * from batches where state in ('sent','uncertain') and notified=0")]

    def notice_done(self,batch,chat):
        with self.lock:
            r=self.db.execute('select done from notices where batch=? and chat=?',(batch,chat)).fetchone()
            return bool(r and r[0])

    def finish_notice(self,batch,chat):
        with self.lock,self.db:
            self.db.execute('insert into notices values(?,?,1) on conflict(batch,chat) do update set done=1',(batch,chat))

    def mark_notified(self,id):
        with self.lock,self.db:self.db.execute('update batches set notified=1 where id=?',(id,))

    def reset_uncertain(self,id,confirmed_received):
        with self.lock,self.db:
            r=self.db.execute('select state from batches where id=?',(id,)).fetchone()
            if not r or r[0]!='uncertain':raise UserError('Неопределённой отправки нет.')
            self.db.execute("update batches set state=?,notified=0 where id=?",('sent' if confirmed_received else 'collecting',id))


def build_archive(queue:Queue,batchid:str):
    rows=queue.batch_files(batchid)
    if not rows or any(r['state']!='ready' for r in rows):raise UserError('Не все файлы получены. Дождитесь загрузки или удалите ошибочный файл.')
    required=sum(r['size'] for r in rows)+1024**3
    if shutil.disk_usage(queue.root).free<required:raise UserError('На основном компьютере недостаточно места для ZIP.')
    dest=queue.root/'archives'/(batchid+'.zip')
    temp=dest.with_suffix('.part')
    manifest=io.StringIO(newline='')
    writer=csv.writer(manifest,delimiter=';');writer.writerow(['Филиал','Файл','Путь в архиве','SHA256'])
    try:
        with zipfile.ZipFile(temp,'w',compression=zipfile.ZIP_STORED,allowZip64=True) as archive:
            for index,r in enumerate(rows,1):
                if queue.batch(batchid)['state']!='packing':raise UserError('Состав отправки изменён: архив будет пересобран.')
                source=queue.path(r)
                if source.stat().st_size!=r['size']:raise UserError('Размер сохранённого файла изменился. Отправка остановлена.')
                with source.open('rb') as f:
                    digest=hashlib.file_digest(f,'sha256').hexdigest()
                if digest!=r['sha256']:raise UserError('Контрольная сумма файла не совпадает. Отправка остановлена.')
                arc=f'{safe_name(r["branch"])}/{index:04d}/{r["name"]}'
                archive.write(source,arc)
                writer.writerow([("'"+str(v)) if str(v).startswith(('=','+','-','@')) else v for v in [r['branch'],r['name'],arc,digest]])
            archive.writestr('Состав заказа.csv',manifest.getvalue().encode('utf-8-sig'))
        os.replace(temp,dest)
        return dest
    finally:
        temp.unlink(missing_ok=True)
