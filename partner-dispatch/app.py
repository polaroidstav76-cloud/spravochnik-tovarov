"""Windows 10/11 desktop launcher. Settings stay on the user's machine."""
from __future__ import annotations
import asyncio
import ctypes
import json
import platform
import tempfile
import urllib.parse
import os
import queue as threadqueue
import re
import secrets
import sys
import threading
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import messagebox,ttk,filedialog
import webbrowser
from core import Queue,UserError,MOSCOW,DIRECTIONS
from services import Settings,Disk,smtp_connect,check_dedicated_bot,protect
from handoff import Handoff
from worker import Worker
from wizard import Wizard

BASE=Path(__file__).resolve().parent
VERSION='0.5'
FIELDS=[('api_id','Telegram API ID',False),('api_hash','Telegram API hash',True),('bot_token','Токен отдельного бота',True),
        ('disk_client_id','ClientID приложения Яндекс Диска (для получения токена)',False),('disk_token','OAuth-токен Яндекс Диска',True),('sender','Яндекс Почта — отправитель',False),('smtp_password','Пароль приложения Яндекс Почты',True),
        ('recipient','Получатель (сначала тестовый)',False)]


def singleton():
    if os.name!='nt':return None
    from ctypes import wintypes
    lib=ctypes.WinDLL('kernel32',use_last_error=True)
    lib.CreateMutexW.argtypes=[ctypes.c_void_p,wintypes.BOOL,wintypes.LPCWSTR]
    lib.CreateMutexW.restype=wintypes.HANDLE
    handle=lib.CreateMutexW(None,False,'Local\\CloudshopWideformatDispatch')
    if ctypes.get_last_error()==183:raise UserError('Программа уже запущена. Откройте её окно на этом компьютере.')
    if not handle:raise UserError('Не удалось создать блокировку программы.')
    return handle


