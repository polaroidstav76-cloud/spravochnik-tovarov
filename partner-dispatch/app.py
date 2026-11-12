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
from core import Queue,UserError
from services import Settings,Disk,smtp_connect,check_dedicated_bot,protect
from worker import Worker
from wizard import Wizard

BASE=Path(__file__).resolve().parent
VERSION='0.3'
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
        self.c.setdefault('sender','')
        self.c.setdefault('owner_code',secrets.token_urlsafe(18))
        self.c.setdefault('join_code',secrets.token_urlsafe(18))
        self.q=Queue(folder)
        self.messages=threadqueue.Queue();self.worker=None;self.thread=None
        root.title('Клаудшоп — заказы партнёрам · @perezakazi_bot');width=min(1040,root.winfo_screenwidth()-50);height=min(810,root.winfo_screenheight()-90)
        root.geometry(f'{width}x{height}');root.minsize(min(900,width),min(650,height))
        outer=ttk.Frame(root,padding=14);outer.pack(fill='both',expand=True)
        ttk.Label(outer,text='Заказы партнёрам · @perezakazi_bot',font=('Segoe UI',18,'bold')).pack(anchor='w')
        ttk.Label(outer,text='Широкоформатная печать · до 500 МБ · отправка в 18:00 МСК · ДТФ подключим отдельно').pack(anchor='w',pady=(2,10))
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
        ttk.Checkbutton(main,text='Ежедневная отправка в 18:00 МСК включена',variable=self.auto,command=self.set_auto).pack(anchor='w',pady=10)
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
        ttk.Label(main,text='Файл принят только после ответа бота «Сохранён». Нельзя выключать или усыплять компьютер до завершения отправки.\nОтправки после 18:00 уходят на следующий день. Архивы и оригиналы автоматически не удаляются.',wraplength=900).pack(anchor='w')
        root.protocol('WM_DELETE_WINDOW',self.close)
        self.wizard=Wizard(notebook,self)
        notebook.insert(0,self.wizard,text='Первый запуск')
        notebook.select(self.wizard if self.q.setting('first_test_confirmed','0')!='1' else main)
        self.refresh()
        if '--autostart' in sys.argv:root.after(1200,self.start)

    def log(self,text):self.messages.put(str(text))

    def config(self,require_all=True):
        c=dict(self.c)
        c.update({key:e.get().strip() for key,e in self.entries.items()})
        for key,_,_ in FIELDS:
            if require_all and key!='disk_client_id' and not c[key]:raise UserError('Заполните все обязательные поля настроек.')
        if c['api_id'] and (not c['api_id'].isdigit() or int(c['api_id'])<=0):raise UserError('Telegram API ID должен быть числом.')
        if c['api_hash'] and not re.fullmatch(r'[a-fA-F0-9]{32}',c['api_hash']):raise UserError('API hash должен содержать 32 символа из Telegram.')
        if c['bot_token'] and not re.fullmatch(r'\d+:[A-Za-z0-9_-]+',c['bot_token']):raise UserError('Проверьте токен бота.')
        for key in ['sender','recipient']:
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
            self.settings.save(updated);self.c=updated
            if changed:
                self.q.set_setting('generation',int(self.q.setting('generation','0'))+1)
                for key in ('first_test_confirmed','automatic','bot_checked','disk_checked','mail_checked'):self.q.set_setting(key,'0')
                self.auto.set(False)
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

    def set_auto(self):
        if self.auto.get() and not self.q.setting('owner'):
            self.auto.set(False);messagebox.showinfo('Подключение','Сначала подключите владельца через кнопку «Подключить сотрудников».');return
        if self.auto.get() and self.q.setting('first_test_confirmed','0')!='1':
            self.auto.set(False);messagebox.showinfo('Сначала тест','Сначала получите тестовое письмо, скачайте архив и нажмите «Тестовое письмо проверено».');return
        self.q.set_setting('automatic',int(self.auto.get()))
        self.log('Ежедневная отправка '+('включена.' if self.auto.get() else 'выключена.'))

    def pair(self):
        if not self.c.get('owner_code'):return
        text=('1. Откройте нового бота в Telegram и отправьте:\n/owner '+self.c['owner_code']+'\n\n2. Сотрудники отправляют боту (вместо Филиал укажите название):\n/join '+self.c['join_code']+' Филиал\n\nКод сотрудников выдавайте только своим сотрудникам. Код владельца никому не передавайте.')
        win=tk.Toplevel(self.root);win.title('Подключение к боту')
        box=tk.Text(win,width=95,height=13,wrap='word');box.pack(padx=14,pady=14);box.insert('1.0',text);box.configure(state='disabled')

    def send(self):
        if not self.worker or not self.thread or not self.thread.is_alive():messagebox.showinfo('Отправка','Сначала запустите бота.');return
        if not self.q.setting('owner'):messagebox.showinfo('Отправка','Сначала подключите владельца через кнопку «Подключить сотрудников».');return
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
        answer=messagebox.askyesnocancel('Проверьте почту',f'Письмо по заказу {batch["id"][:8]} НАЙДЕНО в ящике {batch["recipient"]}?\n\nДа — отметить отправленным.\nНет — повторить отправку (если письмо всё же было доставлено, получится дубль).\nОтмена — ничего не менять.')
        if answer is None:return
        self.q.reset_uncertain(batch['id'],confirmed_received=answer)
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
            test=self.q.db.execute("select id from batches where state='sent' and test_mode=1 and generation=? order by created desc limit 1",(int(self.q.setting('generation','0')),)).fetchone()
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
                'files_by_state':files,'batches_by_state':batches}
        name=filedialog.asksaveasfilename(parent=self.root,title='Отчёт без секретов',initialfile='Cloudshop-check.json',defaultextension='.json',filetypes=[('JSON','*.json')])
        if name:Path(name).write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8');self.log('Отчёт сохранён: без токенов, адресов, кодов сотрудников и названий файлов.')

    def help(self):os.startfile(BASE/'ИНСТРУКЦИЯ.txt')

    def refresh(self):
        if not self.root.winfo_exists():return
        while True:
            try:text=self.messages.get_nowait()
            except threadqueue.Empty:break
            self.logs.configure(state='normal');self.logs.insert('end',datetime.now().strftime('%H:%M:%S')+' '+text+'\n');self.logs.see('end');self.logs.configure(state='disabled')
        rows=self.q.waiting()
        existing=set(self.table.get_children())
        states={'queued':'Ожидает скачивания','downloading':'Скачивается','ready':'Сохранён','failed':'Ошибка скачивания'}
        for r in rows:
            key=str(r['id']);values=(key,r['name'],states.get(r['state'],r['state']))
            if key in existing:self.table.item(key,values=values);existing.remove(key)
            else:self.table.insert('','end',iid=key,values=values)
        for key in existing:self.table.delete(key)
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
        with tempfile.TemporaryDirectory() as folder:
            previous=os.environ.get('LOCALAPPDATA')
            os.environ['LOCALAPPDATA']=folder
            root=None;instance=None
            try:
                assert protect(protect(b'Windows encryption test'),decrypt=True)==b'Windows encryption test'
                root=tk.Tk();root.withdraw();instance=App(root);root.update_idletasks()
                assert instance.q.setting('automatic','0')=='0'
                assert instance.q.setting('first_test_confirmed','0')=='0'
                assert instance.wizard is not None
                assert 'perezakazi_bot' in root.title()
                assert (BASE/'ТЕСТ_НЕ_ПЕЧАТАТЬ_1х1см.tif').exists()
                report={'ok':True,'version':VERSION,'telethon':telethon.__version__,'gui':True,'dpapi':True,'automatic_enabled':False}
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
