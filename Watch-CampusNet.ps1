#Requires -Version 5.1
<#
=============================================================================
 Watch-CampusNet.ps1  —— 校园网认证守护进程

 干的事:
   · 常驻内存, 每隔 N 秒用【绕过系统代理】的直连请求检测联网状态
   · 监听 Windows 网络状态变化事件, 断网/切换网络立刻响应, 不等轮询
   · 一旦发现未认证, 调用 CampusNetLogin.ps1 完成认证
   · 连续失败次数多了会退避到长间隔, 避免把账号往锁定上撞
   · 单实例(Mutex), 不会重复起一堆

 为什么不用计划任务做主力:
   注册计划任务一般要管理员权限; 启动文件夹不需要,
   而且常驻进程配合网络事件能做到秒级响应, 比 5 分钟一次的计划任务灵敏。

 用法(一般由 Install-AutoLogin.ps1 自动拉起, 不需要手动跑):
   powershell -NoProfile -ExecutionPolicy Bypass -File Watch-CampusNet.ps1
   powershell ... -File Watch-CampusNet.ps1 -IntervalSec 60 -Verbose

 本文件必须保存为 UTF-8 with BOM。
=============================================================================
#>
[CmdletBinding()]
param(
    [int]$IntervalSec    = 20,    # 已在线时的轮询间隔
    [int]$OfflineSec     = 6,     # 未在线时的重试间隔
    [int]$FailBackoffSec = 300,   # 连续失败后的长退避间隔
    [int]$FailThreshold  = 5,     # 连续失败多少次开始退避
    [string]$LoginScript,
    [string]$LogDir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch { }

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
if (-not $LoginScript) { $LoginScript = Join-Path $ScriptRoot 'CampusNetLogin.ps1' }
if (-not $LogDir)      { $LogDir      = Join-Path $ScriptRoot 'logs' }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$script:LogFile   = Join-Path $LogDir ('watch-{0:yyyyMMdd}.log' -f (Get-Date))
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-WLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1,-5}] {2}' -f (Get-Date), $Level, $Message
    try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", $script:Utf8NoBom) } catch { }
}

# ---------------------------------------------------------------------------
# 单实例锁
# ---------------------------------------------------------------------------
$mutex = $null
$haveLock = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\CampusNetWatch_Seagull')
    $haveLock = $mutex.WaitOne(0, $false)
} catch {
    # Global\ 前缀在受限环境下可能失败, 退回到 Local\
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'CampusNetWatch_Seagull')
        $haveLock = $mutex.WaitOne(0, $false)
    } catch { $haveLock = $true }
}
if (-not $haveLock) {
    Write-WLog '已有一个守护进程在跑, 本实例退出' 'WARN'
    exit 0
}

# ---------------------------------------------------------------------------
# 直连联网检测(不走系统代理 —— 本机有 Clash 127.0.0.1:7897)
# ---------------------------------------------------------------------------
function Test-WatchOnline {
    $checks = @(
        @{ Url = 'http://www.msftconnecttest.com/connecttest.txt'; Expect = '200:Microsoft Connect Test' },
        @{ Url = 'http://connect.rom.miui.com/generate_204';       Expect = '204:' }
    )
    foreach ($c in $checks) {
        $req = $null
        try {
            $req = [System.Net.HttpWebRequest]::Create($c.Url)
            $req.Method            = 'GET'
            $req.AllowAutoRedirect = $false
            $req.Timeout           = 5000
            $req.ReadWriteTimeout  = 5000
            $req.KeepAlive         = $false
            $req.Proxy             = $null
            $req.UserAgent         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0'
            $resp = $null
            try { $resp = $req.GetResponse() } catch { }
            if ($resp) {
                $code = [int]$resp.StatusCode
                $body = ''
                try {
                    $s = $resp.GetResponseStream()
                    $sr = New-Object System.IO.StreamReader($s)
                    $body = $sr.ReadToEnd()
                    $sr.Close()
                } catch { }
                try { $resp.Close() } catch { }

                if ($code -eq 204) { return $true }
                if ($code -eq 200 -and $body -match 'Microsoft Connect Test') { return $true }
                # 200 但内容是别的东西 / 3xx 跳转 => 被 portal 劫持了
            }
        } catch { }
        finally { if ($req) { try { $req.Abort() } catch { } } }
    }
    return $false
}

