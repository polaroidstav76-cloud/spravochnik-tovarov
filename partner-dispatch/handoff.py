"""Durable handoff to a designated branch. Never automatically sends email."""
from __future__ import annotations
import asyncio
import time
from core import UserError
from services import Disk

MANUAL_MENU='Ручная отправка'

def normalize(value):return ''.join(str(value).casefold().split())

class Handoff:
    def __init__(self,q):
        self.q=q;self.next_revoke={}
        with q.lock,q.db:
            q.db.executescript('''
            create table if not exists handoff_notices(
              batch text not null,event text not null,chat integer not null,primary key(batch,event,chat));
            create table if not exists handoff_files(
              id integer primary key,batch text not null,user integer not null,file integer not null,
              revision integer not null,state text not null default 'queued',message integer,
              unique(batch,user,file,revision));
            ''')
            # An interrupted Telegram send may already have delivered the document.
            q.db.execute("update handoff_files set state='uncertain' where state='sending'")

    def authorized(self,uid):
        if self.q.setting('owner')==str(uid):return True
        chosen=self.q.setting('alert_branch')
        return bool(chosen and normalize(self.q.setting('alert_role:'+str(uid)))==normalize(chosen))

    def targets(self):
        with self.q.lock:users=[r[0] for r in self.q.db.execute('select id from users')]
        owner=self.q.setting('owner')
        return {u for u in users if self.authorized(u)}|({int(owner)} if owner else set())

    def pause(self,bid,expected,reason):
        with self.q.lock,self.q.db:
            return self.q.db.execute("update batches set state='manual',error=?,manual_by=null,notified=0 where id=? and state=?",(reason,bid,expected)).rowcount==1

    def list(self):
        with self.q.lock:
            return [dict(r) for r in self.q.db.execute("select * from batches where direction<>'photo30' and state in ('manual','uncertain','collecting') order by created")]

    def check(self,bid,uid,revision,states=('manual',)):
        if not self.authorized(uid):raise UserError('Эта отправка доступна владельцу и сотрудникам ответственного филиала.')
        b=self.q.batch(bid)
        if b and b['direction']=='photo30':raise UserError('30×40 передаётся приёмнику. Проверьте его подключение на компьютере с принтером.')
        if not b or b['state'] not in states:raise UserError('Отправка уже завершена или её состояние изменилось. Откройте ручные отправки заново.')
        if b['manual_revision']!=revision:raise UserError('Состав заказа изменился. Откройте ручную отправку заново; старую ссылку не используйте.')
        return b

    def take(self,bid,uid,revision):
        with self.q.lock,self.q.db:
            b=self.check(bid,uid,revision,('manual','collecting'))
            if b['state']=='collecting':
                self.q.db.execute("update batches set state='manual',notified=0 where id=? and state='collecting'",(bid,))
            if b['manual_by'] not in (None,uid):raise UserError('Эту отправку уже взял другой сотрудник. Не отправляйте повторно.')
            self.q.db.execute('update batches set manual_by=? where id=?',(uid,bid))
        return self.q.batch(bid)

    def finish(self,bid,uid,revision):
        with self.q.lock,self.q.db:
            b=self.check(bid,uid,revision)
            if b['manual_by']!=uid:raise UserError('Сначала возьмите отправку в работу.')
            self.q.db.execute("update batches set state='manual_sent',notified=0 where id=?",(bid,))

    def request_files(self,bid,uid,revision,retry=False):
        with self.q.lock,self.q.db:
            b=self.check(bid,uid,revision)
            if b['manual_by']!=uid:raise UserError('Сначала возьмите отправку в работу.')
            rows=self.q.batch_files(bid)
            for r in rows:
                self.q.db.execute('insert or ignore into handoff_files(batch,user,file,revision) values(?,?,?,?)',(bid,uid,r['id'],revision))
            if retry:self.q.db.execute("update handoff_files set state='queued' where batch=? and user=? and revision=? and state in ('error','uncertain')",(bid,uid,revision))
            return len(rows)

    @staticmethod
    def button(title,action,b):
        from telethon import Button
        return Button.inline(title,f'h:{action}:{b["id"]}:{b["manual_revision"]}'.encode())

    def alert(self,b):
        from core import DIRECTIONS
        name=DIRECTIONS[b['direction']]['label']
        if b['state']=='uncertain':
            text=f'{name}: результат отправки письма не подтверждён.\nСначала проверьте почту или свяжитесь с получателем. Не отправляйте повторно, пока не убедитесь, что письмо не пришло.'
            buttons=[[self.button('Письмо найдено', 'found',b)],[self.button('Письма нет — ручная отправка','missing',b)]]
        else:
            text=f'{name}: доступна ручная отправка.\n{b["error"] or "Автоматическая отправка не завершилась."}\nФайлов: {len(self.q.batch_files(b["id"]))}.\n'+('Автоматическое письмо приостановлено.' if b['state']=='manual' else 'Автоповторы остановятся только после кнопки «Взять отправку».')
            if b['needs_revoke']:text+='\nСостав изменён. Не используйте предыдущую ссылку: её отзыв ещё проверяется.'
            text+='\n'+('Ссылка на ZIP готова — её получит сотрудник, взявший отправку.' if b['link'] else 'Готовой ссылки нет. Можно получить оригиналы в Telegram, собрать архив и отправить самостоятельно.')
            if b['manual_by']:text+='\nЗадача уже взята в работу.'
            buttons=[[self.button('Взять / открыть отправку','take',b)]]
        return text,buttons

    async def show_list(self,worker,event):
        if not self.authorized(event.sender_id):raise UserError('Ручные отправки доступны ответственному филиалу и владельцу.')
        batches=self.list()
        if not batches:await worker.reply(event,'Ручных отправок сейчас нет.');return
        for b in batches:
            text,buttons=self.alert(b)
            await worker.reply(event,text,buttons)

    async def show_taken(self,worker,event,b):
        text=f'Заказ {b["id"][:8]} взят вами. Получатель: {b["recipient"]}.\n'
        if b['link'] and not b['needs_revoke']:
            text+='Готовый файл:\n'+b['link']+'\nОтправьте эту ссылку получателю самостоятельно.'
        else:text+=('Получите оригиналы кнопкой ниже и соберите холст PNG RGB с прозрачностью, 56 см, 300 dpi, с указанными копиями. Отправьте ссылку получателю самостоятельно.' if b['direction']=='dtf' else 'Получите оригиналы кнопкой ниже, скачайте их на компьютер, соберите ZIP и отправьте получателю самостоятельно.')
        buttons=[[self.button('Получить все исходники','docs',b)],
                 [self.button('Повторить недоставленные исходники','retrydocs',b)],
                 [self.button('Отправлено вручную','done',b)]]
        await worker.reply(event,text,buttons)

    async def callback(self,worker,event):
        try:
            prefix,action,bid,rev=event.data.decode().split(':')
            revision=int(rev);uid=event.sender_id
            if not event.is_private:raise UserError('Откройте личный чат с ботом.')
            if action in ('found','missing'):
                b=self.check(bid,uid,revision,('uncertain',))
                if action=='found':
                    self.q.reset_uncertain(bid,True)
                    await event.answer('Получение письма подтверждено вами.');return
                buttons=[[self.button('Проверил: письма нет. Взять вручную','resolve',b)]]
                await event.answer()
                await worker.reply(event,'Повторная отправка может создать дубль. Подтверждайте только после проверки почты/получателя.',buttons);return
            if action=='resolve':
                self.check(bid,uid,revision,('uncertain',))
                self.pause(bid,'uncertain','Письмо не найдено по проверке сотрудника. Требуется ручная отправка.')
            b=self.check(bid,uid,revision,('manual','collecting') if action=='take' else ('manual',))
            if action in ('take','resolve'):
                b=self.take(bid,uid,revision);worker.choose(uid,b['direction'])
                await event.answer();await self.show_taken(worker,event,b)
            elif action in ('docs','retrydocs'):
                count=self.request_files(bid,uid,revision,retry=action=='retrydocs')
                await event.answer()
                await worker.reply(event,f'Подготовлена выдача {count} исходников. Бот пришлёт их отдельными документами с номерами. Скачайте по одному оригиналу каждого номера. Перед повтором проверьте, какие уже пришли.')
            elif action=='done':
                if b['manual_by']!=uid:raise UserError('Эту отправку выполняет другой сотрудник.')
                await event.answer()
                await worker.reply(event,'Вы уже отправили актуальный состав заказа получателю? Отметка уберёт его из очереди; сама кнопка письмо не отправляет.',[[self.button('Да, уже отправил вручную','confirm',b)]])
            elif action=='confirm':
                self.finish(bid,uid,revision)
                await event.answer('Ручная отправка отмечена.');await event.edit('Ручная отправка подтверждена сотрудником. Автоматического повтора не будет.',buttons=None)
        except UserError as e:await event.answer(str(e),alert=True)
        except (ValueError,UnicodeError):await event.answer('Некорректная команда.',alert=True)

    async def notify(self,worker,b):
        if b['state']=='manual_sent':
            text='Сотрудник отметил ручную отправку заказа. Автоматического повтора не будет.'
            buttons=None
            targets=self.targets()|{r['chat'] for r in self.q.batch_files(b['id'])}
        else:text,buttons=self.alert(b);targets=self.targets()
        if not targets:return
        event=f'{b["state"]}:{b["manual_revision"]}'
        complete=True
        for uid in targets:
            with self.q.lock:done=self.q.db.execute('select 1 from handoff_notices where batch=? and event=? and chat=?',(b['id'],event,uid)).fetchone()
            if done:continue
            try:
                await worker.client.send_message(uid,text,buttons=buttons,parse_mode=None)
            except Exception:
                complete=False;continue
            with self.q.lock,self.q.db:self.q.db.execute('insert or ignore into handoff_notices values(?,?,?)',(b['id'],event,uid))
        if complete:
            with self.q.lock,self.q.db:
                self.q.db.execute('update batches set notified=1 where id=? and state=? and manual_revision=?',(b['id'],b['state'],b['manual_revision']))

    async def cleanup_links(self,worker):
        with self.q.lock:rows=[dict(r) for r in self.q.db.execute('select * from batches where needs_revoke is not null')]
        for b in rows:
            if self.next_revoke.get(b['id'],0)>time.time():continue
            try:
                await asyncio.to_thread(Disk(worker.c['disk_token']).revoke_generated,b['needs_revoke'])
                with self.q.lock,self.q.db:self.q.db.execute('update batches set needs_revoke=null where id=? and needs_revoke=?',(b['id'],b['needs_revoke']))
            except Exception:self.next_revoke[b['id']]=time.time()+120

    async def file_loop(self,worker):
        with self.q.lock,self.q.db:self.q.db.execute("update handoff_files set state='uncertain' where state='sending'")
        while worker.running:
            with self.q.lock:
                r=self.q.db.execute("select d.* from handoff_files d join batches b on b.id=d.batch join files f on f.id=d.file where d.state='queued' and b.state='manual' and d.revision=b.manual_revision and f.state!='cancelled' order by d.id limit 1").fetchone()
                job=dict(r) if r else None
            if not job:await asyncio.sleep(2);continue
            if not self.authorized(job['user']):
                with self.q.lock,self.q.db:self.q.db.execute("update handoff_files set state='error' where id=?",(job['id'],))
                continue
            row=self.q.file(job['file']);b=self.q.batch(job['batch'])
            if b['manual_by']!=job['user']:await asyncio.sleep(2);continue
            with self.q.lock,self.q.db:self.q.db.execute("update handoff_files set state='sending' where id=?",(job['id'],))
            try:
                # Reuse Telegram's original document. No local archive or Disk is required.
                original=worker.cached.get((row['chat'],row['message']))
                if original is None:original=await worker.client.get_messages(row['chat'],ids=row['message'])
                document=original.document if original and original.document else None
                if document is None:
                    local=self.q.path(row)
                    if not local.exists() or local.stat().st_size!=row['size']:raise UserError('Оригинал недоступен. Попросите филиал загрузить его заново.')
                    import hashlib
                    with local.open('rb') as source:
                        if not row['sha256'] or hashlib.file_digest(source,'sha256').hexdigest()!=row['sha256']:raise UserError('Сохранённый оригинал повреждён.')
                    document=str(local)
                latest=self.q.batch(b['id'])
                if latest['state']!='manual' or latest['manual_by']!=job['user'] or not self.authorized(job['user']) or latest['manual_revision']!=job['revision'] or self.q.file(row['id'])['state']=='cancelled':continue
                caption=f'Исходник #{row["id"]}: {row["name"]}'+(f' — {row["copies"]} копий' if row['direction']=='dtf' else '')+f'\nЗаказ {b["id"][:8]}, версия состава {job["revision"]+1}. Не включайте повторные копии одного номера в архив.'
                message=await worker.client.send_file(job['user'],document,caption=caption,force_document=True,parse_mode=None)
                with self.q.lock,self.q.db:self.q.db.execute("update handoff_files set state='done',message=? where id=?",(message.id,job['id']))
            except asyncio.CancelledError:raise
            except Exception:
                with self.q.lock,self.q.db:self.q.db.execute("update handoff_files set state='uncertain' where id=?",(job['id'],))
                try:await worker.client.send_message(job['user'],f'Не подтверждена выдача исходника #{row["id"]}: {row["name"]}. Проверьте чат и нажмите «Повторить недоставленные исходники» только для отсутствующих копий.',parse_mode=None)
                except Exception:pass
