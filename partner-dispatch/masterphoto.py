"""Durable per-employee business-card orders, one/two originals sent as attachments."""
import asyncio,hashlib,math,smtplib,time,uuid
from email.message import EmailMessage
from email.utils import formatdate
from PIL import Image
from core import UserError
from services import smtp_connect
QUANTITIES=(110,310,510,1010)
SIDES={'Односторонние визитки':1,'Двусторонние визитки':2}
INSTRUCTIONS='''📘 Инструкция по отправке файлов

🖨 Широкоформатная печать
Выберите раздел → «Загрузить файл». Отправляйте TIF/TIFF документом, без сжатия. Количество копий не вводится. Файлы уходят общей очередью по расписанию или после «Отправить сейчас» и подтверждения. Перед отправкой проверьте список файлов.

👕 ДТФ-печать
Отправьте PNG, PSD или TIF/TIFF в физическом размере, 300 dpi. Прозрачность сохранится, если она есть в исходнике. По умолчанию 1 копия; при необходимости измените через «Количество копий».
Перед отправкой бот пришлёт предпросмотр. Через 5 минут отправит автоматически. «Исправить макет» остановит таймер и выдаст PSD/PSB со слоями. Исправьте в Photoshop, сохраните готовый прозрачный PNG 300 dpi: ширина 56 см, длина от 50 см. Отправьте его документом в разделе ДТФ. После проверки он сразу уйдёт партнёру без повторной раскладки.

🛠 Мастерская
Документы любого формата. Каждый файл сразу отправляется на почту ссылкой на оригинал, без архива и расписания.

💳 Мастерфото — визитки
Выберите односторонние (1 JPG) или двусторонние (2 JPG: лицевая и оборотная стороны). Размер каждого 9,4 × 5,4 см, 300 dpi, без сжатия мессенджером. После загрузки нажмите тираж 110 / 310 / 510 / 1010 шт. Для двусторонних это количество готовых визиток, а не сумма сторон. Файлы сразу отправляются вложениями в одном письме.

«Загруженные файлы» показывает текущую очередь. Неподходящие файлы отклоняются. Не запускайте бота одновременно на двух компьютерах.'''

def validate_card(path):
 try:
  with Image.open(path) as im:
   if im.format!='JPEG':raise UserError('Для визиток нужен настоящий JPG/JPEG.')
   dpi=im.info.get('dpi',())
   if len(dpi)<2 or any(not math.isfinite(float(v)) or abs(float(v)-300)>1 for v in dpi[:2]):raise UserError('Визитка должна быть сохранена с разрешением 300 dpi.')
   expected=(round(9.4/2.54*300),round(5.4/2.54*300))
   if not any(all(abs(a-b)<=1 for a,b in zip(im.size,sz)) for sz in (expected,expected[::-1])):raise UserError('Размер визитки должен быть 9,4 × 5,4 см при 300 dpi (1110 × 638 пикселей).')
   im.verify()
 except UserError:raise
 except Exception:raise UserError('Не удалось прочитать JPG. Пересохраните визитку и отправьте документом.') from None

