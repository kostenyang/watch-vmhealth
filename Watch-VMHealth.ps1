<#
.SYNOPSIS
    監看 vCenter 裡的 VM,壞掉(guest 沒回應 / 開機卡住)就自動重開。
.DESCRIPTION
    判定「壞掉」的依據(VM 必須是 poweredOn 且 host 連線正常):
      1. VMware Tools 有裝,但 ToolsRunningStatus 不是 guestToolsRunning,或 GuestHeartbeatStatus 為 red/gray
         → guest 當機、或重開後卡在開機畫面起不來
      2. (-Ping / -TcpPort) guest IP ICMP 不通、且指定的 TCP port 都連不上
         IP 來源:-PingMap 指定 > Tools 回報 > (-ResolveDns) 以 VM 名稱查 DNS
      3. (-PowerOnIfOff) VM 意外處於 poweredOff → 直接開機
    保護機制:
      * 開機後 -BootGraceMinutes 內不判定(給開機時間)
      * 要連續 -FailThreshold 次檢查都失敗才動手(狀態存在 -StatePath,一次性排程也能累計)
      * 同一台 VM 在 -CooldownMinutes 內不重複重開;24 小時內最多重開 -MaxResetsPerDay 次
    重開方式:Tools 還活著 → Restart-VMGuest(正常重開);Tools 死了 → Restart-VM(硬重置)。
.EXAMPLE
    # 一次性檢查(給 Windows 排程每 5 分鐘跑一次),先看會做什麼不真的動手
    pwsh ./Watch-VMHealth.ps1 -Server vc01.example.com -Credential (Get-Credential) -VmName 'app-*' -DryRun
.EXAMPLE
    # 常駐模式,每 60 秒檢查,連續 3 次失敗才硬重置;只監看貼了 AutoRestart 標籤的 VM
    pwsh ./Watch-VMHealth.ps1 -Server vc01.example.com -Credential $cred -Tag AutoRestart -Ping -Loop -IntervalSeconds 60
.EXAMPLE
    # 沒裝 Tools 的 VM:指定 IP 用 ping 判定
    pwsh ./Watch-VMHealth.ps1 -Server vc01.example.com -Credential $cred -VmName 'legacy01' -Ping -PingMap @{ legacy01 = '10.0.0.50' }
.EXAMPLE
    # 沒裝 Tools 的 VM:VM 名稱查 DNS 取 IP,改用 TCP port(SSH / RDP)判定,不怕 ICMP 被擋
    pwsh ./Watch-VMHealth.ps1 -Server vc01.example.com -Credential $cred -Tag AutoRestart -ResolveDns -DnsSuffix example.com -TcpPort 22,3389 -Loop
.NOTES
    需求:PowerShell 7.x + VMware.PowerCLI 13.x。
    vCenter 帳號最小權限:VirtualMachine.Interact.PowerOn / PowerOff / Reset、System.Read(唯讀+電源操作即可)。
    管理元件(vCenter / NSX / SDDC Manager 等)請用 -Exclude 明確排除,或用 -Tag / -VmName 只框住服務 VM。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $Server,    # vCenter FQDN / IP
  [pscredential] $Credential,                 # 建議用這個;沒給則用 -User/-Password;都沒給會互動詢問
  [string]   $User,
  [string]   $Password,
  [string[]] $VmName     = @('*'),            # wildcard,可多個
  [string[]] $Tag,                            # 只監看貼了這些 vSphere Tag 的 VM(與 -VmName 交集)
  [string[]] $Exclude    = @('vCLS*','SupervisorControlPlaneVM*'),
  [int]      $FailThreshold    = 3,           # 連續失敗幾次才重開
  [int]      $BootGraceMinutes = 10,          # 開機後幾分鐘內不判定
  [int]      $CooldownMinutes  = 30,          # 重開後多久內不再重開
  [int]      $MaxResetsPerDay  = 3,
  [switch]   $Ping,                           # 額外用 ICMP 判定
  [int[]]    $TcpPort,                        # 額外用 TCP 連線判定(任一 port 通就算可達),例如 22,3389,443
  [hashtable]$PingMap    = @{},               # VM 名 → IP,沒 Tools 的 VM 用
  [switch]   $ResolveDns,                     # 沒 Tools 也沒 PingMap 時,用 VM 名稱查 DNS 取 IP
  [string]   $DnsSuffix,                      # -ResolveDns 時附加的網域,例如 example.com
  [switch]   $PowerOnIfOff,                   # poweredOff 也視為壞掉並開機
  [switch]   $Loop,
  [int]      $IntervalSeconds = 60,
  [switch]   $DryRun,
  [string]   $LogPath   = "$PSScriptRoot\watch-vmhealth.log",
  [string]   $StatePath = "$PSScriptRoot\watch-vmhealth.state.json"
)
$ErrorActionPreference = 'Stop'
function Log($m, $lvl = 'INFO') {
  $line = "{0}  [{1}] {2}" -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'), $lvl, $m
  Write-Host $line
  Add-Content -Path $LogPath -Value $line -Encoding utf8
}

