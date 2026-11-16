"""Independent 30x40 receiver. No Telegram session, bot token or mail password."""
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import sqlite3
import sys
import threading
import urllib.parse
import urllib.request
import uuid
import tkinter as tk
from tkinter import ttk,messagebox,filedialog
from core import UserError,safe_name
from services import Settings
from bridge_client import BridgeClient


def desktop_path():
    if os.name=='nt':
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,r'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') as key:
                return Path(os.path.expandvars(winreg.QueryValueEx(key,'Desktop')[0]))
        except OSError:pass
    return Path.home()/'Desktop'

def trusted_yandex(url):
    p=urllib.parse.urlsplit(url);host=p.hostname or ''
    return p.scheme=='https' and (host.endswith('.yandex.net') or host.endswith('.yandex.ru') or host.endswith('.yandex.com'))

class YandexRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        if not trusted_yandex(newurl):raise UserError('Неизвестный адрес загрузки файла.')
        return super().redirect_request(req,fp,code,msg,headers,newurl)

def download_original(url,destination,expected_size,expected_hash,stopped=lambda:False):
    public=urllib.parse.urlsplit(url)
    if public.scheme!='https' or public.hostname not in ('disk.yandex.ru','disk.yandex.com','yadi.sk'):raise UserError('Неизвестная ссылка исходника.')
    endpoint='https://cloud-api.yandex.net/v1/disk/public/resources/download?'+urllib.parse.urlencode({'public_key':url})
    with urllib.request.urlopen(endpoint,timeout=40) as response:href=json.load(response).get('href','')
    if not trusted_yandex(href):raise UserError('Диск не вернул адрес исходника.')
    if shutil.disk_usage(Path(destination).parent).free<expected_size+100*1024**2:raise UserError('Недостаточно места в папке 30х40.')
    digest=hashlib.sha256();count=0
    opener=urllib.request.build_opener(YandexRedirect())
    with opener.open(href,timeout=120) as response,open(destination,'wb') as out:
        while chunk:=response.read(1024**2):
            if stopped():raise UserError('Загрузка остановлена. Файл останется в очереди.')
            count+=len(chunk)
            if count>expected_size:raise UserError('Размер исходника не совпадает.')
            digest.update(chunk);out.write(chunk)
        out.flush();os.fsync(out.fileno())
    if count!=expected_size or digest.hexdigest()!=expected_hash:raise UserError('Исходник не прошёл проверку целостности.')

