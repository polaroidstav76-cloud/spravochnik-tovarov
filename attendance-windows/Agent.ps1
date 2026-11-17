$ErrorActionPreference='Stop'
$installRoot=Join-Path $env:ProgramData 'CloudshopAttendance'
$mutex=New-Object Threading.Mutex($false,'Global\CloudshopAttendance')
if(-not $mutex.WaitOne(0)){exit}
try{
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 Add-Type -AssemblyName System.Security
 $token=[Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes((Join-Path $installRoot 'device.bin')),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine))
 $endpoint='https://tmxluzvymwldtxbaiekn.supabase.co/functions/v1/attendance-device'
 $statePath=Join-Path $installRoot 'pending.json'
 $logPath=Join-Path $installRoot 'status.log'
 function Write-State($items){
  $text=ConvertTo-Json -InputObject @($items) -Compress
  [IO.File]::WriteAllText($statePath+'.tmp',$text,[Text.Encoding]::UTF8)
  Move-Item ($statePath+'.tmp') $statePath -Force
 }
 function Write-Status($message){
  if((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 100000){Move-Item $logPath ($logPath+'.old') -Force}
  Add-Content -Path $logPath -Value ((Get-Date).ToString('s')+' '+$message) -Encoding UTF8
 }
 function Get-BootTime {
  # Kernel-Boot 27 is emitted for a full boot AND Windows Fast Startup (hybrid boot).
  $event=Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Boot';Id=27} -MaxEvents 1 -ErrorAction SilentlyContinue
  if($event){return $event.TimeCreated.ToUniversalTime().ToString('o')}
  $os=Get-CimInstance Win32_OperatingSystem
  return $os.LastBootUpTime.ToUniversalTime().ToString('o')
 }
 $boot=Get-BootTime
 $pending=@()
 if(Test-Path $statePath){try{$decoded=Get-Content $statePath -Raw|ConvertFrom-Json;$pending=@($decoded)}catch{Write-Status 'Не удалось прочитать очередь. Сохранена копия.';Copy-Item $statePath ($statePath+'.invalid') -Force}}
 $pending=@($pending|Where-Object {$_ -and ([DateTimeOffset]::Parse($_)) -gt [DateTimeOffset]::UtcNow.AddDays(-29)})
 if($pending -notcontains $boot){$pending+=,$boot}
 Write-State $pending
 Write-Status 'Программа запущена. Ожидаю передачу времени включения.'
 while($true){
  try{
   # Upload oldest pending boots before the current heartbeat so offline restarts cannot replace the first arrival.
   $send=@($pending|Sort-Object -Unique)
   if($send -notcontains $boot){$send+=,$boot}
   foreach($item in $send){
    if($item -ne $boot -and [DateTimeOffset]::Parse($item) -lt [DateTimeOffset]::UtcNow.AddDays(-29)){continue}
    $payload=@{action='report';payload=@{boot_at=$item;version='1.0.0'}}|ConvertTo-Json -Compress
    $result=Invoke-RestMethod -Uri $endpoint -Method Post -Headers @{'x-device-token'=$token} -ContentType 'application/json' -Body $payload -TimeoutSec 25
    if(-not $result.result.saved){throw 'No acknowledgement'}
    $pending=@($pending|Where-Object {$_ -ne $item});Write-State $pending
   }
   Write-Status 'Время передано. Фоновая проверка через 5 минут.'
   Start-Sleep -Seconds 300
  }catch{
   # No technical Telegram messages, no credentials or response bodies in logs.
   Write-Status 'Нет подтверждения сервера. Повтор через 60 секунд; время включения сохранено.'
   Start-Sleep -Seconds 60
  }
 }
}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