class App:
    def __init__(self,root):
        self.root=root;self.mutex=singleton()
        folder=Path(os.environ.get('LOCALAPPDATA',str(BASE/'data')))/'CloudshopPrintDispatch'
        self.settings=Settings(folder)
        self.c=self.settings.load()
        self.c.setdefault('bot_username','perezakazi_bot')
        self.c.setdefault('recipient','')
        self.c.setdefault('dtf_recipient',self.c.get('recipient',''))
        self.c.setdefault('sender','')
        self.c.setdefault('owner_code',secrets.token_urlsafe(18))
        self.c.setdefault('join_code',secrets.token_urlsafe(18))
        self.c.setdefault('responsible_code',secrets.token_urlsafe(18))
        self.q=Queue(folder);self.handoff=Handoff(self.q)
        self.messages=threadqueue.Queue();self.worker=None;self.thread=None
        root.title('Клаудшоп — заказы партнёрам · @perezakazi_bot');width=min(1040,root.winfo_screenwidth()-50);height=min(810,root.winfo_screenheight()-90)
        root.geometry(f'{width}x{height}');root.minsize(min(900,width),min(650,height))
        outer=ttk.Frame(root,padding=14);outer.pack(fill='both',expand=True)
        ttk.Label(outer,text='Заказы партнёрам · @perezakazi_bot',font=('Segoe UI',18,'bold')).pack(anchor='w')
        ttk.Label(outer,text='Широкоформатная печать · до 500 МБ · настраиваемое расписание МСК · ДТФ: прозрачный PNG 56 см, 300 dpi').pack(anchor='w',pady=(2,10))
        notebook=ttk.Notebook(outer);self.notebook=notebook;notebook.pack(fill='both',expand=True)
        setup=ttk.Frame(notebook,padding=12);main=ttk.Frame(notebook,padding=12)
        self.setup_tab=setup;self.main_tab=main
        notebook.add(main,text='Очередь и отправка');notebook.add(setup,text='Настройки')
        self.entries={}
        for i,(key,label,secret) in enumerate(FIELDS):
            ttk.Label(setup,text=label).grid(row=i,column=0,sticky='w',pady=7)
            entry=ttk.Entry(setup,width=66,show='•' if secret else '')
            entry.insert(0,str(self.c.get(key,'')));entry.grid(row=i,column=1,sticky='ew',padx=12,pady=7)
            self.entries[key]=entry
        setup.columnconfigure(1,weight=1)
        actions=ttk.Frame(setup);actions.grid(row=len(FIELDS),column=0,columnspan=2,sticky='w',pady=12)
        ttk.Button(actions,text='Сохранить черновик',command=self.save_partial).pack(side='left',padx=3)
        ttk.Button(actions,text='Проверить Диск и почту (без отправки)',command=self.check).pack(side='left',padx=3)
        ttk.Button(actions,text='Получить токен Диска',command=self.disk_oauth).pack(side='left',padx=3)
        ttk.Button(actions,text='Инструкция',command=self.help).pack(side='left',padx=3)
        ttk.Label(setup,text='Секреты сохраняются с шифрованием Windows DPAPI. В чат их присылать не нужно.\nСоздайте отдельного нового бота, не используйте бота сводки или закупок.\nПочта отправляет ссылку на ZIP. Любой получивший ссылку сможет скачать архив.',wraplength=850).grid(row=len(FIELDS)+1,column=0,columnspan=2,sticky='w',pady=10)
        links=ttk.Frame(setup);links.grid(row=len(FIELDS)+2,column=0,columnspan=2,sticky='w')
        for label,url in [('API Telegram','https://my.telegram.org/apps'),('BotFather','https://t.me/BotFather'),('Пароль почты','https://id.yandex.ru/security/app-passwords'),('Доступ к Диску','https://oauth.yandex.ru/client/new')]:
            ttk.Button(links,text=label,command=lambda u=url:webbrowser.open(u)).pack(side='left',padx=3)
        toolbar=ttk.Frame(main);toolbar.pack(fill='x')
        ttk.Button(toolbar,text='Запустить бота',command=self.start).pack(side='left',padx=3)
        ttk.Button(toolbar,text='Остановить',command=self.stop).pack(side='left',padx=3)
        ttk.Button(toolbar,text='Подключить сотрудников',command=self.pair).pack(side='left',padx=3)
        ttk.Button(toolbar,text='Открыть папку данных',command=lambda:os.startfile(self.q.root)).pack(side='left',padx=3)
        self.auto=tk.BooleanVar(value=self.q.setting('automatic','0')=='1')
        ttk.Checkbutton(main,text='Автоматическая отправка по расписанию включена',variable=self.auto,command=self.set_auto).pack(anchor='w',pady=4)
        schedule=ttk.Frame(main);schedule.pack(fill='x',pady=4)
        ttk.Label(schedule,text='Время МСК (ЧЧ:ММ):').pack(side='left')
        self.dispatch_time=tk.StringVar(value=self.q.setting('dispatch_time','18:00'))
        ttk.Entry(schedule,textvariable=self.dispatch_time,width=6).pack(side='left',padx=4)
        selected=self.q.setting('dispatch_days','0,1,2,3,4,5,6').split(',')
        self.dispatch_days=[]
        for index,label in enumerate(('Пн','Вт','Ср','Чт','Пт','Сб','Вс')):
            var=tk.BooleanVar(value=str(index) in selected);self.dispatch_days.append(var)
            ttk.Checkbutton(schedule,text=label,variable=var).pack(side='left')
        ttk.Button(schedule,text='Сохранить расписание',command=self.save_schedule).pack(side='left',padx=4)
        self.status=ttk.Label(main,text='Обработчик не запущен. Сначала заполните настройки.');self.status.pack(anchor='w')
        self.table=ttk.Treeview(main,columns=('id','name','state'),show='headings',height=8)
        for col,title,width in [('id','№',55),('name','Файл',570),('state','Состояние',240)]:
            self.table.heading(col,text=title);self.table.column(col,width=width)
        self.table.pack(fill='both',expand=True,pady=8)
        tools=ttk.Frame(main);tools.pack(fill='x')
        ttk.Button(tools,text='Отправить сейчас (вся очередь)',command=self.send).grid(row=0,column=0,sticky='w',padx=3,pady=2)
        ttk.Button(tools,text='Удалить выбранный файл',command=self.delete).grid(row=0,column=1,sticky='w',padx=3,pady=2)
        ttk.Button(tools,text='Проверить неопределённое письмо',command=self.uncertain).grid(row=1,column=0,sticky='w',padx=3,pady=2)
        ttk.Button(tools,text='Автозапуск при входе Windows',command=self.autostart).grid(row=1,column=1,sticky='w',padx=3,pady=2)
        verification=ttk.Frame(main);verification.pack(fill='x',pady=5)
        ttk.Button(verification,text='Тестовое письмо проверено',command=self.confirm_test).pack(side='left',padx=3)
        ttk.Button(verification,text='Отчёт без секретов',command=self.export_report).pack(side='left',padx=3)
        self.logs=tk.Text(main,height=5,state='disabled',wrap='word');self.logs.pack(fill='x',pady=8)
        ttk.Label(main,text='Файл принят только после ответа бота «Сохранён». Нельзя выключать или усыплять компьютер до завершения отправки.\nФайлы после выбранного времени ждут следующего дня отправки. Архивы и оригиналы автоматически не удаляются.',wraplength=900).pack(anchor='w')
        root.protocol('WM_DELETE_WINDOW',self.close)
        dtf=ttk.Frame(notebook,padding=12);notebook.add(dtf,text='ДТФ-печать')
        ttk.Label(dtf,text='Холст: ширина 56 см, рабочая область 55 см; высота от 50 см. Поля 5 мм.\nРазмеры принтов из DPI исходника. PNG RGB с прозрачностью, 300 dpi. Без зеркального отражения.',wraplength=850).pack(anchor='w',pady=8)
        receiver=ttk.Frame(dtf);receiver.pack(fill='x',pady=5)
        ttk.Label(receiver,text='Получатель ДТФ (сначала свой адрес):').pack(side='left')
        self.dtf_recipient=tk.StringVar(value=self.c.get('dtf_recipient',''))
        ttk.Entry(receiver,textvariable=self.dtf_recipient,width=40).pack(side='left',padx=5)
        ttk.Button(receiver,text='Сохранить почту',command=self.save_partial).pack(side='left')
        self.dtf_auto=tk.BooleanVar(value=self.q.setting('dtf_automatic','0')=='1')
        ttk.Checkbutton(dtf,text='Автоматическая отправка ДТФ включена',variable=self.dtf_auto,command=self.set_dtf_auto).pack(anchor='w',pady=5)
        dtf_schedule=ttk.Frame(dtf);dtf_schedule.pack(fill='x',pady=5)
        ttk.Label(dtf_schedule,text='Время МСК:').pack(side='left')
        self.dtf_time=tk.StringVar(value=self.q.setting('dtf_dispatch_time','12:00'))
        ttk.Entry(dtf_schedule,textvariable=self.dtf_time,width=6).pack(side='left',padx=4)
        self.dtf_days=[];selected=self.q.setting('dtf_dispatch_days','0,3').split(',')
        for index,label in enumerate(('Пн','Вт','Ср','Чт','Пт','Сб','Вс')):
            var=tk.BooleanVar(value=str(index) in selected);self.dtf_days.append(var)
            ttk.Checkbutton(dtf_schedule,text=label,variable=var).pack(side='left')
        ttk.Button(dtf_schedule,text='Сохранить расписание ДТФ',command=self.save_dtf_schedule).pack(side='left',padx=5)
        dtf_actions=ttk.Frame(dtf);dtf_actions.pack(fill='x',pady=8)
        ttk.Button(dtf_actions,text='Отправить ДТФ сейчас',command=self.send_dtf).pack(side='left',padx=4)
        ttk.Button(dtf_actions,text='Тестовое письмо ДТФ проверено',command=self.confirm_dtf_test).pack(side='left',padx=4)
        self.dtf_status=ttk.Label(dtf,text='');self.dtf_status.pack(anchor='w',pady=6)
        self.dtf_table=ttk.Treeview(dtf,columns=('name','copies','state'),show='headings',height=8)
        for key,label,width in [('name','Принт',480),('copies','Копий',80),('state','Состояние',220)]:
            self.dtf_table.heading(key,text=label);self.dtf_table.column(key,width=width)
        self.dtf_table.pack(fill='both',expand=True,pady=6)
        ttk.Label(dtf,text='Количество копий сотрудники задают в боте. Файл без DPI или многостраничный TIFF нужно пересохранить.\nПрозрачность исходников сохраняется; белый фон изображения не удаляется автоматически. Принты могут поворачиваться на 90° для экономии места.',wraplength=850).pack(anchor='w',pady=8)
        history=ttk.Frame(notebook,padding=12);notebook.add(history,text='История и уведомления')
        options=ttk.Frame(history);options.pack(fill='x')
        ttk.Label(options,text='Ответственный филиал:').grid(row=0,column=0,sticky='w')
        self.alert_branch=tk.StringVar(value=self.q.setting('alert_branch'))
        ttk.Entry(options,textvariable=self.alert_branch,width=32).grid(row=0,column=1,padx=5)
        ttk.Label(options,text='Предупреждать, если свободно менее (ГБ):').grid(row=1,column=0,sticky='w',pady=6)
        self.space_threshold=tk.StringVar(value=self.q.setting('space_threshold_gb','10'))
        ttk.Entry(options,textvariable=self.space_threshold,width=8).grid(row=1,column=1,sticky='w',padx=5)
        ttk.Button(options,text='Сохранить уведомления',command=self.save_alerts).grid(row=4,column=0,pady=6,sticky='w')
        self.download_delay=tk.StringVar(value=self.q.setting('download_delay_minutes','15'))
        self.send_delay=tk.StringVar(value=self.q.setting('send_delay_minutes','30'))
        for row,label,var in [(2,'Предупреждать о загрузке дольше (мин):',self.download_delay),(3,'Предупреждать об отправке дольше (мин):',self.send_delay)]:
            ttk.Label(options,text=label).grid(row=row,column=0,sticky='w',pady=3)
            ttk.Entry(options,textvariable=var,width=8).grid(row=row,column=1,sticky='w',padx=5)
        ttk.Label(history,text='Владелец получает уведомления всегда. Ответственный филиал подключается отдельной командой.\nБез интернета уведомления ожидают восстановления связи. Диск проверяется раз в час.',wraplength=850).pack(anchor='w',pady=6)
        self.space_status=ttk.Label(history,text='Свободное место ещё не проверено');self.space_status.pack(anchor='w')
        self.history_table=ttk.Treeview(history,columns=('date','direction','state','count','recipient'),show='headings',height=10)
        for key,label,width in [('date','Создано (МСК)',145),('direction','Направление',145),('state','Состояние',230),('count','Файлов',65),('recipient','Получатель',240)]:
            self.history_table.heading(key,text=label);self.history_table.column(key,width=width)
        self.history_table.pack(fill='both',expand=True,pady=8)
        history_actions=ttk.Frame(history);history_actions.pack(fill='x')
        ttk.Button(history_actions,text='Открыть ссылку',command=lambda:self.history_link(False)).pack(side='left',padx=3)
        ttk.Button(history_actions,text='Скопировать ссылку',command=lambda:self.history_link(True)).pack(side='left',padx=3)
        ttk.Label(history,text='«Письмо принято сервером» не подтверждает получение партнёром. Старые ссылки могут стать недоступны после удаления архива с Диска.',wraplength=850).pack(anchor='w',pady=8)
        self.wizard=Wizard(notebook,self)
        notebook.insert(0,self.wizard,text='Первый запуск')
        notebook.select(self.wizard if self.q.setting('first_test_confirmed','0')!='1' else main)
        self.refresh()
        if '--autostart' in sys.argv:root.after(1200,self.start)

    def log(self,text):self.messages.put(str(text))

    def config(self,require_all=True):
        c=dict(self.c)
        c.update({key:e.get().strip() for key,e in self.entries.items()})
        c['dtf_recipient']=self.dtf_recipient.get().strip()
        for key,_,_ in FIELDS:
            if require_all and key!='disk_client_id' and not c[key]:raise UserError('Заполните все обязательные поля настроек.')
        if c['api_id'] and (not c['api_id'].isdigit() or int(c['api_id'])<=0):raise UserError('Telegram API ID должен быть числом.')
        if c['api_hash'] and not re.fullmatch(r'[a-fA-F0-9]{32}',c['api_hash']):raise UserError('API hash должен содержать 32 символа из Telegram.')
        if c['bot_token'] and not re.fullmatch(r'\d+:[A-Za-z0-9_-]+',c['bot_token']):raise UserError('Проверьте токен бота.')
        for key in ['sender','recipient','dtf_recipient']:
            if c[key] and not re.fullmatch(r'[A-Za-z0-9.!#$%&\x27*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',c[key]):raise UserError('Проверьте почтовые адреса.')
        if c.get('disk_client_id') and not re.fullmatch(r'[a-fA-F0-9]{32}',c['disk_client_id']):raise UserError('Проверьте ClientID приложения Яндекс Диска.')
        if '#access_token=' in c['disk_token']:
            c['disk_token']=urllib.parse.parse_qs(urllib.parse.urlsplit(c['disk_token']).fragment).get('access_token',[''])[0]
        return c

    def save_partial(self):return self.save(require_all=False)

    def save(self,require_all=True):
        if self.thread and self.thread.is_alive():messagebox.showinfo('Настройки','Сначала остановите обработчик.');return False
        try:
            updated=self.config(require_all=require_all)
            changed=any(self.c.get(k,'')!=updated.get(k,'') for k,_,_ in FIELDS if k!='disk_client_id')
            dtf_changed=self.c.get('dtf_recipient','')!=updated.get('dtf_recipient','') or any(self.c.get(k,'')!=updated.get(k,'') for k in ('api_id','api_hash','bot_token','disk_token','sender','smtp_password'))
            disk_changed=self.c.get('disk_token')!=updated.get('disk_token')
            self.settings.save(updated);self.c=updated
            if disk_changed:
                self.q.set_setting('disk_free_bytes','');self.q.set_setting('space_check_after','0');self.q.set_setting('low_space_episode','')
            if changed:
                self.q.set_setting('generation',int(self.q.setting('generation','0'))+1)
                for key in ('first_test_confirmed','automatic','bot_checked','disk_checked','mail_checked'):self.q.set_setting(key,'0')
                self.auto.set(False)
            if dtf_changed:
                self.q.set_setting('dtf_generation',int(self.q.setting('dtf_generation','0'))+1)
                self.q.set_setting('dtf_automatic','0');self.q.set_setting('dtf_first_test_confirmed','0');self.dtf_auto.set(False)
        except UserError as e:messagebox.showerror('Настройки',str(e));return False
        self.log('Настройки сохранены на этом компьютере.');return True

    def check(self):
        if not self.save():return
        c=dict(self.c)
        def check():
            try:
                space=Disk(c['disk_token']).check();self.q.set_setting('disk_checked','1')
                smtp=smtp_connect(c);smtp.close();self.q.set_setting('mail_checked','1')
                self.log(f'Диск и почта доступны. Свободно на Диске: {space/1024**3:.1f} ГБ. Письмо не отправлялось.')
            except UserError as e:self.log(str(e))
            except Exception:self.log('Проверка не завершена. Проверьте интернет.')
        threading.Thread(target=check,daemon=True).start()

    def start(self):
        if self.thread and self.thread.is_alive():return
        if not self.save():return
        self.worker=Worker(self.q,dict(self.c),self.log)
        def run():
            try:asyncio.run(self.worker.run())
            except UserError as e:self.log(str(e))
            except Exception as e:self.log(f'Бот не подключён ({type(e).__name__}). Проверьте настройки Telegram и интернет. Секреты в журнал не записаны.')
        self.thread=threading.Thread(target=run,daemon=True);self.thread.start()
        self.log('Подключаю Telegram…')

    def stop(self):
        if self.worker:self.worker.stop()

    def save_schedule(self):
        value=self.dispatch_time.get().strip()
        if not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d',value):
            messagebox.showerror('Расписание','Введите время от 00:00 до 23:59, например 18:00.');return False
        days=[str(i) for i,var in enumerate(self.dispatch_days) if var.get()]
        if not days:
            messagebox.showerror('Расписание','Выберите хотя бы один день недели.');return False
        with self.q.lock,self.q.db:
            self.q.set_setting('dispatch_time',value)
            self.q.set_setting('dispatch_days',','.join(days))
        self.log('Расписание сохранено: '+value+' МСК, '+', '.join(('Пн','Вт','Ср','Чт','Пт','Сб','Вс')[int(i)] for i in days)+'.')
        return True

    def save_dtf_schedule(self):
        value=self.dtf_time.get().strip();days=[str(i) for i,var in enumerate(self.dtf_days) if var.get()]
        if not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d',value) or not days:
            messagebox.showerror('ДТФ','Укажите время ЧЧ:ММ и хотя бы один день недели.');return False
        with self.q.lock:
            self.q.set_setting('dtf_dispatch_time',value);self.q.set_setting('dtf_dispatch_days',','.join(days))
        self.log('Расписание ДТФ сохранено: '+value+' МСК.');return True

    def set_dtf_auto(self):
        if self.dtf_auto.get():
            if not self.save_dtf_schedule() or not self.c.get('dtf_recipient') or self.q.setting('dtf_first_test_confirmed','0')!='1':
                self.dtf_auto.set(False);messagebox.showinfo('ДТФ','Сначала сохраните получателя ДТФ, отправьте тест и подтвердите тестовое письмо ДТФ.');return
        self.q.set_setting('dtf_automatic',int(self.dtf_auto.get()))

    def send_dtf(self):
        if not self.worker or not self.thread or not self.thread.is_alive():messagebox.showinfo('ДТФ','Сначала запустите бота.');return
        if not self.c.get('dtf_recipient'):messagebox.showinfo('ДТФ','Сохраните тестовую почту ДТФ.');return
        rows=self.q.waiting('dtf')
        if not messagebox.askyesno('ДТФ',f'Собрать и отправить общий холст из {len(rows)} принтов с указанными копиями?'):return
        try:
            bid=self.q.claim(self.c['dtf_recipient'],datetime.now().timestamp(),manual=True,direction='dtf')
            self.log('Начинаю сборку холста ДТФ.' if bid else 'Очередь ДТФ пуста.')
        except UserError as e:messagebox.showinfo('ДТФ',str(e))

    def confirm_dtf_test(self):
        with self.q.lock:
            test=self.q.db.execute("select 1 from batches where direction='dtf' and state='sent' and test_mode=1 and generation=? limit 1",(int(self.q.setting('dtf_generation','0')),)).fetchone()
        if not test:messagebox.showinfo('ДТФ','Сначала отправьте тестовый холст на свою почту.');return
        if messagebox.askyesno('ДТФ','Вы скачали PNG по ссылке, проверили размеры, количество копий и прозрачность?'):
            self.q.set_setting('dtf_first_test_confirmed','1');self.log('Тест ДТФ подтверждён. Можно включить расписание ДТФ.')

    def set_auto(self):
        if self.auto.get() and not self.save_schedule():
            self.auto.set(False);return
        if self.auto.get() and not self.q.setting('owner'):
            self.auto.set(False);messagebox.showinfo('Подключение','Сначала подключите владельца через кнопку «Подключить сотрудников».');return
        if self.auto.get() and self.q.setting('first_test_confirmed','0')!='1':
            self.auto.set(False);messagebox.showinfo('Сначала тест','Сначала получите тестовое письмо, скачайте архив и нажмите «Тестовое письмо проверено».');return
        self.q.set_setting('automatic',int(self.auto.get()))
        self.log('Автоматическая отправка '+('включена.' if self.auto.get() else 'выключена.'))

    def pair(self):
        if not self.c.get('owner_code'):return
        text=('1. Откройте нового бота в Telegram и отправьте:\n/owner '+self.c['owner_code']+'\n\n2. Сотрудники отправляют боту (вместо Филиал укажите название):\n/join '+self.c['join_code']+' Филиал\n\nКод сотрудников выдавайте только своим сотрудникам. Код владельца никому не передавайте.')
        text+='\n\n3. Ответственный филиал (команда только его сотрудникам):\n/responsible '+self.c['responsible_code']+'\nНастройте название филиала во вкладке «История и уведомления». Обычный /join не даёт этих прав.'
        win=tk.Toplevel(self.root);win.title('Подключение к боту')
        box=tk.Text(win,width=95,height=17,wrap='word');box.pack(padx=14,pady=14);box.insert('1.0',text);box.configure(state='disabled')
        def copy_owner():
            win.clipboard_clear();win.clipboard_append('/owner '+self.c['owner_code']);win.update()
            messagebox.showinfo('Скопировано','Команда владельца скопирована. Вставьте её в личный чат @perezakazi_bot.',parent=win)
        ttk.Button(win,text='Скопировать команду владельца',command=copy_owner).pack(pady=8)
        def copy_staff():
            win.clipboard_clear();win.clipboard_append('/join '+self.c['join_code']+' Филиал');win.update()
            messagebox.showinfo('Скопировано','Замените слово «Филиал» точным адресом филиала.',parent=win)
        ttk.Button(win,text='Скопировать команду сотрудника',command=copy_staff).pack(pady=4)
        def copy_responsible():
            win.clipboard_clear();win.clipboard_append('/responsible '+self.c['responsible_code']);win.update()
            messagebox.showinfo('Скопировано','Отправьте команду только сотрудникам ответственного филиала.',parent=win)
        ttk.Button(win,text='Скопировать команду ответственного филиала',command=copy_responsible).pack(pady=4)



    def send(self):
        if not self.worker or not self.thread or not self.thread.is_alive():messagebox.showinfo('Отправка','Сначала запустите бота.');return
        if not self.q.setting('owner'):messagebox.showinfo('Отправка','Сначала подключите владельца через кнопку «Подключить сотрудников».');return
        if not messagebox.askyesno('Подтвердите отправку',f'Отправить всю общую очередь: {len(self.q.waiting())} файлов?'):return
        try:
            bid=self.q.claim(self.c['recipient'],datetime.now().timestamp(),manual=True)
            self.log('Начинаю подготовку отправки.' if bid else 'Очередь пуста.')
        except UserError as e:messagebox.showinfo('Отправка',str(e))

    def delete(self):
        selected=self.table.selection()
        if not selected:return
        id=int(selected[0]);row=self.q.file(id)
        if not messagebox.askyesno('Удалить файл',f'Удалить из очереди «{row["name"]}»?'):return
        try:
            row=self.q.cancel(id)
            try:self.q.path(row).unlink(missing_ok=True)
            except OSError:pass
            self.log('Удалён из очереди: '+row['name'])
        except UserError as e:messagebox.showinfo('Удаление',str(e))

    def uncertain(self):
        with self.q.lock:
            batch=self.q.db.execute("select * from batches where state='uncertain' order by created limit 1").fetchone()
        if not batch:messagebox.showinfo('Проверка','Неопределённых отправок нет.');return
        answer=messagebox.askyesnocancel('Проверьте почту',f'Письмо по заказу {batch["id"][:8]} НАЙДЕНО в ящике {batch["recipient"]}?\n\nДа — отметить отправленным.\nНет — передать заказ в ручной режим после проверки почты.\nОтмена — ничего не менять.')
        if answer is None:return
        if answer:self.q.reset_uncertain(batch['id'],confirmed_received=True)
        else:self.handoff.pause(batch['id'],'uncertain','Письмо не найдено по проверке владельца. Требуется ручная отправка.')
        self.log('Результат письма уточнён по вашей проверке.')

    def autostart(self):
        if os.name!='nt':return
        target=Path(os.environ['APPDATA'])/'Microsoft/Windows/Start Menu/Programs/Startup/CloudshopPrint.cmd'
        if target.exists():
            if messagebox.askyesno('Автозапуск','Отключить автозапуск при входе в Windows?'):target.unlink();self.log('Автозапуск отключён.')
            return
        if not messagebox.askyesno('Автозапуск','Запускать обработчик автоматически после входа этого пользователя в Windows?'):return
        # Arguments contain no credentials.
        command=f'"{sys.executable}" --autostart' if getattr(sys,'frozen',False) else f'"{Path(sys.executable).with_name("pythonw.exe")}" "{BASE / "app.py"}" --autostart'
        target.write_text('@echo off\r\nchcp 65001 >nul\r\nstart "" '+command+'\r\n',encoding='utf-8')
        self.log('Автозапуск включён. Программа запускается после входа в Windows, не до него.')

    def wizard_action(self,action):
        if action.startswith('url:'):webbrowser.open(action[4:]);return
        if action.startswith('field:'):
            self.notebook.select(self.setup_tab);self.entries[action[6:]].focus_set();return
        operations={'bot':self.check_bot,'oauth':self.disk_oauth,'check':self.check,'start':self.start,'pair':self.pair,
                    'sample':self.sample,'confirm':self.confirm_test,'main':lambda:self.notebook.select(self.main_tab),
                    'autostart':self.autostart,'report':self.export_report}
        operations[action]()

    def disk_oauth(self):
        client=self.entries['disk_client_id'].get().strip()
        if not re.fullmatch(r'[a-fA-F0-9]{32}',client):
            messagebox.showinfo('ClientID','Введите ClientID вашего приложения Яндекс Диска в настройках.');return
        webbrowser.open('https://oauth.yandex.ru/authorize?'+urllib.parse.urlencode({'response_type':'token','client_id':client}))

    def check_bot(self):
        if not self.save_partial():return
        if not self.c.get('bot_token'):messagebox.showinfo('Токен','Сначала введите токен нового бота.');return
        c=dict(self.c)
        def check():
            try:
                username=check_dedicated_bot(c['bot_token'],c['bot_username'])
                self.q.set_setting('bot_checked','1');self.log('Telegram подтвердил @'+username+'. Другой обработчик к нему не подключён.')
            except UserError as e:self.log(str(e))
        threading.Thread(target=check,daemon=True).start()

    def sample(self):
        source=BASE/'ТЕСТ_НЕ_ПЕЧАТАТЬ_1х1см.tif'
        if not source.exists():messagebox.showinfo('Тест','Тестовый файл не найден. Возьмите любой безопасный TIF для проверки.');return
        dest=self.q.root/source.name
        dest.write_bytes(source.read_bytes())
        os.startfile(self.q.root)
        messagebox.showinfo('Тестовый файл','В открывшейся папке выделите ТЕСТ_НЕ_ПЕЧАТАТЬ_1х1см.tif и отправьте его в @perezakazi_bot как файл, без сжатия.')

    def confirm_test(self):
        with self.q.lock:
            test=self.q.db.execute("select id from batches where direction='wideformat' and state='sent' and test_mode=1 and generation=? order by created desc limit 1",(int(self.q.setting('generation','0')),)).fetchone()
        if not test:
            messagebox.showinfo('Сначала отправка','Программа ещё не получила подтверждение приёма тестового письма почтовым сервером. Сначала отправьте тест через бота.');return
        if not messagebox.askyesno('Подтверждение теста','Вы нашли тестовое письмо в своём ящике, скачали ZIP и открыли исходный TIF?'):
            return
        self.q.set_setting('first_test_confirmed','1')
        self.log('Тестовое письмо и архив проверены вами. Теперь можно включить ежедневное расписание.')

    def export_report(self):
        with self.q.lock:
            files={r[0]:r[1] for r in self.q.db.execute('select state,count(*) from files group by state')}
            batches={r[0]:r[1] for r in self.q.db.execute('select state,count(*) from batches group by state')}
        report={'version':VERSION,'windows':platform.release(),'python':platform.python_version(),
                'settings_present':{k:bool(e.get().strip()) for k,e in self.entries.items()},
                'checks':{k:self.q.setting(k,'0')=='1' for k in ('bot_checked','disk_checked','mail_checked','first_test_confirmed','automatic')},
                'schedule':{'time_moscow':self.q.setting('dispatch_time','18:00'),'weekdays':self.q.setting('dispatch_days','0,1,2,3,4,5,6'),'retry_minutes':10},
                'owner_connected':bool(self.q.setting('owner')),
                'owner_last_result':self.q.setting('owner_last_result','not_recorded'),
                'files_by_state':files,'batches_by_state':batches}
        name=filedialog.asksaveasfilename(parent=self.root,title='Отчёт без секретов',initialfile='Cloudshop-check.json',defaultextension='.json',filetypes=[('JSON','*.json')])
        if name:Path(name).write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8');self.log('Отчёт сохранён: без токенов, адресов, кодов сотрудников и названий файлов.')

    def save_alerts(self):
        try:
            value=float(self.space_threshold.get().replace(',','.'))
            if not 0<value<=100000:raise ValueError()
        except ValueError:
            messagebox.showerror('Уведомления','Введите порог свободного места от 0 до 100000 ГБ (больше нуля).');return
        try:
            download=int(self.download_delay.get());send=int(self.send_delay.get())
            if not 1<=download<=1440 or not 1<=send<=1440:raise ValueError()
        except ValueError:
            messagebox.showerror('Уведомления','Время ожидания должно быть целым числом от 1 до 1440 минут.');return
        self.q.set_setting('download_delay_minutes',download);self.q.set_setting('send_delay_minutes',send)
        self.q.set_setting('alert_branch',self.alert_branch.get().strip()[:80])
        self.q.set_setting('space_threshold_gb',value)
        self.q.set_setting('space_check_after','0')
        self.log('Настройки уведомлений сохранены. Подключите ответственных сотрудников отдельной командой.')

    def history_link(self,copy):
        selected=self.history_table.selection()
        if not selected:return
        batch=self.q.batch(selected[0])
        link=batch.get('link') if batch and batch['state'] in ('sent','manual_sent') else None
        if not link:
            messagebox.showinfo('Ссылка','Ссылка доступна для отправок, принятых почтовым сервером.');return
        if copy:
            self.root.clipboard_clear();self.root.clipboard_append(link);self.root.update()
            self.log('Ссылка на архив скопирована.')
        elif link.startswith('https://'):webbrowser.open(link)

    def help(self):os.startfile(BASE/'ИНСТРУКЦИЯ.txt')

    def refresh(self):
        if not self.root.winfo_exists():return
        while True:
            try:text=self.messages.get_nowait()
            except threadqueue.Empty:break
            self.logs.configure(state='normal');self.logs.insert('end',datetime.now().strftime('%H:%M:%S')+' '+text+'\n');self.logs.see('end');self.logs.configure(state='disabled')
        dtf_rows=self.q.waiting('dtf')
        previous=set(self.dtf_table.get_children())
        for row in dtf_rows:
            key=str(row['id']);values=(row['name'],row['copies'] if row['copies_set'] else 'Укажите',{'queued':'Ожидает скачивания','downloading':'Скачивается','ready':'Сохранён','failed':'Ошибка','cancelled':'Удалён'}.get(row['state'],row['state']))
            if key in previous:self.dtf_table.item(key,values=values);previous.remove(key)
            else:self.dtf_table.insert('','end',iid=key,values=values)
        for key in previous:self.dtf_table.delete(key)
        self.dtf_status.configure(text=f'Принтов: {len(dtf_rows)} · Копий с подтверждённым количеством: {sum(r["copies"] for r in dtf_rows if r["copies_set"])}')
        rows=self.q.waiting()
        existing=set(self.table.get_children())
        states={'queued':'Ожидает скачивания','downloading':'Скачивается','ready':'Сохранён','failed':'Ошибка скачивания'}
        for r in rows:
            key=str(r['id']);values=(key,r['name'],states.get(r['state'],r['state']))
            if key in existing:self.table.item(key,values=values);existing.remove(key)
            else:self.table.insert('','end',iid=key,values=values)
        for key in existing:self.table.delete(key)
        history_states={'sent':'Письмо принято сервером','manual':'Ручная отправка','manual_sent':'Отмечено отправленным вручную','uncertain':'Нужно проверить почту','cancelled':'Отменено','collecting':'Подготовка / ожидание повтора','packing':'Сборка архива','uploading':'Загрузка на Диск','ready':'Готово к отправке','submitting':'Передача письма','invalidated':'Пересборка'}
        old=set(self.history_table.get_children())
        history_rows=self.q.history()
        for batch in history_rows:
            key=batch['id'];values=(datetime.fromtimestamp(batch['created'],MOSCOW).strftime('%d.%m.%Y %H:%M'),DIRECTIONS.get(batch['direction'],{}).get('label',batch['direction']),history_states.get(batch['state'],batch['state']),batch['file_count'],batch['recipient'])
            if key in old:self.history_table.item(key,values=values);old.remove(key)
            else:self.history_table.insert('','end',iid=key,values=values)
        for batch in history_rows:self.history_table.move(batch['id'],'','end')
        for key in old:self.history_table.delete(key)
        free=self.q.setting('disk_free_bytes')
        if free:self.space_status.configure(text=f'Последняя проверка: свободно {int(free)/1024**3:.1f} ГБ')
        running=self.thread and self.thread.is_alive()
        with self.q.lock:
            uncertain=self.q.db.execute("select count(*) from batches where state='uncertain'").fetchone()[0]
        self.status.configure(text=('Обработчик запущен' if running else 'Обработчик остановлен')+f' · В очереди: {len(rows)}'+(' · Нужна проверка письма!' if uncertain else ''))
        self.root.after(1500,self.refresh)

    def close(self):
        if self.thread and self.thread.is_alive():
            if not messagebox.askyesno('Остановить обработчик','При закрытии получение файлов и отправка остановятся. Закрыть программу?'):return
        self.stop();self.root.destroy()


