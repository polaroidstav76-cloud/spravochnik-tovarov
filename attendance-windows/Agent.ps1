$ErrorActionPreference='Stop'
function Get-PowerEvents {
 $xml=@'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[TimeCreated[timediff(@SystemTime) &lt;= 2592000000] and (
 (Provider[@Name='Microsoft-Windows-Kernel-General'] and (EventID=12 or EventID=13)) or
 (Provider[@Name='Microsoft-Windows-Kernel-Boot'] and EventID=27) or
 (Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=41 or EventID=42 or EventID=107 or EventID=109)) or
 (Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1)
)]]</Select></Query></QueryList>
'@
 $records=Get-WinEvent -FilterXml $xml -MaxEvents 2000 -ErrorAction SilentlyContinue
 foreach($event in $records){Convert-PowerEvent $event}
}
function Convert-PowerEvent($event){
 $kind=$null
 switch($event.ProviderName){
  'Microsoft-Windows-Kernel-General' {if($event.Id -eq 12){$kind='boot'}elseif($event.Id -eq 13){$kind='shutdown'}}
  'Microsoft-Windows-Kernel-Boot' {if($event.Id -eq 27){$kind='boot'}}
  'Microsoft-Windows-Kernel-Power' {switch($event.Id){41 {$kind='unexpected_restart'} 42 {$kind='suspend'} 107 {$kind='resume'} 109 {$kind='shutdown'}}}
  'Microsoft-Windows-Power-Troubleshooter' {if($event.Id -eq 1){$kind='resume'}}
 }
 if($kind){return [PSCustomObject]@{kind=$kind;at=$event.TimeCreated.ToUniversalTime().ToString('o');source=($event.ProviderName+':'+$event.Id);record_id=[string]$event.RecordId}}
}
function Get-BootTime($events=$null){
 if($null -eq $events){$events=@(Get-PowerEvents)}
 $latest=$events|Where-Object {$_.kind -in @('boot','resume')}|Sort-Object at -Descending|Select-Object -First 1
 if($latest){return $latest.at}
 return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
}
function Event-Key($event){return ($event.kind+'|'+$event.at+'|'+$event.source)}
function Write-State($items){
 $text=ConvertTo-Json -InputObject @($items) -Compress
 [IO.File]::WriteAllText($statePath+'.tmp',$text,[Text.Encoding]::UTF8)
 Move-Item ($statePath+'.tmp') $statePath -Force
}
$installRoot=Join-Path $env:ProgramData 'CloudshopAttendance'
$mutex=New-Object Threading.Mutex($false,'Global\CloudshopAttendance')
if(-not $mutex.WaitOne(0)){exit}
try{
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 Add-Type -AssemblyName System.Security
 $token=[Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes((Join-Path $installRoot 'device.bin')),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine))
 $endpoint='https://tmxluzvymwldtxbaiekn.supabase.co/functions/v1/attendance-device'
 $statePath=Join-Path $installRoot 'events-acknowledged.json'
 $logPath=Join-Path $installRoot 'status.log'
 function Write-Status($message){
  if((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 100000){Move-Item $logPath ($logPath+'.old') -Force}
  Add-Content -Path $logPath -Value ((Get-Date).ToString('s')+' '+$message) -Encoding UTF8
 }
 $acknowledged=@()
 if(Test-Path $statePath){try{$decoded=Get-Content $statePath -Raw|ConvertFrom-Json;$acknowledged=@($decoded)}catch{Copy-Item $statePath ($statePath+'.invalid') -Force}}
 Write-Status 'Версия 1.1: учёт загрузок, выключений и выхода из сна запущен.'
 while($true){
  try{
   # Re-read every minute: a process can survive Windows hibernation with yesterday's cached boot time.
   $events=@(Get-PowerEvents|Sort-Object at)
   $boot=Get-BootTime $events
   $new=@($events|Where-Object {$acknowledged -notcontains (Event-Key $_)})
   for($offset=0;$offset -lt $new.Count;$offset+=64){
    $batch=@($new|Select-Object -Skip $offset -First 64)
    $body=@{action='events';payload=@{events=$batch;version='1.1.0'}}|ConvertTo-Json -Compress -Depth 5
    $result=Invoke-RestMethod -Uri $endpoint -Method Post -Headers @{'x-device-token'=$token} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 25
    if(-not $result.result.saved){throw 'No acknowledgement'}
    foreach($event in $batch){$acknowledged+=,(Event-Key $event)}
    Write-State $acknowledged
   }
   # Heartbeats never infer shutdown from absence of connectivity. No technical Telegram messages.
   $body=@{action='report';payload=@{boot_at=$boot;version='1.1.0'}}|ConvertTo-Json -Compress
   $result=Invoke-RestMethod -Uri $endpoint -Method Post -Headers @{'x-device-token'=$token} -ContentType 'application/json' -Body $body -TimeoutSec 25
   if(-not $result.result.saved){throw 'No acknowledgement'}
   # Bound the acknowledgment cache to Windows events still in the 30-day scan.
   $present=@($events|ForEach-Object {Event-Key $_});$acknowledged=@($acknowledged|Where-Object {$present -contains $_});Write-State $acknowledged
   Write-Status 'События Windows и текущее время запуска переданы. Следующая проверка через минуту.'
   Start-Sleep -Seconds 60
  }catch{
   Write-Status 'Нет подтверждения сервера. События сохраняются в журнале Windows; повтор через 60 секунд.'
   Start-Sleep -Seconds 60
  }
 }
}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