class Masterphoto:
 def __init__(self,w):
  self.w=w;self.q=w.q
  with self.q.lock,self.q.db:
   self.q.db.execute('create table if not exists business_orders(id text primary key,uid integer,sides integer,quantity integer,batch text unique,created real)')
   self.q.db.execute('create table if not exists business_files(file integer primary key,order_id text references business_orders(id))')
 def current(self,uid):
  with self.q.lock:
   r=self.q.db.execute('select * from business_orders where uid=? and batch is null order by created desc limit 1',(uid,)).fetchone();return dict(r) if r else None
 def files(self,oid):
  with self.q.lock:return [dict(r) for r in self.q.db.execute("select f.* from files f join business_files bf on bf.file=f.id where bf.order_id=? and f.state!='cancelled' order by f.id",(oid,))]
 async def prompt(self,event):
  from telethon import Button
  await self.w.reply(event,'Выберите вид визиток. Затем загрузите оригиналы JPG, 9,4 × 5,4 см, 300 dpi.',[[Button.text(k,resize=True,persistent=True)] for k in SIDES]+[[Button.text('Инструкция по отправке файлов',resize=True,persistent=True),Button.text('Главное меню',resize=True,persistent=True)]])
 async def quantities(self,order,chat):
  from telethon import Button
  rows=self.files(order['id'])
  if len(rows)!=order['sides'] or any(r['state']!='ready' for r in rows):return
  await self.w.client.send_message(chat,'Все стороны сохранены. Выберите количество готовых визиток:',buttons=[[Button.inline(str(q)+' шт.',f'card:{order["id"]}:{q}'.encode()) for q in QUANTITIES[:2]],[Button.inline(str(q)+' шт.',f'card:{order["id"]}:{q}'.encode()) for q in QUANTITIES[2:]]],parse_mode=None)
 async def handle(self,event,text):
  uid=event.sender_id
  if text in SIDES:
   old=self.current(uid)
   if old and self.files(old['id']):raise UserError('Сначала завершите текущий заказ визиток или удалите его файлы через «Удалить файл».')
   with self.q.lock,self.q.db:
    self.q.db.execute("update business_orders set batch='cancelled:'||id where uid=? and batch is null",(uid,))
    oid=uuid.uuid4().hex;self.q.db.execute('insert into business_orders(id,uid,sides,created) values(?,?,?,?)',(oid,uid,SIDES[text],time.time()))
   await self.w.reply(event,f'{text}: отправьте {SIDES[text]} файл(а) JPG документом. Первый файл — лицо, второй — оборот. Затем выберите тираж.');return True
  if event.document:
   order=self.current(uid)
   if not order:await self.prompt(event);return True
   if len(self.files(order['id']))>=order['sides']:raise UserError('Все стороны уже добавлены. Дождитесь проверки и выберите тираж; следующий заказ начните кнопкой вида визиток.')
   if (event.file.size or 0)>10*1024*1024:raise UserError('Один JPG визитки должен быть не больше 10 МБ для отправки вложением.')
   with self.q.lock:
    r=self.q.add(event.chat_id,event.id,uid,event.file.name or '',event.file.size or 0,event.date.timestamp(),direction='masterphoto')
    with self.q.db:self.q.db.execute('insert or ignore into business_files values(?,?)',(r['id'],order['id']))
   self.w.cached[(r['chat'],r['message'])]=event.message
   await self.w.reply(event,'Получаю сторону визитки. После проверки всех сторон предложу тираж.');return True
  if text in ('Загрузить файл','/cards'):
   order=self.current(uid)
   if order and len(self.files(order['id']))==order['sides']:await self.quantities(order,event.chat_id)
   else:await self.prompt(event)
   return True
  return False
 async def downloaded(self,r):
  with self.q.lock:o=self.q.db.execute('select o.* from business_orders o join business_files f on f.order_id=o.id where f.file=?',(r['id'],)).fetchone()
  if o:await self.quantities(dict(o),r['chat'])
 async def callback(self,event):
  _,oid,qty=event.data.decode().split(':');qty=int(qty)
  with self.q.lock,self.q.db:
   o=self.q.db.execute('select * from business_orders where id=?',(oid,)).fetchone()
   if not o or o['uid']!=event.sender_id or not self.q.user(event.sender_id):raise UserError('Этот заказ принадлежит другому сотруднику.')
   if o['batch']:await event.answer('Тираж уже принят. Повторного письма не будет.');return
   rows=self.files(oid)
   if qty not in QUANTITIES or len(rows)!=o['sides'] or any(r['state']!='ready' for r in rows):raise UserError('Сначала загрузите все стороны визитки и дождитесь проверки.')
   recipient=self.w.c.get('masterphoto_recipient','')
   if not recipient:raise UserError('Укажите почту «Мастерфото» в настройках программы и сохраните.')
   bid=uuid.uuid4().hex
   self.q.db.execute("insert into batches(id,state,created,recipient,direction,test_mode,generation) values(?,'collecting',?,?,'masterphoto',0,0)",(bid,time.time(),recipient))
   self.q.db.executemany('update files set batch=? where id=?',[(bid,r['id']) for r in rows]);self.q.db.execute('update business_orders set quantity=?,batch=? where id=?',(qty,bid,oid));self.q.set_setting('batch_progress:'+bid,event.chat_id)
  await event.answer('Тираж принят.');await event.edit(f'Заказ: {qty} визиток, {o["sides"]} сторона(ы). Отправляю вложениями одним письмом.',buttons=None)
 def email(self,b,rows):
  with self.q.lock:o=self.q.db.execute('select * from business_orders where batch=?',(b['id'],)).fetchone()
  if not o or len(rows)!=o['sides']:raise UserError('Состав заказа визиток изменён. Отправка остановлена: загрузите заказ заново.')
  msg=EmailMessage();msg['From']=self.w.c['sender'];msg['To']=b['recipient'];msg['Date']=formatdate(localtime=False);msg['Message-ID']=f'<cloudshop-print-{b["id"]}@{self.w.c["sender"].split("@")[-1]}>';msg['Subject']=f'Полароид · Визитки · {o["quantity"]} шт. · {b["id"][:8]}'
  side='односторонние' if o['sides']==1 else 'двусторонние'
  msg.set_content(f'Здравствуйте! Распечатайте, пожалуйста, визитки ({side}), количество {o["quantity"]} шт. Счёт на оплату отправьте на эту же почту. Спасибо. Это письмо отправлено автоматически. Если есть проблемы с файлом, пожалуйста, напишите нам.')
  for i,r in enumerate(rows):
   path=self.q.path(r);data=path.read_bytes()
   if len(data)!=r['size'] or hashlib.sha256(data).hexdigest()!=r['sha256']:raise UserError('Исходник визитки изменён на компьютере.')
   validate_card(path);msg.add_attachment(data,maintype='image',subtype='jpeg',filename=('Лицевая-' if i==0 else 'Оборотная-')+r['name'])
  return msg
 async def process(self,b):
  bid=b['id'];chat=int(self.q.setting('batch_progress:'+bid,self.q.setting('owner','0')) or 0);key='batch:'+bid
  if b['state']=='invalidated':
   self.q.transition(bid,'invalidated','cancelled',error='Сторона удалена: создайте заказ визиток заново.');return
  if float(self.q.setting('retry_at:'+bid,'0'))>time.time():return
  if b['recipient']!=self.w.c.get('masterphoto_recipient',''):return
  if not self.q.transition(bid,'collecting','packing'):return
  try:
   await self.w.cards.update(key,chat,'Мастерфото · визитки','Проверяю стороны и готовлю письмо с вложениями…',force=True)
   msg=await asyncio.to_thread(self.email,b,self.q.batch_files(bid));smtp=await asyncio.to_thread(smtp_connect,self.w.c)
   try:
    if not self.q.transition(bid,'packing','ready'):return
    if not self.q.accept_smtp(bid):return
    try:await asyncio.to_thread(smtp.send_message,msg)
    except (smtplib.SMTPRecipientsRefused,smtplib.SMTPSenderRefused,smtplib.SMTPDataError):self.q.transition(bid,'submitting','collecting',error='Почта отказала в отправке.');self.q.set_setting('retry_at:'+bid,time.time()+600)
    except Exception:self.q.transition(bid,'submitting','uncertain',error='Проверьте почту перед повтором: сервер не подтвердил отправку.')
    else:self.q.transition(bid,'submitting','sent',error=None)
   finally:smtp.close()
  except Exception as e:
   state=self.q.batch(bid)['state']
   if state in ('packing','ready'):self.q.transition(bid,state,'collecting',error=str(e) if isinstance(e,UserError) else 'Не удалось подготовить письмо.')
   self.q.set_setting('retry_at:'+bid,time.time()+600)
  state=self.q.batch(bid)['state']
  await self.w.cards.update(key,chat,'Мастерфото · визитки','✅ Письмо отправлено с оригиналами JPG.' if state=='sent' else '⚠️ Результат не подтверждён. Проверьте почту.' if state=='uncertain' else '⏳ Не отправлено. Файлы сохранены; повтор через 10 минут.',force=True)
