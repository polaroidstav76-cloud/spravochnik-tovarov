$ErrorActionPreference='Stop'
# Only this print bot: never touch Cloudshop POS, receiver, personal Telegram or other Python tools.
Get-ScheduledTask -TaskName 'CloudshopPrintDispatch-*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-ScheduledTask -InputObject $_ -ErrorAction SilentlyContinue; Unregister-ScheduledTask -InputObject $_ -Confirm:$false }
$startup=Join-Path $env:APPDATA 'Microsoft/Windows/Start Menu/Programs/Startup/CloudshopPrint.cmd'
Remove-Item -LiteralPath $startup -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^CloudshopPrint(?:-(x64|x86))?\.exe$' -or ($_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -match '(partner-dispatch|partner_dispatch|Cloudshop-Print)[\\/][^\r\n]*app\.py') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop }
Write-Host 'Old print bot stopped. Autostart disabled. Queue and settings preserved.'
