@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo Клаудшоп — установка обработчика печати
where py >nul 2>nul
if not errorlevel 1 goto launcher
where python >nul 2>nul
if not errorlevel 1 goto python
:missing
echo.
echo Сначала установите Python 3.11 или новее с python.org.
echo При установке включите Python Launcher и Tcl/Tk.
echo После установки запустите SETUP.cmd повторно.
pause
exit /b 1
:launcher
py -3 -c "import sys,tkinter; assert sys.version_info >= (3,11)" >nul 2>nul
if errorlevel 1 goto missing
py -3 -m venv .venv
if errorlevel 1 goto fail
goto packages
:python
python -c "import sys,tkinter; assert sys.version_info >= (3,11)" >nul 2>nul
if errorlevel 1 goto missing
python -m venv .venv
if errorlevel 1 goto fail
:packages
".venv\Scripts\python.exe" -m pip install --no-index --find-links wheelhouse --require-hashes -r requirements.lock
if errorlevel 1 goto fail
echo.
echo Готово. Для запуска используйте START.cmd.
echo Сначала подключим отдельного бота и почту по инструкции.
pause
exit /b 0
:fail
echo Установка не завершилась. Сообщите текст ошибки, без паролей и токенов.
pause
exit /b 1