class Receiver:
    def __init__(self,data_dir,folder,client,download=download_original):
        self.root=Path(folder).resolve();self.root.mkdir(parents=True,exist_ok=True)
        self.client=client;self.download=download
        self.db=sqlite3.connect(Path(data_dir)/'receipts.sqlite3',check_same_thread=False)
        self.db.row_factory=sqlite3.Row
        self.db.execute('create table if not exists receipts(id text primary key,path text not null,sha256 text not null,size integer not null,state text not null)');self.db.commit()
    def receive(self,job,stopped=lambda:False):
        id=str(uuid.UUID(job['id']));name=job['filename'];size=int(job['size']);sha=job['sha256']
        if name!=safe_name(name) or not 0<size<=500*1024**2 or not re.fullmatch('[a-f0-9]{64}',sha):raise UserError('Недопустимое задание.')
        row=self.db.execute('select * from receipts where id=?',(id,)).fetchone()
        if row:
            if row['sha256']!=sha or row['size']!=size:raise UserError('Состав задания изменился.')
            target=Path(row['path'])
        else:
            target=self.root/name
            if target.exists():target=self.root/('Заказ-'+id)/name
            with self.db:self.db.execute('insert into receipts values(?,?,?,?,?)',(id,str(target),sha,size,'new'))
        if not target.resolve().is_relative_to(self.root):raise UserError('Путь сохранения изменился. Верните прежнюю папку или подключите приёмник заново.')
        target.parent.mkdir(parents=True,exist_ok=True)
        saved=bool(row and target.exists())
        if saved:
            with target.open('rb') as file:saved=target.stat().st_size==size and hashlib.file_digest(file,'sha256').hexdigest()==sha
        if not saved:
            part=target.parent/('.'+name+'.'+id+'.part')
            try:
                self.download(job['url'],part,size,sha,stopped)
                with part.open('rb') as file:
                    if part.stat().st_size!=size or hashlib.file_digest(file,'sha256').hexdigest()!=sha:raise UserError('Исходник не прошёл проверку.')
                if target.exists():
                    target=self.root/('Заказ-'+id)/name;target.parent.mkdir(parents=True,exist_ok=True)
                    if target.exists():raise UserError('Файл заказа уже существует и отличается. Проверьте папку; автоматическая перезапись запрещена.')
                    with self.db:self.db.execute('update receipts set path=? where id=?',(str(target),id))
                if os.name=='nt':os.rename(part,target) # Windows rename never replaces an existing destination.
                else:os.link(part,target);part.unlink()
                with self.db:self.db.execute("update receipts set state='saved' where id=?",(id,))
            finally:part.unlink(missing_ok=True)
        with self.db:self.db.execute("update receipts set state='saved' where id=?",(id,))
        relative=target.relative_to(self.root).as_posix()
        self.client.request('complete',{'id':id,'sha256':sha,'size':size,'relative_path':relative})
        with self.db:self.db.execute("update receipts set state='reported' where id=?",(id,))
        return relative
    def pending_acknowledgments(self):
        return [dict(r) for r in self.db.execute("select * from receipts where state='saved'")]
    def retry_acks(self):
        for row in self.pending_acknowledgments():
            path=Path(row['path'])
            with path.open('rb') as file:
                if path.stat().st_size!=row['size'] or hashlib.file_digest(file,'sha256').hexdigest()!=row['sha256']:raise UserError('Сохранённый файл изменился до уведомления Клаудшопа.')
            self.client.request('complete',{'id':row['id'],'sha256':row['sha256'],'size':row['size'],'relative_path':path.relative_to(self.root).as_posix()})
            with self.db:self.db.execute("update receipts set state='reported' where id=?",(row['id'],))

