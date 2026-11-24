@echo off
if exist "%LOCALAPPDATA%\CloudshopDesk\App\CloudshopDesk.exe" (
 start "" "%LOCALAPPDATA%\CloudshopDesk\App\CloudshopDesk.exe"
) else (
 call "%~dp0INSTALL.cmd"
)