# ---------- 狀態(連續失敗計數 / 重開紀錄)----------
function Load-State {
  if (Test-Path $StatePath) {
    try { $raw = Get-Content $StatePath -Raw | ConvertFrom-Json -AsHashtable; if ($raw) { return $raw } } catch {}
  }
  return @{}
}
function Save-State($s) { $s | ConvertTo-Json -Depth 5 | Set-Content $StatePath -Encoding utf8 }
function Get-VmState($s, $name) {
  if (-not $s.ContainsKey($name)) { $s[$name] = @{ fails = 0; lastReason = ''; resets = @() } }
  return $s[$name]
}

# ---------- 網路可達性 ----------
function Resolve-VmIp($name) {
  $fqdn = if ($DnsSuffix -and $name -notlike "*.$DnsSuffix") { "$name.$DnsSuffix" } else { $name }
  try {
    $a = [System.Net.Dns]::GetHostAddresses($fqdn) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
    if ($a) { return $a.IPAddressToString }
  } catch {}
  return $null
}
function Test-TcpPort($ip, $port, $timeoutMs = 2000) {
  $c = [System.Net.Sockets.TcpClient]::new()
  try {
    $r = $c.ConnectAsync($ip, $port)
    if ($r.Wait($timeoutMs) -and $c.Connected) { return $true }
  } catch {} finally { $c.Dispose() }
  return $false
}

