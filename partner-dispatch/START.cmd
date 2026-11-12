@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
if not exist ".venv\Scripts\pythonw.exe" (
 echo Сначала запустите SETUP.cmd.
 pause
 exit /b 1
)
start "" ".venv\Scripts\pythonw.exe" "%~dp0app.py"
