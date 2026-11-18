"""Per-user background startup: Windows credentials remain in their original DPAPI profile."""
import base64
import ctypes
import json
import os
from pathlib import Path
import subprocess
from core import UserError

EVENT_NAME='Local\\CloudshopPrintShowWindow'

def show_event(create=False):
    if os.name!='nt':return None
    from ctypes import wintypes
    lib=ctypes.WinDLL('kernel32',use_last_error=True)
    lib.CreateEventW.argtypes=[ctypes.c_void_p,wintypes.BOOL,wintypes.BOOL,wintypes.LPCWSTR];lib.CreateEventW.restype=wintypes.HANDLE
    lib.OpenEventW.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.LPCWSTR];lib.OpenEventW.restype=wintypes.HANDLE
    lib.SetEvent.argtypes=[wintypes.HANDLE];lib.SetEvent.restype=wintypes.BOOL
    lib.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD];lib.WaitForSingleObject.restype=wintypes.DWORD
    lib.CloseHandle.argtypes=[wintypes.HANDLE]
    if create:return lib.CreateEventW(None,False,False,EVENT_NAME)
    handle=lib.OpenEventW(2,False,EVENT_NAME)
    if not handle:return False
    try:return bool(lib.SetEvent(handle))
    finally:lib.CloseHandle(handle)

def event_requested(handle):
    if not handle:return False
    from ctypes import wintypes
    lib=ctypes.WinDLL('kernel32',use_last_error=True)
    lib.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD];lib.WaitForSingleObject.restype=wintypes.DWORD
    return lib.WaitForSingleObject(handle,0)==0

def task_script(executable,args,enabled=True):
    payload=base64.b64encode(json.dumps({'exe':str(executable),'args':args,'enabled':enabled}).encode()).decode()
    return '''$ErrorActionPreference='Stop'
$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+"'"+payload+"'"+'''))|ConvertFrom-Json
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$name='CloudshopPrintDispatch-'+$sid
if(-not $c.enabled){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue;exit}
$action=New-ScheduledTaskAction -Execute $c.exe -Argument $c.args -WorkingDirectory ([IO.Path]::GetDirectoryName($c.exe))
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $sid
$principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force|Out-Null
'''

def configure_task(executable,args,enabled=True):
    script=task_script(executable,args,enabled)
    encoded=base64.b64encode(script.encode('utf-16le')).decode()
    try:
        result=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',encoded],capture_output=True,timeout=40,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    except (OSError,subprocess.TimeoutExpired):raise UserError('Не удалось настроить планировщик Windows. Проверьте доступ к планировщику заданий.') from None
    if result.returncode:raise UserError('Windows не разрешила настроить автозапуск. Запустите программу от имени того же пользователя Windows и проверьте доступ к планировщику.')
    # Remove the previous visible-window Startup shortcut only after the new task is registered.
    old=Path(os.environ['APPDATA'])/'Microsoft/Windows/Start Menu/Programs/Startup/CloudshopPrint.cmd'
    old.unlink(missing_ok=True)
