@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
 echo Сначала запустите SETUP.cmd.
 pause
 exit /b 1
)
".venv\Scripts\python.exe" diagnostics.py
pause