# ---------------------------------------------------------------------------
# 调用认证脚本
# ---------------------------------------------------------------------------
function Invoke-LoginOnce {
    if (-not (Test-Path $LoginScript)) {
        Write-WLog ('认证脚本不存在: ' + $LoginScript) 'ERROR'
        return 99
    }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $exe)) { $exe = 'powershell.exe' }
    $psArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden', '-File', ('"' + $LoginScript + '"'), '-Quiet'
    )
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $psArgs -WindowStyle Hidden -PassThru -Wait
        return $p.ExitCode
    } catch {
        Write-WLog ('拉起认证脚本失败: ' + $_.Exception.Message) 'ERROR'
        return 98
    }
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------
Write-WLog '================ 校园网守护进程启动 ================' 'OK'
Write-WLog ('认证脚本   : ' + $LoginScript)
Write-WLog ('在线轮询   : {0}s   离线重试: {1}s   失败退避: {2}s' -f $IntervalSec, $OfflineSec, $FailBackoffSec)
Write-WLog '代理策略   : 直连(强制绕过系统代理)'

$failCount  = 0
$lastState  = $null
$netChanged = $false

# 注册网络变化事件, 让断网/切网能立刻响应
$subs = @()
foreach ($evt in @('NetworkAvailabilityChanged','NetworkAddressChanged')) {
    try {
        $sub = Register-ObjectEvent -InputObject ([System.Net.NetworkInformation.NetworkChange]) `
                                    -EventName $evt -SourceIdentifier ('CampusNet_' + $evt) `
                                    -ErrorAction Stop
        $subs += ('CampusNet_' + $evt)
        Write-WLog ('已订阅网络事件: ' + $evt) 'INFO'
    } catch {
        Write-WLog ('订阅网络事件失败(不影响轮询): {0} - {1}' -f $evt, $_.Exception.Message) 'DEBUG'
    }
}

$stop = $false
while (-not $stop) {

    # 处理事件队列
    $netChanged = $false
    foreach ($sid in $subs) {
        $q = Get-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue
        if ($q) {
            $netChanged = $true
            $q | Remove-Event -ErrorAction SilentlyContinue
        }
    }
    if ($netChanged) { Write-WLog '检测到网络状态变化事件' 'INFO' }

    $online = Test-WatchOnline

    if ($online) {
        if ($lastState -ne 'ONLINE') {
            Write-WLog '网络状态: 已在线' 'OK'
            $lastState = 'ONLINE'
        }
        $failCount = 0
        Start-Sleep -Seconds $IntervalSec
        continue
    }

    # 不在线 -> 认证
    Write-WLog '网络状态: 未认证/无网络, 触发自动登录' 'WARN'
    $lastState = 'OFFLINE'

    $code = Invoke-LoginOnce
    Write-WLog ('认证脚本退出码: ' + $code) $(if ($code -eq 0) { 'OK' } else { 'ERROR' })

    if ($code -eq 0) {
        $failCount = 0
        Start-Sleep -Seconds 3
        if (Test-WatchOnline) {
            Write-WLog '认证后复核通过' 'OK'
            $lastState = 'ONLINE'
            Start-Sleep -Seconds $IntervalSec
            continue
        }
        Write-WLog '认证报成功但复核仍未通' 'WARN'
    } else {
        $failCount++
    }

    if ($failCount -ge $FailThreshold) {
        Write-WLog ('连续失败 {0} 次, 退避 {1} 秒后再试 (检查密码是否正确)' -f $failCount, $FailBackoffSec) 'ERROR'
        Start-Sleep -Seconds $FailBackoffSec
        $failCount = 0
    } else {
        Start-Sleep -Seconds $OfflineSec
    }
}

foreach ($sid in $subs) {
    Unregister-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue
}
if ($mutex -and $haveLock) {
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
Write-WLog '守护进程退出' 'WARN'