class ReceiverApp:
    def __init__(self,root):
        self.root=root;root.title('Клаудшоп · приёмник 30×40');root.geometry('780x500')
        self.mutex=None
        if os.name=='nt':
            import ctypes
            lib=ctypes.WinDLL('kernel32',use_last_error=True);lib.CreateMutexW.restype=ctypes.c_void_p;lib.CreateMutexW.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_wchar_p]
            self.mutex=lib.CreateMutexW(None,False,'Local\\CloudshopPrint30Receiver')
            if ctypes.get_last_error()==183:raise UserError('Приёмник уже запущен на этом компьютере.')
        self.data=Path(os.environ.get('LOCALAPPDATA',str(Path.cwd()/'data')))/'CloudshopPrintReceiver'
        self.settings=Settings(self.data);self.config=self.settings.load();self.messages=queue.Queue();self.stop_event=threading.Event();self.thread=None;self.pairing=False
        box=ttk.Frame(root,padding=18);box.pack(fill='both',expand=True)
        ttk.Label(box,text='Приём файлов для принтера 30×40',font=('Segoe UI',17,'bold')).pack(anchor='w')
        ttk.Label(box,text='Скачивает оригиналы в папку. Печать запускает сотрудник. Telegram и почту здесь настраивать не нужно.',wraplength=720).pack(anchor='w',pady=8)
        ttk.Label(box,text='Код приёмника из Клаудшопа (раздел «30×40», администратор):').pack(anchor='w')
        self.code=ttk.Entry(box,width=50,show='•');self.code.pack(anchor='w',pady=5)
        ttk.Button(box,text='Подключить этот компьютер',command=self.pair).pack(anchor='w')
        self.folder=tk.StringVar(value=self.config.get('folder',str(desktop_path()/'30х40')))
        row=ttk.Frame(box);row.pack(fill='x',pady=14)
        ttk.Entry(row,textvariable=self.folder,width=65).pack(side='left',fill='x',expand=True)
        ttk.Button(row,text='Выбрать папку',command=self.choose).pack(side='left',padx=5)
        actions=ttk.Frame(box);actions.pack(fill='x')
        for text,action in [('Запустить приёмник',self.start),('Остановить',self.stop),('Открыть папку',self.open_folder),('Автозапуск',self.autostart)]:ttk.Button(actions,text=text,command=action).pack(side='left',padx=3)
        self.status=ttk.Label(box,text='Подключён: '+self.config.get('branch','нет'));self.status.pack(anchor='w',pady=8)
        self.logs=tk.Text(box,height=7,wrap='word',state='disabled');self.logs.pack(fill='both',expand=True)
        root.protocol('WM_DELETE_WINDOW',self.close);root.after(500,self.refresh)
        if '--autostart' in sys.argv:root.after(1200,self.start)
    def log(self,text):self.messages.put(text)
    def pair(self):
        if self.thread and self.thread.is_alive():messagebox.showinfo('Приёмник','Сначала остановите приёмник.');return
        if self.pairing:return
        self.pairing=True
        code=self.code.get().strip();folder=self.folder.get().strip()
        def work():
            try:
                result=BridgeClient.pair(code,'receiver');self.config.update(result);self.config['folder']=folder
                self.settings.save(self.config);self.log('Компьютер подключён: '+result['branch'])
                self.root.after(0,lambda:self.code.delete(0,'end'))
            except Exception as e:self.log(str(e) if isinstance(e,(UserError,ConnectionError)) else 'Не удалось подключить компьютер.')
            finally:self.pairing=False
        threading.Thread(target=work,daemon=True).start()
    def choose(self):
        if self.thread and self.thread.is_alive():messagebox.showinfo('Приёмник','Остановите приёмник перед сменой папки.');return
        value=filedialog.askdirectory(initialdir=str(desktop_path()))
        if value:self.folder.set(value)
    def start(self):
        if self.pairing:messagebox.showinfo('Подключение','Дождитесь подключения компьютера.');return
        if self.thread and self.thread.is_alive():return
        if not self.config.get('token'):messagebox.showinfo('Приёмник','Сначала подключите компьютер кодом из Клаудшопа.');return
        folder=self.folder.get().strip()
        if not folder or not Path(folder).is_absolute():messagebox.showerror('Папка','Выберите полный путь папки.');return
        self.config['folder']=folder;self.settings.save(self.config);self.stop_event.clear()
        def run():
            receiver=None
            try:
                client=BridgeClient(self.config['token']);receiver=Receiver(self.data,folder,client)
                while not self.stop_event.is_set():
                    delay=15
                    try:
                        receiver.retry_acks();job=client.request('next')
                        if job:
                            name=receiver.receive(job,self.stop_event.is_set);self.log('Сохранён и отмечен в Клаудшопе: '+name);delay=1
                    except Exception as e:
                        self.log((str(e) if isinstance(e,(UserError,ConnectionError)) else 'Загрузка не завершена. Проверьте интернет и папку.')+' Повтор через 10 минут.');delay=600
                    self.stop_event.wait(delay)
            finally:
                if receiver:receiver.db.close()
        self.thread=threading.Thread(target=run,daemon=True);self.thread.start();self.log('Приёмник запущен. Ожидаю файлы.')
    def stop(self):self.stop_event.set()
    def open_folder(self):
        path=Path(self.folder.get());path.mkdir(parents=True,exist_ok=True);os.startfile(path)
    def autostart(self):
        if os.name!='nt':return
        import winreg
        executable=str(Path(sys.executable).resolve())
        command='"'+executable+'" --receiver --autostart'
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER,r'Software\Microsoft\Windows\CurrentVersion\Run') as key:winreg.SetValueEx(key,'CloudshopPrint30Receiver',0,winreg.REG_SZ,command)
        messagebox.showinfo('Автозапуск','Приёмник будет запускаться после входа этого пользователя в Windows.')
    def refresh(self):
        while not self.messages.empty():
            self.logs.configure(state='normal');self.logs.insert('end',self.messages.get_nowait()+'\n');self.logs.see('end');self.logs.configure(state='disabled')
        self.status.configure(text=('Приёмник работает' if self.thread and self.thread.is_alive() else 'Приёмник остановлен')+' · '+self.config.get('branch','не подключён'))
        self.root.after(500,self.refresh)
    def close(self):
        if self.thread and self.thread.is_alive() and not messagebox.askyesno('Остановить приёмник','При закрытии загрузка файлов остановится. Закрыть?'):return
        self.stop();self.root.destroy()
