param([switch]$Uninstall)
$ErrorActionPreference='Stop'
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){
 $argsText='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'"'
 if($Uninstall){$argsText+=' -Uninstall'}
 Start-Process powershell.exe -Verb RunAs -ArgumentList $argsText -Wait
 exit
}
$installRoot=Join-Path $env:ProgramData 'CloudshopAttendance'
$taskName='CloudshopAttendance'
try{
 if($Uninstall){
  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  if(Test-Path $installRoot){Remove-Item $installRoot -Recurse -Force}
  Write-Host 'Удалено. Отключите компьютер также в Клаудшопе, если будете подключать другой.'
  Read-Host 'Нажмите Enter';exit
 }
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $endpoint='https://tmxluzvymwldtxbaiekn.supabase.co/functions/v1/attendance-device'
 Write-Host 'КЛАУДШОП - УЧЁТ ВКЛЮЧЕНИЙ КОМПЬЮТЕРА'
 Write-Host 'В админке откройте «Приход сотрудников», сохраните настройки филиала и получите код.'
 $pairCode=(Read-Host 'Вставьте код подключения (32 символа)').Trim().ToLowerInvariant()
 if($pairCode -notmatch '^[a-f0-9]{32}$'){throw 'Неверный формат кода. Скопируйте код целиком.'}
 # The one-time code is consumed only after the server verifies that this branch has no active device.
 $body=@{action='pair';payload=@{code=$pairCode;label=$env:COMPUTERNAME}}|ConvertTo-Json -Compress
 $response=Invoke-RestMethod -Uri $endpoint -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30
 if(-not $response.result.token){throw 'Сервер не подтвердил подключение.'}
 Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
 New-Item -ItemType Directory -Path $installRoot -Force|Out-Null
 # Protect both machine-bound DPAPI credentials and state from ordinary Windows accounts.
 & icacls.exe $installRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'|Out-Null
 if($LASTEXITCODE -ne 0){throw 'Не удалось защитить папку настроек.'}
 Copy-Item (Join-Path $PSScriptRoot 'Agent.ps1') (Join-Path $installRoot 'Agent.ps1') -Force
 Add-Type -AssemblyName System.Security
 $protected=[Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($response.result.token),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
 [IO.File]::WriteAllBytes((Join-Path $installRoot 'device.bin'),$protected)
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $installRoot 'Agent.ps1')+'"')
 $trigger=New-ScheduledTaskTrigger -AtStartup
 $login=New-ScheduledTaskTrigger -AtLogOn
 $repeat=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
 $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
 Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger,$login,$repeat) -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force|Out-Null
 Start-ScheduledTask -TaskName $taskName
 Write-Host ('ГОТОВО. Филиал: '+$response.result.branch)
 Write-Host 'Программа запускается автоматически при старте Windows, вход сотрудника не требуется.'
 Write-Host 'Коды и токены никому отправлять не нужно. Состояние смотрите в админке Клаудшопа.'
}catch{
 Write-Host ('Не удалось установить: '+$_.Exception.Message) -ForegroundColor Red
 Write-Host 'Если код уже использован, отключите этот компьютер в админке и получите новый код.'
}
Read-Host 'Нажмите Enter'
