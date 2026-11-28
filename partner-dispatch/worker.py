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
from monitoring import Monitoring
from handoff import Handoff,MANUAL_MENU
from bot_features import BotFeatures,STATUS,NEXT,UNDO
from dtf_render import inspect_art,build_sheet
from local_delivery import LocalDelivery
from file_formats import validate_content
from progress_cards import ProgressCards
from vpn_reminder import VpnReminder
from dtf_review import DtfReview
from masterphoto import Masterphoto,INSTRUCTIONS
from services import Disk, email_for, smtp_connect, check_dedicated_bot


class Worker:
    def __init__(self,queue,config,log):
        self.q=queue;self.c=config;self.log=log
        self.client=None;self.running=True;self.loop=None
        self.cached={};self.retry_at={};self.tasks=[];self.monitor=Monitoring(queue);self.handoff=Handoff(queue);self.features=BotFeatures(queue);self.local_delivery=LocalDelivery(self);self.cards=ProgressCards(self);self.vpn=VpnReminder(self);self.dtf_review=DtfReview(self);self.masterphoto=Masterphoto(self);self.q.set_setting('runtime_version','0.14')
        with self.q.lock:
            rejected=[r[0] for r in self.q.db.execute("select id from files where state='cancelled' and error is not null")]
        for file_id in rejected:self.q.discard_rejected(file_id)
        with self.q.lock,self.q.db:
            self.q.db.execute("update batches set state='uncertain',notified=0,error='Ручная отправка отключена. Проверьте почту и отметьте результат в программе перед повтором.' where state='manual'")

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
            def keys(rows):return [[Button.text(label,resize=True,persistent=True) for label in row] for row in rows]
            if not direction:
                rows=[['🖨 '+DIRECTIONS['wideformat']['label'],'👕 '+DIRECTIONS['dtf']['label']],['🛠 '+DIRECTIONS['workshop']['label'],'Мастерфото']]

                rows.append(['Инструкция по отправке файлов'])
                buttons=keys(rows)
            else:
                rows=[['📥 '+UPLOAD,'📋 '+BUTTONS[0]],['🚀 '+BUTTONS[1],'🗑 '+BUTTONS[2]],['↩️ '+UNDO,'📊 '+STATUS]]
                if direction in ('workshop','photo30','masterphoto'):rows=[rows[0],['🗑 '+BUTTONS[2],'📊 '+STATUS]]
                if direction=='dtf':rows.append(['Количество копий','Инструкция по отправке файлов'])
                if direction=='masterphoto':rows.insert(0,['Односторонние визитки','Двусторонние визитки'])
                if direction!='dtf':rows.append(['Инструкция по отправке файлов'])
                rows.append(['Главное меню','⬅️ '+BACK])
                buttons=keys(rows)
        await event.respond(text,buttons=buttons,parse_mode=None)

    async def on_message(self,event):
        if not event.is_private:return
        message_id=getattr(event,'id',None)
        if message_id is not None and not self.q.accept_event('message',str(event.chat_id)+':'+str(message_id)):return
        await self._on_message(event)

    async def _on_message(self,event):
        if not event.is_private:return
        text=(event.raw_text or '').strip();uid=event.sender_id
        text=text.lstrip('🖨👕🛠🖼📥📋🚀🗑📊⬅️🕒↩️📂 ').strip()
        owner=self.q.setting('owner')
        parts=text.split(maxsplit=1)
        if parts and parts[0].split('@')[0]=='/owner':
            if len(parts)!=2:
                await event.respond('Нужна полная команда /owner с кодом из программы на компьютере.',parse_mode=None);return
            if not hmac.compare_digest(parts[1].strip().encode(),self.c['owner_code'].encode()):
                self.q.set_setting('owner_last_result','code_mismatch')
                self.log('Подключение владельца отклонено: код не совпадает с кодом запущенной программы.')
                await event.respond('Код владельца не совпадает с кодом запущенной программы. Откройте «Подключить сотрудников» на компьютере и нажмите «Скопировать команду владельца».',parse_mode=None);return
            if owner and owner!=str(uid):
                self.q.set_setting('owner_last_result','different_owner')
                self.log('Подключение отклонено: владельцем уже назначен другой Telegram-аккаунт.')
                await event.respond('Владельцем уже назначен другой Telegram-аккаунт. Доступы и код не изменены.',parse_mode=None);return
            self.q.set_setting('owner_last_result','connected')
            self.q.set_setting('owner',uid);self.q.join(uid,'Основной филиал')
            self.choose(uid,None)
            await self.reply(event,'Владелец подключён. Выберите направление печати.');return
        if text.startswith('/responsible '):
            code=text.split(maxsplit=1)[1].strip()
            expected=self.c.get('responsible_code','')
            branch=self.q.setting('alert_branch')
            if not expected or not branch or not hmac.compare_digest(code.encode(),expected.encode()):
                await event.respond('Неверный код ответственного филиала или филиал не настроен в программе.',parse_mode=None);return
            self.q.join(uid,branch);self.q.set_setting('alert_role:'+str(uid),branch)
            self.choose(uid,None)
            await self.reply(event,'Ответственный филиал подключён. Вам будут приходить уведомления о сбоях и нехватке места.');return
        if text.startswith('/join '):
            parts=text.split(maxsplit=2)
            if len(parts)!=3 or not hmac.compare_digest(parts[1].encode(),self.c['join_code'].encode()):
                await event.respond('Неверный код подключения. Обратитесь к руководителю.',parse_mode=None);return
            self.q.join(uid,parts[2]);self.q.set_setting('alert_role:'+str(uid),'');self.choose(uid,None)
            await self.reply(event,'Филиал подключён. Выберите направление печати.');return
        if not self.q.user(uid):
            await event.respond('Этот бот принимает файлы только от подключённых сотрудников. Получите код подключения у руководителя.',parse_mode=None);return
        try:
            if text in ('Инструкция по отправке файлов','/help'):
                await self.reply(event,INSTRUCTIONS);return
            if event.document and self.direction(uid)=='dtf' and await self.dtf_review.handle_document(event):return
            if text==MANUAL_MENU or text=='/manual':
                await self.reply(event,'Ручная отправка отключена. Используйте «Отправить сейчас».');return
            if text in ('/start','/menu',BACK,'Главное меню'):
                self.choose(uid,None)
                await self.reply(event,'Выберите направление печати. Программа 0.14.');return
            chosen=next((key for key,value in DIRECTIONS.items() if text==value['label']),None)
            if chosen:
                if chosen=='masterphoto':
                    self.choose(uid,chosen);await self.masterphoto.prompt(event);return
                self.choose(uid,chosen if DIRECTIONS[chosen]['enabled'] else None)
                if not DIRECTIONS[chosen]['enabled']:
                    await self.reply(event,'ДТФ-печать пока не настроена. Файлы в это направление пока не принимаются. Выберите широкоформатную печать.');return
                await self.reply(event,'Направление: '+DIRECTIONS[chosen]['label']+'.\nОтправьте макет документом, без сжатия, или выберите действие.');return
            direction=self.direction(uid)
            if not direction:
                await self.reply(event,'Сначала выберите направление печати. Файл пока не принят.');return
            if direction=='masterphoto' and await self.masterphoto.handle(event,text):return
            if direction=='dtf' and (text=='Количество копий' or text=='/copies'):
                await self.copies_menu(event);return
            if direction=='dtf' and text.isdigit():
                pending=self.q.setting('dtf_pending:'+str(uid))
                if not pending:raise UserError('Сначала выберите принт кнопкой «Количество копий».')
                self.q.set_copies(int(pending),uid,int(text))
                self.q.set_setting('dtf_pending:'+str(uid),'')
                await self.reply(event,f'Количество сохранено: {int(text)} шт.');return
            if text==UPLOAD:
                await self.reply(event,'Направление: '+DIRECTIONS[direction]['label']+'.\nОтправьте оригинал документом, до 500 МБ.');return
            if text in (BUTTONS[0],'Просмотр файлов','/files'):
                rows=self.q.waiting(direction)
                if not rows:await self.reply(event,'Очередь пуста.');return
                for part in chunks(self.features.file_lines(direction)):await self.reply(event,DIRECTIONS[direction]['label']+' · загруженные файлы\n'+part)
            elif text==BUTTONS[1] or text=='/send':
                if direction=='dtf' and not self.c.get('dtf_recipient'):raise UserError('Укажите тестового получателя ДТФ в программе.')
                if not self.q.setting('owner'):raise UserError('Сначала подключите владельца на основном компьютере.')
                if direction in ('workshop','photo30','masterphoto'):
                    await self.reply(event,'В этом направлении каждый файл отправляется автоматически после сохранения.');return
                from telethon import Button
                token,count=self.features.request(uid,direction)
                if not token:
                    await self.reply(event,'Текущий заказ уже обрабатывается. Проверьте «Состояние».' if self.q.waiting(direction) else 'Очередь пуста.');return
                rows=self.q.waiting(direction)
                branches=len({r['branch'] for r in rows if r['batch'] is None})
                copy_note=f' Всего копий: {sum(r["copies"] for r in rows if r["batch"] is None)}.' if direction=='dtf' else ''
                await self.reply(event,f'Отправить общую очередь: {count} файлов от {branches} филиалов?{copy_note} Состав фиксируется после подтверждения. Подтверждение действует 5 минут.',[[Button.inline('Подтвердить отправку',('send:'+token).encode()),Button.inline('Отмена',('abort:'+token).encode())]])
            elif text in (NEXT,'/next'):
                await self.reply(event,self.features.status(direction))
            elif text in (UNDO,'/undo'):
                from telethon import Button
                row=self.features.last_upload(uid,direction)
                if not row:await self.reply(event,'Ваших файлов, которые ещё можно отменить до отправки, нет.');return
                await self.reply(event,'Отменить вашу последнюю загрузку?\n'+row['name'],[[Button.inline('↩️ Отменить загрузку',f'undo:{direction}:{row["id"]}'.encode()),Button.inline('Оставить',f'keep:{direction}:{row["id"]}'.encode())]])
            elif text==STATUS or text=='/status':
                await self.reply(event,self.features.status(direction))
            elif text==BUTTONS[2] or text=='/delete':
                await self.delete_menu(event,0,direction)
            elif event.document:
                file=event.file
                r=self.q.add(event.chat_id,event.id,uid,file.name or '',(file.size or 0),event.date.timestamp(),direction=direction)
                if r['state']=='cancelled':await self.reply(event,'Этот файл ранее удалён.');return
                self.cached[(r['chat'],r['message'])]=event.message
                await self.reply(event,f'{DIRECTIONS[direction]["label"]}: получаю «{r["name"]}». Дождитесь подтверждения «Сохранён».')

            elif event.photo:
                await self.reply(event,'Пришлите макет как файл, без сжатия, чтобы сохранить оригинал для печати.')
            else:
                await self.reply(event,'Отправьте подходящий для выбранного раздела оригинал документом, до 500 МБ.')
        except UserError as e:await self.reply(event,str(e))

    def recipient(self,direction):
        if direction=='masterphoto':return self.c.get('masterphoto_recipient','')
        if direction=='photo30':return 'local:30x40'
        if direction=='workshop':return self.c.get('workshop_recipient','')
        return self.c.get('dtf_recipient','') if direction=='dtf' else self.c['recipient']

    async def copies_menu(self,event):
        from telethon import Button
        rows=[r for r in self.q.waiting('dtf') if r['batch'] is None and (r['sender']==event.sender_id or self.q.setting('owner')==str(event.sender_id))]
        if not rows:await self.reply(event,'Ваших принтов для изменения количества нет.');return
        for start in range(0,len(rows),20):
            buttons=[[Button.inline(f'#{r["id"]} '+r['name'][:40]+f' — {r["copies"]} шт.',f'copies:{r["id"]}'.encode())] for r in rows[start:start+20]]
            await self.reply(event,'Выберите принт для изменения количества:',buttons)

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
        query_id=getattr(getattr(event,'query',None),'query_id',None)
        if query_id is not None and not self.q.accept_event('callback',str(query_id)):
            await event.answer();return
        await self._on_callback(event)

    async def _on_callback(self,event):
        if not event.is_private or not self.q.user(event.sender_id):
            await event.answer('Нет доступа.',alert=True);return
        try:
            data=event.data.decode()
            if data.startswith('card:'):
                await self.masterphoto.callback(event);return
            if data.startswith('dtf:'):
                try:await self.dtf_review.callback(event)
                except UserError as e:await self.reply(event,str(e))
                return
            if data.startswith('copies:'):
                row=self.q.file(int(data.split(':')[1]))
                if not row or row['direction']!='dtf' or row['batch'] is not None or (row['sender']!=event.sender_id and self.q.setting('owner')!=str(event.sender_id)):raise UserError('Принт недоступен для изменения.')
                self.q.set_setting('dtf_pending:'+str(event.sender_id),row['id'])
                self.choose(event.sender_id,'dtf')
                await event.answer();await self.reply(event,'Введите количество копий для «'+row['name']+'» от 1 до 999.');return
            if data.startswith('h:'):
                await event.answer('Ручная отправка отключена.',alert=True);return
            if data.startswith('send:'):
                token=data.split(':',1)[1]
                with self.q.lock:confirmation=self.q.db.execute('select direction from send_confirmations where token=?',(token,)).fetchone()
                recipient=self.recipient(confirmation['direction']) if confirmation else ''
                if not recipient:raise UserError('Укажите получателя этого направления в программе.')
                bid=self.features.confirm(token,event.sender_id,recipient)
                if bid:self.q.set_setting('batch_progress:'+bid,event.sender_id)
                await event.answer('Отправка подтверждена.')
                await event.edit('Начинаю отправку текущей очереди.' if bid else 'Очередь пуста.',buttons=None);return
            if data.startswith('abort:'):
                token=data.split(':',1)[1]
                with self.q.lock,self.q.db:
                    changed=self.q.db.execute('update send_confirmations set used=1 where token=? and user=? and used=0',(token,event.sender_id)).rowcount
                if not changed:raise UserError('Подтверждение уже использовано.')
                await event.answer('Отменено.');await event.edit('Отправка отменена. Файлы остаются в очереди.',buttons=None);return
            action,direction,value=data.split(':',2)
            if action not in ('page','delete','keep','remove','undo'):
                raise UserError('Эта кнопка относится к другой версии программы. Откройте меню заново и проверьте, что старая программа остановлена на всех компьютерах.')
            if direction!=self.direction(event.sender_id):
                await event.answer('Откройте соответствующее направление и выберите файл заново.',alert=True);return
            number=int(value)
            if number<0:raise ValueError()
            if action=='page':
                await event.answer();await self.delete_menu(event,number,direction)
            elif action=='delete':
                from telethon import Button
                r=self.q.file(number)
                if not r or r['direction']!=direction or r['state']=='cancelled':raise UserError('Файл уже удалён или недоступен.')
                await event.answer()
                await event.edit(f'Удалить файл #{number}?\n{r["name"]}\nЗагрузил филиал: {r["branch"]}',buttons=[[Button.inline('🗑 Удалить',f'remove:{direction}:{number}'.encode()),Button.inline('Оставить',f'keep:{direction}:{number}'.encode())]],parse_mode=None)
                return
            elif action=='keep':
                await event.answer('Файл оставлен.');await event.edit('Файл оставлен в очереди.',buttons=None);return
            elif action in ('remove','undo'):
                r=self.features.undo(event.sender_id,direction,number) if action=='undo' else self.q.cancel(number,direction=direction)
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
            dest=self.q.path(r);temp=dest.with_suffix(dest.suffix+'.part');invalid_art=False
            try:
                if shutil.disk_usage(self.q.root).free<r['size']*2+1024**3:
                    raise UserError('Недостаточно места на основном компьютере.')
                dest.parent.mkdir(parents=True,exist_ok=True)
                msg=self.cached.pop((r['chat'],r['message']),None)
                if msg is None:msg=await self.client.get_messages(r['chat'],ids=r['message'])
                if not msg or not msg.document:raise UserError('Исходный файл недоступен в Telegram. Загрузите его заново.')
                async def progress(received,total):
                    await self.cards.update('file:'+str(r['id']),r['chat'],'📥 '+r['name'],f'Загрузка: {received/1048576:.1f} из {total/1048576:.1f} МБ',received,total)
                    if self.q.file(r['id'])['state']=='cancelled':raise UserError('Файл удалён из очереди.')
                await self.client.download_media(msg,file=str(temp),progress_callback=progress)
                if self.q.file(r['id'])['state']=='cancelled':continue
                if not temp.exists() or temp.stat().st_size!=r['size']:
                    raise UserError('Файл получен не полностью.')
                def checksum():
                    with temp.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
                sha=await asyncio.to_thread(checksum)
                if self.q.file(r['id'])['state']=='cancelled':continue
                try:
                    await asyncio.to_thread(validate_content,temp,r['direction'],r['name'])
                    if r['direction']=='masterphoto':
                        from masterphoto import validate_card
                        await asyncio.to_thread(validate_card,temp)
                except UserError:
                    invalid_art=True;raise
                if r['direction']=='dtf':
                    try:await asyncio.to_thread(inspect_art,temp)
                    except UserError:
                        invalid_art=True;raise
                os.replace(temp,dest);self.q.downloaded(r['id'],sha)
                self.log('Сохранён: '+r['name'])
                try:
                    prefix='dtf_' if r['direction']=='dtf' else ''
                    schedule='Отправка в выбранные дни в '+self.q.setting(prefix+'dispatch_time','12:00' if prefix else '18:00')+' МСК.' if self.q.setting(prefix+'automatic','0')=='1' else 'Расписание пока выключено.'
                    if r['direction']=='masterphoto':schedule='После проверки всех сторон выберите тираж в боте.'
                    if r['direction']=='workshop':schedule='Отправка в мастерскую начнётся автоматически, без ожидания расписания.'
                    elif r['direction']=='photo30':schedule='Передаю на компьютер 30×40. О сохранении на нём сообщу отдельно.'
                    if prefix:
                        info=await asyncio.to_thread(inspect_art,dest)
                        schedule+=f' Размер: {info["width_cm"]:.2f} × {info["height_cm"]:.2f} см.'
                        if not info['transparent']:schedule+=' Фон исходника непрозрачный и будет сохранён. Для прозрачного фона загрузите PNG с прозрачностью.'
                    await self.cards.update('file:'+str(r['id']),r['chat'],'✅ Сохранён: '+r['name'],schedule,force=True)
                except Exception:self.log('Не удалось отправить подтверждение загрузки. Файл сохранён.')
                if r['direction']=='masterphoto':
                    try:await self.masterphoto.downloaded(r)
                    except Exception:self.log('Визитки сохранены. Чтобы повторно выбрать тираж, нажмите «Загрузить файл» в разделе Мастерфото.')
            except asyncio.CancelledError:raise
            except Exception as e:
                reason=str(e) if isinstance(e,UserError) else 'Не удалось скачать файл. Проверьте связь с Telegram.'
                retry_note='Будет повтор; состояние видно в программе на основном компьютере.' if self.q.file(r['id'])['attempts']<5 else 'Пять попыток не удались. Удалите эту запись и отправьте исходный файл заново.'
                self.q.download_failed(r['id'],time.time(),reason)
                if invalid_art:
                    self.q.cancel(r['id'],direction=r['direction'])
                    retry_note='Файл отклонён и автоматически удалён с компьютера и из очереди. Загрузите исправленный оригинал.'
                self.log(reason+' '+r['name'])
                if invalid_art or self.q.file(r['id'])['state']!='cancelled':
                    await self.cards.update('file:'+str(r['id']),r['chat'],'❌ '+r['name'],reason+' '+retry_note,force=True)
            finally:
                temp.unlink(missing_ok=True)
                if self.q.file(r['id'])['state']=='cancelled':
                    try:dest.unlink(missing_ok=True)
                    except OSError:pass
                if invalid_art:self.q.discard_rejected(r['id'])

    async def process_batch(self,b):
        if b['direction']=='masterphoto':
            await self.masterphoto.process(b);return
        if b['direction']=='dtf' and b['state'] in ('review','editing'):
            await self.dtf_review.tick(b['id']);return
        if b['direction']=='photo30':
            await self.local_delivery.process(b);return
        bid=b['id'];disk=Disk(self.c['disk_token'])
        if float(self.q.setting('retry_at:'+bid,'0'))>time.time():return
        if b['recipient']!=self.recipient(b['direction']):
            self.q.set_setting('retry_at:'+bid,time.time()+600)
            self.log('У незавершённой отправки другой получатель. Отправка остановлена; удалите её файлы из очереди и загрузите заново для нового адреса.')
            return
        if b['state']=='invalidated':
            self.q.transition(bid,'invalidated','collecting');return
        rows=self.q.batch_files(bid)
        if not rows:
            if b.get('remote_path'):await asyncio.to_thread(disk.remove_generated,b['remote_path'])
            self.q.transition(bid,b['state'],'cancelled');return
        if any(r['state']!='ready' for r in rows):return
        if not self.q.transition(bid,'collecting','packing'):return
        chat=int(self.q.setting('batch_progress:'+bid,self.q.setting('owner','0')) or 0)
        title='📦 '+DIRECTIONS[b['direction']]['label']+' · '+str(len(rows))+' файлов'
        await self.cards.update('batch:'+bid,chat,title,'1/4 · Собираем заказ…',force=True)
        try:
            if b.get('remote_path'):await asyncio.to_thread(disk.remove_generated,b['remote_path'])
            artifact=rows[0]['name'] if b['direction']=='workshop' else 'Полароид-ДТФ.png' if b['direction']=='dtf' else 'Полароид.zip'
            if b['direction']=='workshop':
                archive=self.q.path(rows[0])
                def verify_original():
                    with archive.open('rb') as file:
                        if archive.stat().st_size!=rows[0]['size'] or hashlib.file_digest(file,'sha256').hexdigest()!=rows[0]['sha256']:raise UserError('Исходник мастерской изменился.')
                await asyncio.to_thread(verify_original)
            elif b['direction']=='dtf':
                review=self.dtf_review.get(bid)
                if review and review['approved'] and review['fingerprint']==self.dtf_review.fingerprint(bid):
                    archive=await asyncio.to_thread(self.dtf_review.artifact,bid)
                else:
                    archive=await asyncio.to_thread(build_sheet,self.q,bid,self.cards.thread_callback('batch:'+bid,chat,title,'2/4 · Формирование холста…'))
                    if self.dtf_review.prepare(bid,archive,chat):
                        await self.dtf_review.show(bid)
                        await self.cards.update('batch:'+bid,chat,title,'👀 Предпросмотр готов. Автоотправка через 5 минут. «Исправить макет» остановит таймер.',force=True)
                    return
            else:archive=await asyncio.to_thread(build_archive,self.q,bid,self.cards.thread_callback('batch:'+bid,chat,title,'2/4 · Архивирование…'))
            remote=f'disk:/Cloudshop-Print/{bid}_{uuid.uuid4().hex}/{artifact}'
            if not self.q.transition(bid,'packing','uploading',remote_path=remote):return
            await self.cards.update('batch:'+bid,chat,title,'3/4 · Загружаем на Яндекс Диск…',force=True)
            link=await asyncio.to_thread(disk.upload,archive,remote,self.cards.thread_callback('batch:'+bid,chat,title,'3/4 · Загружаем на Яндекс Диск…'))
            if not self.q.transition(bid,'uploading','ready',link=link):
                await asyncio.to_thread(disk.remove_generated,remote);return
            b=self.q.batch(bid)
            await self.cards.update('batch:'+bid,chat,title,'4/4 · Файлы на Диске. Отправляем письмо…',force=True)
            # Login happens before the irreversible boundary; deletion is still possible here.
            smtp=await asyncio.to_thread(smtp_connect,self.c)
            try:
                if b['direction']=='dtf':b['layout_description']=self.q.setting('dtf_layout:'+bid)
                msg=email_for(self.c,b,rows)
                if not self.q.accept_smtp(bid):return
                try:
                    await asyncio.to_thread(smtp.send_message,msg)
                except (smtplib.SMTPRecipientsRefused,smtplib.SMTPSenderRefused,smtplib.SMTPDataError):
                    self.q.transition(bid,'submitting','collecting',error='Почтовый сервер отказал в отправке. Заказ сохранён.')
                    self.q.set_setting('retry_at:'+bid,time.time()+600)
                    self.log('Почтовый сервер отказал в отправке. Будет повтор через 10 минут.')
                    self.monitor.failure(bid,'Почтовый сервер отказал в отправке.')
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
            self.q.set_setting('retry_at:'+bid,time.time()+600)
            self.log(reason+' Повтор через 10 минут; файлы сохранены.')
            self.monitor.failure(bid,reason)

        current=self.q.batch(bid)
        stage={'sent':f'✅ Заказ отправлен. Файлов: {len(rows)}.','uncertain':'⚠️ Результат письма не подтверждён. Проверьте почту перед повтором.','collecting':'⏳ Не удалось завершить. Файлы сохранены, повтор через 10 минут.','invalidated':'Состав изменился. Заказ будет пересобран.'}.get(current['state'],'Обработка: '+current['state'])
        buttons=None
        if current.get('link') and current['state']=='sent':
            from telethon import Button
            buttons=[[Button.url('Открыть заказ',current['link'])]]
        await self.cards.update('batch:'+bid,chat,title,stage,buttons=buttons,force=True)

    async def notify(self):
        owner=self.q.setting('owner')
        if not owner:return
        for b in self.q.pending_notifications():
            if b['state']=='local_saved':
                complete=True
                for chat in {r['chat'] for r in self.q.batch_files(b['id'])}|self.monitor.targets():
                    if self.q.notice_done(b['id'],chat):continue
                    try:
                        await self.client.send_message(chat,'30×40: файл '+self.q.batch_files(b['id'])[0]['name']+' сохранён на компьютере с принтером. Уведомление в Клаудшопе создано. Печать запускает сотрудник.',parse_mode=None)
                        self.q.finish_notice(b['id'],chat)
                    except Exception:complete=False
                if complete:self.q.mark_notified(b['id'])
                continue
            if b['state'] in ('manual','manual_sent','uncertain'):
                if b['state']=='uncertain':
                    for chat in self.monitor.targets():
                        if not self.q.notice_done(b['id'],chat):
                            await self.client.send_message(chat,'Почтовый сервер не вернул результат отправки. Проверьте почту перед повтором, чтобы не отправить заказ дважды.',parse_mode=None);self.q.finish_notice(b['id'],chat)
                self.q.mark_notified(b['id']);continue
            if b['state']=='sent':
                text=f'Заказ отправлен на {b["recipient"]}.\nФайлов: {len(self.q.batch_files(b["id"]))}.\nАрхив: {b["link"]}\nПисьмо отправлено.'
                if b['direction']=='masterphoto':text=f'Мастерфото: визитки отправлены вложениями на {b["recipient"]}. Файлов: {len(self.q.batch_files(b["id"]))}.'
                if b['direction']=='dtf':text=text.replace('Архив:','Холст ДТФ:')+'\n'+self.q.setting('dtf_layout:'+b['id'])
                chats={r['chat'] for r in self.q.batch_files(b['id'])}|self.monitor.targets()
            else:
                text='Не удалось подтвердить отправку письма. Проверьте ящик и окно программы на основном компьютере. Автоматический повтор остановлен, чтобы не отправить заказ дважды.'
                chats=self.monitor.targets()
            complete=True
            for chat in chats:
                if self.q.notice_done(b['id'],chat):continue
                notice=text if chat in self.monitor.targets() or b['state']!='sent' else f'Заказ отправлен. Файлов в отправке: {len(self.q.batch_files(b["id"]))}. Письмо принято почтовым сервером.'
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

    async def schedule_loop(self,direction='wideformat'):
        while self.running:
            try:
                prefix='dtf_' if direction=='dtf' else ''
                if direction in ('workshop','photo30'):
                    ready=bool(self.c.get('bridge_token')) if direction=='photo30' else bool(self.recipient(direction))
                    if ready:self.q.claim_immediate(self.recipient(direction),time.time(),direction)
                elif direction!='masterphoto' and self.q.setting(prefix+'automatic','0')=='1' and self.recipient(direction):self.q.claim(self.recipient(direction),time.time(),direction=direction)
                b=self.q.active_batch(direction)
                if b:await self.process_batch(b)
            except asyncio.CancelledError:raise
            except Exception:self.log('Не удалось выполнить проверку очереди. Повторим через 10 секунд.')
            await asyncio.sleep(10)

    async def watch_loop(self):
        while self.running:
            try:
                await self.notify()
                await self.handoff.cleanup_links(self)
                await self.monitor.check_delays()
                await self.monitor.notify(self.client)
                await self.monitor.check_space(self.c)
            except asyncio.CancelledError:raise
            except Exception:self.log('Проверка задержек ожидает восстановления связи.')
            await asyncio.sleep(10)

    async def run(self):
        from telethon import TelegramClient,events
        self.loop=asyncio.get_running_loop()
        await asyncio.to_thread(check_dedicated_bot,self.c['bot_token'])
        if not self.running:return
        # Only a bot token is used. No personal Telegram session or phone login.
        self.client=TelegramClient(str(self.q.root/'telegram-bot'),int(self.c['api_id']),self.c['api_hash'],catch_up=True)
        self.client.add_event_handler(self.on_message,events.NewMessage(incoming=True))
        self.client.add_event_handler(self.on_callback,events.CallbackQuery())
        try:
            await self.client.connect()
            if not self.running:return
            if not await self.client.is_user_authorized():
                await self.client.sign_in(bot_token=self.c['bot_token'])
            me=await self.client.get_me()
            if str(me.id)!=self.c['bot_token'].split(':')[0]:raise UserError('Токен изменился. Остановите программу и обратитесь за переносом сессии; не удаляйте очередь.')
            if self.c.get('bot_username') and (me.username or '').lower()!=self.c['bot_username'].lstrip('@').lower():raise UserError('Этот токен относится к другому боту. Нужен @perezakazi_bot.')
            if not me.bot:raise UserError('Нужен отдельный бот, а не личный аккаунт Telegram.')
            self.log('Бот подключён: @'+str(me.username))
            await self.client.catch_up()
            self.tasks=[asyncio.create_task(self.vpn.run()),asyncio.create_task(self.download_loop()),asyncio.create_task(self.schedule_loop()),asyncio.create_task(self.schedule_loop('dtf')),asyncio.create_task(self.schedule_loop('workshop')),asyncio.create_task(self.schedule_loop('photo30')),asyncio.create_task(self.schedule_loop('masterphoto')),asyncio.create_task(self.local_delivery.status_loop()),asyncio.create_task(self.features.broadcast_loop(self)),asyncio.create_task(self.watch_loop())]
            await self.client.run_until_disconnected()
        finally:
            self.running=False
            for task in self.tasks:task.cancel()
            await asyncio.gather(*self.tasks,return_exceptions=True)
            if self.client.is_connected():await self.client.disconnect()
            self.log('Обработчик остановлен. Очередь сохранена на компьютере.')