def self_test(report_path):
    report={'ok':False}
    try:
        import telethon
        import cryptg
        sample=b'\0'*16; key=b'\1'*32; iv=b'\2'*32
        assert cryptg.decrypt_ige(cryptg.encrypt_ige(sample,key,iv),key,iv)==sample
        with tempfile.TemporaryDirectory() as folder:
            previous=os.environ.get('LOCALAPPDATA')
            os.environ['LOCALAPPDATA']=folder
            root=None;instance=None
            try:
                assert protect(protect(b'Windows encryption test'),decrypt=True)==b'Windows encryption test'
                root=tk.Tk();root.withdraw();instance=App(root);root.update_idletasks()
                assert instance.q.setting('automatic','0')=='0'
                assert len(instance.dispatch_days)==7
                assert instance.history_table.winfo_exists()
                assert instance.alert_branch.get()==''
                assert instance.dtf_time.get()=='12:00'
                assert [i for i,v in enumerate(instance.dtf_days) if v.get()]==[0,3]
                from PIL import Image
                assert Image.new('RGBA',(2,2)).mode=='RGBA'
                from dtf_render import inspect_art,render_png
                from dtf_layout import Layout,Placement
                source=Path(folder)/'source.png';output=Path(folder)/'sheet.png'
                Image.new('RGBA',(2,3),(255,0,0,255)).save(source,dpi=(300,300))
                assert inspect_art(source)['width']==2
                render_png(output,Layout(16,16,1,1,(Placement('test',1,1,2,3,False),)),{'test':source})
                with Image.open(output) as check:
                    assert check.mode=='RGBA' and check.getpixel((0,0))==(0,0,0,0) and check.getpixel((1,1))==(255,0,0,255)
                    assert abs(check.info['dpi'][0]-300)<.01
                instance.dispatch_time.set('17:45')
                assert instance.save_schedule()
                assert instance.q.setting('dispatch_time')=='17:45'
                assert instance.q.setting('first_test_confirmed','0')=='0'
                assert instance.wizard is not None
                assert 'perezakazi_bot' in root.title()
                assert (BASE/'ТЕСТ_НЕ_ПЕЧАТАТЬ_1х1см.tif').exists()
                report={'ok':True,'version':VERSION,'telethon':telethon.__version__,'gui':True,'dpapi':True,'fast_file_crypto':True,'automatic_enabled':False}
            finally:
                if instance:instance.q.db.close()
                if root:root.destroy()
                if previous is None:os.environ.pop('LOCALAPPDATA',None)
                else:os.environ['LOCALAPPDATA']=previous
    except Exception as e:report['error_type']=type(e).__name__
    Path(report_path).write_text(json.dumps(report,indent=2),encoding='utf-8')
    return 0 if report['ok'] else 1


if __name__=='__main__':
    if '--self-test' in sys.argv:
        try:report_path=sys.argv[sys.argv.index('--report')+1]
        except (ValueError,IndexError):sys.exit(2)
        sys.exit(self_test(report_path))
    root=tk.Tk()
    try:app=App(root)
    except Exception as e:
        messagebox.showerror('Запуск',str(e) if isinstance(e,UserError) else 'Не удалось открыть локальные настройки.');root.destroy();sys.exit(1)
    root.mainloop()