# ---------- 健康判定 ----------
function Test-VmHealth($vm, $st) {
  # 回傳 @{ Healthy=bool; Reason=string; Skip=bool; ToolsAlive=bool }
  $x  = $vm.ExtensionData
  $rt = $x.Runtime; $g = $x.Guest
  if ($rt.ConnectionState -ne 'connected') { return @{ Skip = $true; Reason = "VM $($rt.ConnectionState)(host 問題,不處理)" } }

  if ($rt.PowerState -eq 'poweredOff') {
    if ($PowerOnIfOff) { return @{ Healthy = $false; Reason = 'poweredOff'; ToolsAlive = $false; PowerOn = $true } }
    return @{ Skip = $true; Reason = 'poweredOff(未啟用 -PowerOnIfOff)' }
  }
  if ($rt.PowerState -eq 'suspended') { return @{ Skip = $true; Reason = 'suspended' } }
  if ($rt.Question) { Log "$($vm.Name) 有待回答的問題: $($rt.Question.Text)" 'WARN' }

  # 開機寬限期:取 vCenter BootTime 與「我們上次重開時間」較晚者
  # (實測 Restart-VM 硬重置不會更新 Runtime.BootTime,只靠 BootTime 會在重置後馬上又誤判)
  $since = $null
  if ($rt.BootTime) { $since = $rt.BootTime.ToUniversalTime() }
  if ($st.resets.Count -gt 0) {
    $last = ($st.resets | ForEach-Object { ([DateTime]$_).ToUniversalTime() } | Sort-Object | Select-Object -Last 1)
    if (-not $since -or $last -gt $since) { $since = $last }
  }
  if ($since) {
    $up = [DateTime]::UtcNow - $since
    if ($up.TotalMinutes -lt $BootGraceMinutes) {
      return @{ Skip = $true; Reason = ("開機/重開才 {0:N1} 分鐘,寬限中" -f $up.TotalMinutes) }
    }
  }

  $toolsInstalled = $g.ToolsVersionStatus2 -ne 'guestToolsNotInstalled' -and $g.ToolsStatus -ne 'toolsNotInstalled'
  $toolsAlive     = $g.ToolsRunningStatus -eq 'guestToolsRunning'
  $hb             = $x.GuestHeartbeatStatus
  $reasons = @()

  if ($toolsInstalled) {
    if (-not $toolsAlive)          { $reasons += "Tools $($g.ToolsRunningStatus)" }
    elseif ($hb -in 'red','gray')  { $reasons += "heartbeat $hb" }
  }

  # 網路可達性判定(-Ping ICMP / -TcpPort TCP 連線,任一通就算可達)
  # 目標 IP 來源優先序:-PingMap 指定 > Tools 回報 > (-ResolveDns) 以 VM 名稱查 DNS
  $ip = $null; $reachChecked = $false; $reach = $false
  if ($Ping -or $TcpPort) {
    if ($PingMap.ContainsKey($vm.Name)) { $ip = $PingMap[$vm.Name] }
    elseif ($g.IpAddress -and $g.IpAddress -match '^\d+\.\d+\.\d+\.\d+$') { $ip = $g.IpAddress }
    elseif ($ResolveDns) { $ip = Resolve-VmIp $vm.Name }
    if ($ip) {
      $checks = @(); $reach = $false; $reachChecked = $true
      if ($Ping) {
        $ok = Test-Connection -TargetName $ip -Count 2 -TimeoutSeconds 2 -Quiet -ErrorAction SilentlyContinue
        if ($ok) { $reach = $true } else { $checks += 'ping' }
      }
      if ($TcpPort -and -not $reach) {
        foreach ($port in $TcpPort) { if (Test-TcpPort $ip $port) { $reach = $true; break } }
        if (-not $reach) { $checks += "tcp $($TcpPort -join '/')" }
      }
      if (-not $reach) { $reasons += "$ip $($checks -join ' 與 ') 不通" }
    }
  }
  # 網路可達 = guest 活著,優先於 Tools 判定。
  # 實測:移除 Tools 後 vCenter 仍回報 toolsNotRunning / guestToolsUnmanaged(舊值殘留,不會變 toolsNotInstalled),
  # 只看 Tools 會把「沒 Tools 但服務正常」的 VM 當成當機一直重開。
  if ($reachChecked -and $reach) { return @{ Healthy = $true; ToolsAlive = $toolsAlive } }

  # 完全沒判定依據(沒 Tools 也沒 IP)→ 不敢動
  if (-not $toolsInstalled -and -not $ip) { return @{ Skip = $true; Reason = '沒裝 Tools 也沒可達性目標(-PingMap / -ResolveDns),無法判定' } }

  if ($reasons.Count -eq 0) { return @{ Healthy = $true; ToolsAlive = $toolsAlive } }
  return @{ Healthy = $false; Reason = ($reasons -join '; '); ToolsAlive = $toolsAlive }
}

