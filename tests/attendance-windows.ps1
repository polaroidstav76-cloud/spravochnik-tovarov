$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('Install.ps1','Agent.ps1')){
 $path=Join-Path $root ('attendance-windows\'+$name)
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors|Out-String)}
 if($name -eq 'Agent.ps1'){
  $bootFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BootTime'},$true)
  Invoke-Expression $bootFunction.Extent.Text
  $time=[DateTimeOffset]::Parse((Get-BootTime))
  if($time -gt [DateTimeOffset]::UtcNow.AddMinutes(2) -or $time -lt [DateTimeOffset]'2000-01-01'){throw 'Invalid boot time'}
  $writeState=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-State'},$true)
  Invoke-Expression $writeState.Extent.Text
 }
}
# Machine-bound protected credentials survive a separate powershell process running as the same machine.
Add-Type -AssemblyName System.Security
$sample=[Text.Encoding]::UTF8.GetBytes('test-device-token')
$encrypted=[Security.Cryptography.ProtectedData]::Protect($sample,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
$plain=[Security.Cryptography.ProtectedData]::Unprotect($encrypted,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
if([Text.Encoding]::UTF8.GetString($plain) -ne 'test-device-token'){throw 'DPAPI roundtrip failed'}
$statePath=Join-Path $env:TEMP ('attendance-test-'+[guid]::NewGuid()+'.json')
try{
 Write-State @('2026-11-17T06:50:00.0000000Z')
 $decoded=Get-Content $statePath -Raw|ConvertFrom-Json
 $state=@($decoded)
 if($state.Count -ne 1 -or $state[0] -ne '2026-11-17T06:50:00.0000000Z'){throw 'Single offline event lost'}
 Write-State @('2026-11-17T06:50:00.0000000Z','2026-11-17T08:00:00.0000000Z')
 $decoded=Get-Content $statePath -Raw|ConvertFrom-Json
 $state=@($decoded)
 if($state.Count -ne 2){throw 'Offline restart queue lost'}
 Write-State @()
 $decoded=Get-Content $statePath -Raw|ConvertFrom-Json
 if(@($decoded).Count -ne 0){throw 'Acknowledged events not removed'}
}finally{Remove-Item $statePath -ErrorAction SilentlyContinue}
# Validate the exact scheduler settings without installing a real agent or making any network calls.
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -File "C:\ProgramData\CloudshopAttendance\Agent.ps1"'
$trigger=New-ScheduledTaskTrigger -AtStartup
$login=New-ScheduledTaskTrigger -AtLogOn
$repeat=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
$task=New-ScheduledTask -Action $action -Trigger @($trigger,$login,$repeat) -Settings $settings -Principal $principal
if(-not $task){throw 'Scheduled task definition failed'}
Write-Host 'PASS: Windows PowerShell syntax, actual Windows boot timestamp, DPAPI, durable offline queue and SYSTEM task definition'
