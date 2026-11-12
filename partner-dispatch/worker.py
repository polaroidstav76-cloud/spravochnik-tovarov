from __future__ import annotations
import asyncio
import hashlib
import hmac
import os
import shutil
import smtplib
import time
import uuid
from pathlib import Path
from core import Queue, UserError, MOSCOW, BUTTONS, DIRECTIONS, UPLOAD, BACK, build_archive, chunks
from services import Disk, email_for, smtp_connect, check_dedicated_bot


class Worker:
    def __init__(self,queue,config,log):
        self.q=queue;self.c=config;self.log=log
        self.client=None;self.running=True;self.loop=None
        self.cached={};self.retry_at={};self.tasks=[]

    def stop(self):
        self.running=False
        if self.loop and not self.loop.is_closed() and self.client:
            asyncio.run_coroutine_threadsafe(self.client.disconnect(),self.loop)

    def direction(self,uid):
        value=self.q.setting('direction:'+str(uid))
        return value if value in DIRECTIONS and DIRECTIONS[value]['enabled'] else None

    def choose(self,uid,direction):
        self.q.set_setting('direction:'+str(uid),direction or '')

    async def reply(self,event,text,buttons=None):
        from telethon import Button
        if buttons is None:
            direction=self.direction(event.sender_id)
            if direction:
                buttons=[[Button.text(UPLOAD,resize=True,persistent=True)],
                         [Button.text(BUTTONS[0])],[Button.text(BUTTONS[1]),Button.text(BUTTONS[2])],[Button.text(BACK)]]
            else:
                buttons=[[Button.text(r['label'],resize=True,persistent=True)] for r in DIRECTIONS.values()]
        await event.respond(text,buttons=buttons,parse_mode=None)

    async def on_message(self,event):
        if not event.is_private:return
        text=(event.raw_text or '').strip();uid=event.sender_id
        owner=self.q.setting('owner')
        if text.startswith('/owner '):
            if not hmac.compare_digest(text[7:].strip().encode(),self.c['owner_code'].encode()):return
            if owner and owner!=str(uid):return
            self.q.set_setting('owner',uid);self.q.join(uid,'Основной филиал')
            self.choose(uid,None)
            await self.reply(event,'Владелец подключён. Выберите направление печати.');return
        if text.startswith('/join '):
            parts=text.split(maxsplit=2)
            if len(parts)!=3 or not hmac.compare_digest(parts[1].encode(),self.c['join_code'].encode()):
                await event.respond('Неверный код подключения. Обратитесь к руководителю.',parse_mode=None);return
            self.q.join(uid,parts[2]);self.choose(uid,None)
            await self.reply(event,'Филиал подключён. Выберите направление печати.');return
        if not self.q.user(uid):
            await event.respond('Этот бот принимает файлы только от подключённых сотрудников. Получите код подключения у руководителя.',parse_mode=None);return
        try:
            if text in ('/start','/menu',BACK,'Главное меню'):
                self.choose(uid,None)
                await self.reply(event,'Выберите направление печати.');return
            chosen=next((key for key,value in DIRECTIONS.items() if text==value['label']),None)
            if chosen:
                self.choose(uid,chosen if DIRECTIONS[chosen]['enabled'] else None)
                if not DIRECTIONS[chosen]['enabled']:
                    await self.reply(event,'ДТФ-печать пока не настроена. Файлы в это направление пока не принимаются. Выберите широкоформатную печать.');return
                await self.reply(event,'Направление: '+DIRECTIONS[chosen]['label']+'.\nОтправьте макет документом, без сжатия, или выберите действие.');return
            direction=self.direction(uid)
            if not direction:
                await self.reply(event,'Сначала выберите направление печати. Файл пока не принят.');return
            if text==UPLOAD:
                await self.reply(event,'Направление: '+DIRECTIONS[direction]['label']+'.\nОтправьте оригинал документом, до 500 МБ.');return
            if text==BUTTONS[0] or text=='/files':
                rows=self.q.waiting(direction)
                if not rows:await self.reply(event,'Очередь пуста.');return
                # User-facing list deliberately contains names only.
                for part in chunks(r['name'] for r in rows):await self.reply(event,part)
            elif text==BUTTONS[1] or text=='/send':
                if not self.q.setting('owner'):raise UserError('Сначала подключите владельца на основном компьютере.')
                bid=self.q.claim(self.c['recipient'],time.time(),manual=True,direction=direction)
                await self.reply(event,'Начинаю отправку текущей очереди.' if bid else 'Очередь пуста.')
            elif text==BUTTONS[2] or text=='/delete':
                await self.delete_menu(event,0,direction)
            elif event.document:
                file=event.file
                r=self.q.add(event.chat_id,event.id,uid,file.name or '',file.size,event.date.timestamp(),direction=direction)
                if r['state']=='cancelled':await self.reply(event,'Этот файл ранее удалён.');return
                self.cached[(r['chat'],r['message'])]=event.message
                await self.reply(event,f'{DIRECTIONS[direction]["label"]}: получаю «{r["name"]}». Дождитесь подтверждения «Сохранён».')
            elif event.photo:
                await self.reply(event,'Пришлите макет как файл, без сжатия, чтобы сохранить оригинал для печати.')
            else:
                await self.reply(event,'Отправьте макет документом (TIF, TIFF, PDF, JPG, PNG), до 500 МБ.')
        except UserError as e:await self.reply(event,str(e))

    async def delete_menu(self,event,offset,direction):
        from telethon import Button
        rows=self.q.waiting(direction);page=rows[offset:offset+10]
        if not page:await self.reply(event,'Очередь пуста.');return
        buttons=[[Button.inline(f'✕ {r["name"][:65]} · #{r["id"]}',f'delete:{direction}:{r["id"]}'.encode())] for r in page]
        nav=[]
        if offset:nav.append(Button.inline('Назад',f'page:{direction}:{max(0,offset-10)}'.encode()))
        if offset+10<len(rows):nav.append(Button.inline('Далее',f'page:{direction}:{offset+10}'.encode()))
        if nav:buttons.append(nav)
        await self.reply(event,'Выберите файл для удаления. Номер отличает файлы с одинаковым названием.',buttons)

    async def on_callback(self,event):
        if not event.is_private or not self.q.user(event.sender_id):
            await event.answer('Нет доступа.',alert=True);return
        try:
            data=event.data.decode()
            action,direction,value=data.split(':',2)
            if direction!=self.direction(event.sender_id):
                await event.answer('Откройте соответствующее направление и выберите файл заново.',alert=True);return
            number=int(value)
            if number<0:raise ValueError()
            if action=='page':
                await event.answer();await self.delete_menu(event,number,direction)
            elif action=='delete':
                r=self.q.cancel(number,direction=direction)
                try:self.q.path(r).unlink(missing_ok=True)
                except OSError:pass # A currently downloading file is removed when download finishes.
                await event.answer('Файл удалён из очереди.')
                await event.edit('Удалён: '+r['name'],buttons=None,parse_mode=None)
        except UserError as e:await event.answer(str(e),alert=True)
        except (ValueError,UnicodeError):await event.answer('Некорректная команда.',alert=True)

    async def download_loop(self):
        while self.running:
            r=self.q.download_candidate(time.time())
            if not r:await asyncio.sleep(2);continue
            dest=self.q.path(r);temp=dest.with_suffix(dest.suffix+'.part')
            try:
                if shutil.disk_usage(self.q.root).free<r['size']*2+1024**3:
                    raise UserError('Недостаточно места на основном компьютере.')
                dest.parent.mkdir(parents=True,exist_ok=True)
                msg=self.cached.pop((r['chat'],r['message']),None)
                if msg is None:msg=await self.client.get_messages(r['chat'],ids=r['message'])
                if not msg or not msg.document:raise UserError('Исходный файл недоступен в Telegram. Загрузите его заново.')
                async def progress(received,total):
                    if self.q.file(r['id'])['state']=='cancelled':raise UserError('Файл удалён из очереди.')
                await self.client.download_media(msg,file=str(temp),progress_callback=progress)
                if self.q.file(r['id'])['state']=='cancelled':continue
                if not temp.exists() or temp.stat().st_size!=r['size']:
                    raise UserError('Файл получен не полностью.')
                def checksum():
                    with temp.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
                sha=await asyncio.to_thread(checksum)
                if self.q.file(r['id'])['state']=='cancelled':continue
                os.replace(temp,dest);self.q.downloaded(r['id'],sha)
                self.log('Сохранён: '+r['name'])
                try:
                    await self.client.send_message(r['chat'],f'Сохранён: {r["name"]}\nОтправка по расписанию: {r["due"]}, 18:00 МСК. Для срочной отправки нажмите «Отправить сейчас».',parse_mode=None)
                except Exception:self.log('Не удалось отправить подтверждение загрузки. Файл сохранён.')
            except asyncio.CancelledError:raise
            except Exception as e:
                reason=str(e) if isinstance(e,UserError) else 'Не удалось скачать файл. Проверьте связь с Telegram.'
                retry_note='Будет повтор; состояние видно в программе на основном компьютере.' if self.q.file(r['id'])['attempts']<5 else 'Пять попыток не удались. Удалите эту запись и отправьте исходный файл заново.'
                self.q.download_failed(r['id'],time.time(),reason)
                self.log(reason+' '+r['name'])
                if not self.q.file(r['id'])['state']=='cancelled':
                    try:await self.client.send_message(r['chat'],f'Пока не сохранён: {r["name"]}. {reason} {retry_note}',parse_mode=None)
                    except Exception:pass
            finally:
                temp.unlink(missing_ok=True)
                if self.q.file(r['id'])['state']=='cancelled':
                    try:dest.unlink(missing_ok=True)
                    except OSError:pass

    async def process_batch(self,b):
        bid=b['id'];disk=Disk(self.c['disk_token'])
        if self.retry_at.get(bid,0)>time.time():return
        if b['state']=='invalidated':
            self.q.transition(bid,'invalidated','collecting');return
        rows=self.q.batch_files(bid)
        if not rows:
            if b.get('remote_path'):await asyncio.to_thread(disk.remove_generated,b['remote_path'])
            self.q.transition(bid,b['state'],'cancelled');return
        if any(r['state']!='ready' for r in rows):return
        if not self.q.transition(bid,'collecting','packing'):return
        try:
            if b.get('remote_path'):await asyncio.to_thread(disk.remove_generated,b['remote_path'])
            archive=await asyncio.to_thread(build_archive,self.q,bid)
            remote=f'disk:/Cloudshop-Print/{bid}_{uuid.uuid4().hex}.zip'
            if not self.q.transition(bid,'packing','uploading',remote_path=remote):return
            link=await asyncio.to_thread(disk.upload,archive,remote)
            if not self.q.transition(bid,'uploading','ready',link=link):
                await asyncio.to_thread(disk.remove_generated,remote);return
            b=self.q.batch(bid)
            # Login happens before the irreversible boundary; deletion is still possible here.
            smtp=await asyncio.to_thread(smtp_connect,self.c)
            try:
                msg=email_for(self.c,b,rows)
                if not self.q.accept_smtp(bid):return
                try:
                    await asyncio.to_thread(smtp.send_message,msg)
                except (smtplib.SMTPRecipientsRefused,smtplib.SMTPSenderRefused,smtplib.SMTPDataError):
                    self.q.transition(bid,'submitting','collecting',error='Почтовый сервер отказал в отправке. Заказ сохранён.')
                    self.retry_at[bid]=time.time()+300
                    self.log('Почтовый сервер отказал в отправке. Будет повтор через 5 минут.')
                except Exception:
                    self.q.transition(bid,'submitting','uncertain',error='Почтовый сервер не подтвердил результат. Проверьте тестовый ящик перед повтором.')
                    self.log('Результат письма не определён. Автоповтор остановлен, чтобы не создать дубль.')
                else:
                    self.q.transition(bid,'submitting','sent',error=None)
                    self.log(f'Письмо принято почтовым сервером: {len(rows)} файлов.')
            finally:
                try:await asyncio.to_thread(smtp.close)
                except Exception:pass
        except asyncio.CancelledError:raise
        except Exception as e:
            reason=str(e) if isinstance(e,UserError) else 'Сбой подготовки отправки. Проверьте интернет и настройки.'
            current=self.q.batch(bid)['state']
            if current in ('packing','uploading','ready'):
                self.q.transition(bid,current,'collecting',error=reason)
            self.retry_at[bid]=time.time()+300
            self.log(reason+' Повтор через 5 минут; файлы сохранены.')

    async def notify(self):
        owner=self.q.setting('owner')
        if not owner:return
        for b in self.q.pending_notifications():
            if b['state']=='sent':
                text=f'Заказ отправлен на {b["recipient"]}.\nФайлов: {len(self.q.batch_files(b["id"]))}.\nАрхив: {b["link"]}\nПисьмо принято почтовым сервером; получение партнёром не подтверждено.'
                chats={r['chat'] for r in self.q.batch_files(b['id'])}|{int(owner)}
            else:
                text='Не удалось подтвердить отправку письма. Проверьте ящик и окно программы на основном компьютере. Автоматический повтор остановлен, чтобы не отправить заказ дважды.'
                chats={int(owner)}
            complete=True
            for chat in chats:
                if self.q.notice_done(b['id'],chat):continue
                notice=text if chat==int(owner) or b['state']!='sent' else f'Заказ отправлен. Файлов в отправке: {len(self.q.batch_files(b["id"]))}. Письмо принято почтовым сервером.'
                try:
                    await self.client.send_message(chat,notice,parse_mode=None)
                    self.q.finish_notice(b['id'],chat)
                except Exception as e:
                    if type(e).__name__ in ('UserIsBlockedError','ChatWriteForbiddenError','PeerIdInvalidError'):
                        self.q.finish_notice(b['id'],chat)
                        self.log('Один из сотрудников недоступен для уведомления Telegram.')
                    else:
                        complete=False
                        self.log('Одно уведомление Telegram пока не доставлено. Повторим позже.')
            if complete:self.q.mark_notified(b['id'])

    async def schedule_loop(self):
        while self.running:
            try:
                if self.q.setting('automatic','0')=='1':self.q.claim(self.c['recipient'],time.time())
                b=self.q.active_batch()
                if b:await self.process_batch(b)
                await self.notify()
            except asyncio.CancelledError:raise
            except Exception:self.log('Не удалось выполнить проверку очереди. Повторим через 10 секунд.')
            await asyncio.sleep(10)

    async def run(self):
        from telethon import TelegramClient,events
        self.loop=asyncio.get_running_loop()
        await asyncio.to_thread(check_dedicated_bot,self.c['bot_token'])
        # Only a bot token is used. No personal Telegram session or phone login.
        self.client=TelegramClient(str(self.q.root/'telegram-bot'),int(self.c['api_id']),self.c['api_hash'],catch_up=True)
        self.client.add_event_handler(self.on_message,events.NewMessage(incoming=True))
        self.client.add_event_handler(self.on_callback,events.CallbackQuery())
        try:
            await self.client.connect()
            if not await self.client.is_user_authorized():
                await self.client.sign_in(bot_token=self.c['bot_token'])
            me=await self.client.get_me()
            if str(me.id)!=self.c['bot_token'].split(':')[0]:raise UserError('Токен изменился. Остановите программу и обратитесь за переносом сессии; не удаляйте очередь.')
            if self.c.get('bot_username') and (me.username or '').lower()!=self.c['bot_username'].lstrip('@').lower():raise UserError('Этот токен относится к другому боту. Нужен @perezakazi_bot.')
            if not me.bot:raise UserError('Нужен отдельный бот, а не личный аккаунт Telegram.')
            self.log('Бот подключён: @'+str(me.username))
            await self.client.catch_up()
            self.tasks=[asyncio.create_task(self.download_loop()),asyncio.create_task(self.schedule_loop())]
            await self.client.run_until_disconnected()
        finally:
            self.running=False
            for task in self.tasks:task.cancel()
            await asyncio.gather(*self.tasks,return_exceptions=True)
            if self.client.is_connected():await self.client.disconnect()
            self.log('Обработчик остановлен. Очередь сохранена на компьютере.')