# ---------- 重開 ----------
function Invoke-Recover($vm, $h, $st) {
  $now = [DateTime]::Now
  $recent = @($st.resets | ForEach-Object { [DateTime]$_ } | Where-Object { $_ -gt $now.AddHours(-24) })
  if ($recent.Count -ge $MaxResetsPerDay) {
    Log "$($vm.Name) 24h 內已重開 $($recent.Count) 次,達上限 $MaxResetsPerDay,不再處理(請人工介入)" 'ERROR'; return
  }
  if ($recent.Count -gt 0 -and ($now - ($recent | Sort-Object | Select-Object -Last 1)).TotalMinutes -lt $CooldownMinutes) {
    Log "$($vm.Name) 距上次重開未滿 $CooldownMinutes 分鐘,冷卻中" 'WARN'; return
  }

  if ($h.PowerOn)          { $action = 'Start-VM(開機)' }
  elseif ($h.ToolsAlive)   { $action = 'Restart-VMGuest(正常重開)' }
  else                     { $action = 'Restart-VM(硬重置)' }
  Log "$($vm.Name) 連續 $($st.fails) 次不健康 [$($h.Reason)] → $action" 'ACTION'
  if ($DryRun) { Log "  (DryRun,未執行)"; return }

  try {
    if ($h.PowerOn)        { Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
    elseif ($h.ToolsAlive) { Restart-VMGuest -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
    else                   { Restart-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
    $st.resets = @($recent | ForEach-Object { $_.ToString('o') }) + $now.ToString('o')
    $st.fails  = 0
    Log "  $($vm.Name) $action 已送出"
  } catch {
    Log "  $($vm.Name) $action 失敗: $($_.Exception.Message)" 'ERROR'
  }
}

# ---------- 主流程 ----------
function Invoke-Check {
  $state = Load-State
  $vms = if ($Tag) { Get-VM -Server $script:vc -Tag $Tag -ErrorAction SilentlyContinue } else { Get-VM -Server $script:vc -Name $VmName -ErrorAction SilentlyContinue }
  $vms = $vms | Where-Object { $n = $_.Name
           ($VmName | Where-Object { $n -like $_ }) -and -not ($Exclude | Where-Object { $n -like $_ }) } |
         Sort-Object Name -Unique
  if (-not $vms) { Log "沒有符合的 VM: $($VmName -join ',')" 'WARN'; return }

  $sum = @{ ok = 0; bad = 0; skip = 0 }
  foreach ($vm in $vms) {
    $st = Get-VmState $state $vm.Name
    $h  = Test-VmHealth $vm $st
    if ($h.Skip) {
      $sum.skip++; Write-Verbose "$($vm.Name): skip - $($h.Reason)"
      continue
    }
    if ($h.Healthy) {
      $sum.ok++
      if ($st.fails -gt 0) { Log "$($vm.Name) 恢復正常(先前 $($st.fails) 次失敗)" }
      $st.fails = 0; $st.lastReason = ''
      continue
    }
    $sum.bad++
    $st.fails++; $st.lastReason = $h.Reason
    Log "$($vm.Name) 不健康 ($($st.fails)/$FailThreshold): $($h.Reason)" 'WARN'
    if ($st.fails -ge $FailThreshold) { Invoke-Recover $vm $h $st }
  }
  # 已不存在的 VM 從狀態移除
  foreach ($k in @($state.Keys)) { if ($k -notin $vms.Name) { $state.Remove($k) } }
  Save-State $state
  Log ("檢查完成: {0} 台, 正常 {1} / 異常 {2} / 略過 {3}" -f $vms.Count, $sum.ok, $sum.bad, $sum.skip)
}

Import-Module VMware.VimAutomation.Core | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null
Log ("=== Watch-VMHealth 啟動 server={0} vm={1} tag={2} threshold={3} grace={4}m ping={5} tcp={6} dns={7} dryrun={8} ===" -f $Server, ($VmName -join ','), ($Tag -join ','), $FailThreshold, $BootGraceMinutes, $Ping, ($TcpPort -join ','), $ResolveDns, $DryRun)
if (-not $Credential) {
  if ($User -and $Password) { $Credential = [pscredential]::new($User, (ConvertTo-SecureString $Password -AsPlainText -Force)) }
  else { $Credential = Get-Credential -Message "vCenter $Server 帳號" }
}
function Connect-Vc { Connect-VIServer -Server $Server -Credential $Credential -Force -WarningAction SilentlyContinue }
$script:vc = Connect-Vc
try {
  do {
    try { Invoke-Check }
    catch {
      Log "檢查發生例外: $($_.Exception.Message)" 'ERROR'
      # 連線斷了就重連
      if (-not $script:vc.IsConnected) {
        try { $script:vc = Connect-Vc; Log '已重新連線 vCenter' }
        catch { Log "重連失敗: $($_.Exception.Message)" 'ERROR' }
      }
    }
    if ($Loop) { Start-Sleep -Seconds $IntervalSeconds }
  } while ($Loop)
} finally {
  if ($script:vc) { Disconnect-VIServer $script:vc -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
}
