@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "PRINT_ARCH=x86"
if /I "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "PRINT_ARCH=x64"
if defined PROCESSOR_ARCHITEW6432 set "PRINT_ARCH=x64"
if not exist "CloudshopPrint-%PRINT_ARCH%.exe" (
 echo Распакуйте весь архив в одну папку. Файл программы не найден.
 pause
 exit /b 1
)
start "" "%~dp0CloudshopPrint-%PRINT_ARCH%.exe"
