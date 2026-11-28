"""Durable DTF proof window and byte-preserving replacement of the final sheet."""
import asyncio
import hashlib
import json
import math
import os
import struct
import time
import uuid
from pathlib import Path
from PIL import Image
from core import MAX_BYTES,UserError
from dtf_layout import pixels

class DtfReview:
 def __init__(self,worker):
  self.w=worker;self.q=worker.q
  with self.q.lock,self.q.db:
   self.q.db.execute('''create table if not exists dtf_reviews(
    batch text primary key references batches(id),revision integer not null,chat integer not null,
    fingerprint text not null,path text not null,sha text not null,width integer,height integer,
    deadline real,editor integer,approved integer not null default 0,noticed integer not null default 0,
    uploading integer not null default 0,replacement integer not null default 0)''')
   self.q.db.execute('create table if not exists dtf_replacement_messages(chat integer,message integer,batch text,accepted integer not null default 0,primary key(chat,message))')
   self.q.db.execute('update dtf_reviews set uploading=0')
 def get(self,bid):
  with self.q.lock:
   row=self.q.db.execute('select * from dtf_reviews where batch=?',(bid,)).fetchone()
   return dict(row) if row else None
 def fingerprint(self,bid):
  rows=self.q.batch_files(bid)
  return hashlib.sha256(json.dumps([(r['id'],r['sha256'],r['copies']) for r in rows]).encode()).hexdigest()
 def checked(self,bid,revision,uid):
  if not self.q.user(uid):raise UserError('Сначала подключитесь как сотрудник.')
  row=self.get(bid);batch=self.q.batch(bid)
  if not row or not batch or batch['direction']!='dtf' or row['revision']!=revision or row['fingerprint']!=self.fingerprint(bid):raise UserError('Этот предпросмотр устарел. Откройте актуальное сообщение с предпросмотром ДТФ.')
  if batch['state'] not in ('review','editing'):raise UserError('Отправка уже началась или завершена. Заменить макет сейчас нельзя.')
  return row,batch
 def artifact(self,bid):
  row=self.get(bid)
  if not row or row['fingerprint']!=self.fingerprint(bid):return None
  path=self.q.root/'archives'/bid/row['path']
  if not path.is_file():raise UserError('Готовый холст не найден. Проверьте папку данных программы.')
  with path.open('rb') as source:digest=hashlib.file_digest(source,'sha256').hexdigest()
  if digest!=row['sha']:raise UserError('Готовый холст изменился на диске. Загрузите исправленный PNG через «Исправить макет».')
  return path
 def prepare(self,bid,path,chat):
  with path.open('rb') as source:
   header=source.read(24)
   if header[:8]!=b'\x89PNG\r\n\x1a\n':raise UserError('Готовый холст должен быть PNG.')
   width,height=struct.unpack('>II',header[16:24]);source.seek(0);sha=hashlib.file_digest(source,'sha256').hexdigest()
  fingerprint=self.fingerprint(bid)
  with self.q.lock,self.q.db:
   batch=self.q.batch(bid)
   if batch['state']!='packing':return False
   old=self.get(bid);revision=(old['revision']+1) if old else 1
   self.q.db.execute('''insert into dtf_reviews(batch,revision,chat,fingerprint,path,sha,width,height)
    values(?,?,?,?,?,?,?,?) on conflict(batch) do update set revision=excluded.revision,chat=excluded.chat,
    fingerprint=excluded.fingerprint,path=excluded.path,sha=excluded.sha,width=excluded.width,height=excluded.height,
    deadline=null,editor=null,approved=0,noticed=0,uploading=0,replacement=0''',(bid,revision,chat,fingerprint,path.name,sha,width,height))
   self.q.db.execute("update batches set state='review',error=null where id=?",(bid,))
  return True
 def buttons(self,row):
  from telethon import Button
  base=f'dtf:{row["batch"]}:{row["revision"]}:'
  return [[Button.inline('⬇️ Скачать PNG',(base+'get').encode())],
          [Button.inline('✏️ Исправить макет',(base+'edit').encode()),Button.inline('🚀 Отправить сейчас',(base+'send').encode())]]
 async def show(self,bid,chat=None):
  row=self.get(bid);batch=self.q.batch(bid)
  if not row or batch['state'] not in ('review','editing'):raise UserError('Сейчас нет готового макета, ожидающего проверки.')
  chat=chat or row['chat'];path=await asyncio.to_thread(self.artifact,bid)
  description=f'ДТФ · {row["width"]/300*2.54:.2f} × {row["height"]/300*2.54:.2f} см · 300 dpi.'
  if batch['state']=='editing':
   from telethon import Button
   actions=[[Button.inline('⬇️ Скачать текущий PNG',f'dtf:{bid}:{row["revision"]}:get'.encode())]]
   if chat==row['editor']:actions.append([Button.inline('Вернуть текущий макет',f'dtf:{bid}:{row["revision"]}:resume'.encode())])
   await self.w.client.send_message(chat,description+'\n✏️ Макет исправляется сотрудником. Автоотправка приостановлена. Загрузите готовый PNG документом в этот бот.',buttons=actions,parse_mode=None);return
  remaining=max(0,math.ceil((row['deadline']-time.time())/60)) if row['deadline'] else 5
  text=description+f'\nПроверьте расположение принтов. Автоматическая отправка примерно через {remaining} мин.\nЧтобы остановить таймер и заменить холст, нажмите «Исправить макет».'
  if row['replacement']:text='✅ Исправленный макет принят без повторной раскладки.\n'+text
  preview=path.with_suffix('.preview.png')
  if preview.is_file():await self.w.client.send_file(chat,str(preview),caption=text,buttons=self.buttons(row))
  else:await self.w.client.send_message(chat,text,buttons=self.buttons(row),parse_mode=None)
  with self.q.lock,self.q.db:
   self.q.db.execute('update dtf_reviews set noticed=1,deadline=coalesce(deadline,?) where batch=? and revision=? and exists(select 1 from batches where id=? and state=\'review\')',(time.time()+300,bid,row['revision'],bid))
 async def tick(self,bid):
  row=self.get(bid);batch=self.q.batch(bid)
  if not row or batch['state']!='review':return
  if not row['noticed']:await self.show(bid);row=self.get(bid)
  with self.q.lock,self.q.db:
   if row['deadline'] and row['deadline']<=time.time():
    changed=self.q.db.execute("update batches set state='collecting' where id=? and state='review'",(bid,)).rowcount
    if changed:
     self.q.db.execute('update dtf_reviews set approved=1 where batch=?',(bid,));self.q.set_setting('retry_at:'+bid,'0')
 def editing_for(self,uid):
  with self.q.lock:
   r=self.q.db.execute("select r.* from dtf_reviews r join batches b on b.id=r.batch where r.editor=? and b.state='editing'",(uid,)).fetchone()
   return dict(r) if r else None
 async def callback(self,event):
  _,bid,revision,action=event.data.decode().split(':');revision=int(revision);uid=event.sender_id
  with self.q.lock:
   row,batch=self.checked(bid,revision,uid)
   if action=='edit':
    self.w.choose(uid,'dtf')
    with self.q.db:
     if batch['state']=='editing' and row['editor']!=uid:raise UserError('Этот макет уже исправляет другой сотрудник.')
     existing=self.editing_for(uid)
     if existing and existing['batch']!=bid:raise UserError('Сначала завершите исправление другого макета.')
     self.q.db.execute("update batches set state='editing' where id=?",(bid,))
     self.q.db.execute('update dtf_reviews set editor=?,deadline=null,approved=0 where batch=?',(uid,bid))
   elif action=='send':
    if batch['state']=='editing':raise UserError('Макет ещё исправляется. Загрузите готовый PNG или верните текущий макет.')
    with self.q.db:
     self.q.db.execute('update dtf_reviews set approved=1 where batch=?',(bid,));self.q.set_setting('retry_at:'+bid,'0');self.q.db.execute("update batches set state='collecting' where id=?",(bid,))
   elif action not in ('get','resume'):raise UserError('Неизвестное действие.')
   if action=='resume':
    if batch['state']!='editing' or row['editor']!=uid or row['uploading']:raise UserError('Сначала завершите загрузку или обратитесь к сотруднику, который исправляет макет.')
    with self.q.db:
     self.q.db.execute("update batches set state='review' where id=?",(bid,));self.q.db.execute('update dtf_reviews set editor=null,deadline=null,noticed=0 where batch=?',(bid,))
  await event.answer('Автоотправка остановлена.' if action=='edit' else 'Отправка подтверждена.' if action=='send' else '')
  if action in ('get','edit'):
   path=await asyncio.to_thread(self.artifact,bid)
   if action=='edit':
    from dtf_psd import export_psd
    await self.w.reply(event,'Готовлю Photoshop-макет: каждая копия принта будет отдельным слоем. Отправка на паузе.')
    path=await asyncio.to_thread(export_psd,self.q,bid,path)
   await self.w.client.send_file(uid,str(path),force_document=True,caption='Макет для Photoshop со слоями, 300 dpi.' if action=='edit' else 'Готовый PNG 300 dpi.')
  if action=='edit':
   from telethon import Button
   await self.w.reply(event,'✏️ Автоматическая отправка этого заказа остановлена. Откройте PSD/PSB в Photoshop, исправьте слои и отправьте готовый PNG сюда документом. После проверки он сразу уйдёт партнёру.\nХолст: ширина 56 см, длина не меньше 50 см, 300 dpi, прозрачный фон. Сам файл отправится без новой раскладки.',[[Button.inline('Вернуть текущий макет',f'dtf:{bid}:{revision}:resume'.encode())]])
  if action=='resume':await self.show(bid)
 async def handle_document(self,event):
  if self.w.direction(event.sender_id)!='dtf':return False
  with self.q.lock:
   intent=self.q.db.execute('select * from dtf_replacement_messages where chat=? and message=?',(event.chat_id,event.id)).fetchone()
  current=self.editing_for(event.sender_id)
  if intent and (intent['accepted'] or not current or current['batch']!=intent['batch']):
   await self.w.reply(event,'Этот файл уже обработан как замена готового ДТФ-холста. Он не будет добавлен отдельным принтом.');return True
  return await self.receive(event) if current else False
 async def receive(self,event):
  row=self.editing_for(event.sender_id)
  if not row:return False
  if not event.document:return False
  with self.q.lock,self.q.db:self.q.db.execute('insert or ignore into dtf_replacement_messages(chat,message,batch) values(?,?,?)',(event.chat_id,event.id,row['batch']))
  name=event.file.name or '';size=event.file.size or 0
  if not name.lower().endswith('.png') or not 0<size<=MAX_BYTES:raise UserError('Вы исправляете макет ДТФ. Отправьте исправленный PNG документом, до 500 МБ. Для обычной загрузки выберите нужный раздел в меню.')
  with self.q.lock,self.q.db:
   self.checked(row['batch'],row['revision'],event.sender_id)
   if self.q.db.execute('update dtf_reviews set uploading=1 where batch=? and uploading=0',(row['batch'],)).rowcount!=1:raise UserError('Предыдущий готовый PNG ещё загружается. Дождитесь результата.')
  directory=self.q.root/'archives'/row['batch'];temp=directory/(uuid.uuid4().hex+'.replacement.part');destination=directory/('Готовый-ДТФ-'+uuid.uuid4().hex+'.png')
  accepted=False
  try:
   await self.w.reply(event,'Получаю исправленный ДТФ-холст. Автоотправка остаётся на паузе.')
   key='dtf-replacement:'+row['batch']
   async def progress(done,total):
    await self.w.cards.update(key,event.chat_id,'ДТФ · исправленный макет','Загрузка файла…',done,total)
   await self.w.cards.update(key,event.chat_id,'ДТФ · исправленный макет','Получаю файл…',force=True)
   await self.w.client.download_media(event.message,file=str(temp),progress_callback=progress)
   await self.w.cards.update(key,event.chat_id,'🔎 ДТФ · проверка файла','Проверяю PNG, размеры, разрешение и прозрачность… Автоотправка на паузе.',force=True)
   if not temp.is_file() or temp.stat().st_size!=size:raise UserError('Готовый PNG загрузился не полностью. Повторите загрузку; отправка остаётся на паузе.')
   width,height,sha=await asyncio.to_thread(validate_ready,temp)
   await self.w.cards.update(key,event.chat_id,'🔎 ДТФ · проверка файла','Готовлю предпросмотр исправленного холста…',force=True)
   await asyncio.to_thread(make_preview,temp,destination.with_suffix('.preview.png'))
   with self.q.lock,self.q.db:
    current,batch=self.checked(row['batch'],row['revision'],event.sender_id)
    if current['editor']!=event.sender_id:raise UserError('Макет уже изменён другим сотрудником.')
    os.replace(temp,destination)
    self.q.db.execute('''update dtf_reviews set revision=revision+1,path=?,sha=?,width=?,height=?,
      deadline=null,editor=null,approved=1,noticed=1,uploading=0,replacement=1,chat=? where batch=?''',(destination.name,sha,width,height,event.sender_id,row['batch']))
    self.q.db.execute("update batches set state='collecting',error=null where id=?",(row['batch'],))
    self.q.db.execute('update dtf_replacement_messages set accepted=1 where chat=? and message=?',(event.chat_id,event.id))
    self.q.set_setting('dtf_layout:'+row['batch'],f'{width/300*2.54:.2f} × {height/300*2.54:.2f} см; готовый макет сотрудника, без повторной раскладки')
   self.q.set_setting('retry_at:'+row['batch'],'0')
   await self.w.cards.update(key,event.chat_id,'✅ ДТФ · проверка завершена','Готовый холст принят. Передаю на отправку партнёру.',force=True)
   accepted=True;await self.w.reply(event,'Исправленный макет принят. Отправляю партнёру без повторной раскладки.');return True
  except Exception:
   await self.w.cards.update('dtf-replacement:'+row['batch'],event.chat_id,'❌ ДТФ · файл не принят','Проверка или загрузка не завершена. Автоотправка остаётся на паузе.',force=True)
   raise
  finally:
   temp.unlink(missing_ok=True)
   if not accepted:destination.with_suffix('.preview.png').unlink(missing_ok=True)
   with self.q.lock,self.q.db:self.q.db.execute('update dtf_reviews set uploading=0 where batch=?',(row['batch'],))


def validate_ready(path):
 try:
  with Image.open(path) as image:
   if image.format!='PNG':raise UserError('Файл должен быть настоящим PNG.')
   width,height=image.size;dpi=image.info.get('dpi',())
   if width!=pixels(56) or height<pixels(50):raise UserError('Холст должен быть шириной 56 см и длиной не меньше 50 см при 300 dpi. Размеры автоматически не изменяются.')
   if len(dpi)<2 or any(not math.isfinite(float(v)) or abs(float(v)-300)>1 for v in dpi[:2]):raise UserError('Сохраните готовый PNG с разрешением 300 dpi по обеим осям.')
   if 'A' not in image.getbands() and 'transparency' not in image.info:raise UserError('Сохраните PNG с прозрачностью, без фонового слоя.')
   image.verify()
  with Path(path).open('rb') as source:sha=hashlib.file_digest(source,'sha256').hexdigest()
  return width,height,sha
 except UserError:raise
 except Exception:raise UserError('Не удалось проверить готовый PNG. Пересохраните его в Photoshop и загрузите документом ещё раз.') from None

def make_preview(path,destination):
 with Image.open(path) as image:
  image.thumbnail((640,1600));image.save(destination,'PNG')
