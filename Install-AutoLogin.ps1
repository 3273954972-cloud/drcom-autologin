#Requires -Version 5.1
<#
=============================================================================
 Install-AutoLogin.ps1  —— 一键装机 / 卸载 / 查看状态

 装完效果:
   · 开机登录 Windows 后, 守护进程静默启动, 自动完成校园网认证
   · 平时常驻后台, 掉线/换网会秒级自动重连, 你不用再点那个登录页
   · 全程无需管理员权限(主方案走启动文件夹)
   · 如果你有管理员权限, 会额外注册一个计划任务做冗余

 用法:
   powershell -ExecutionPolicy Bypass -File Install-AutoLogin.ps1
   powershell -ExecutionPolicy Bypass -File Install-AutoLogin.ps1 -TestNow
   powershell -ExecutionPolicy Bypass -File Install-AutoLogin.ps1 -Status
   powershell -ExecutionPolicy Bypass -File Install-AutoLogin.ps1 -Uninstall

 本文件必须保存为 UTF-8 with BOM。
=============================================================================
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$TestNow,
    [switch]$NoScheduledTask,   # 只装启动文件夹, 不尝试注册计划任务
    [string]$InstallDir
)

$ErrorActionPreference = 'Continue'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
if (-not $InstallDir) { $InstallDir = $ScriptRoot }

$LoginScript  = Join-Path $InstallDir 'CampusNetLogin.ps1'
$WatchScript  = Join-Path $InstallDir 'Watch-CampusNet.ps1'
$ConfigPath   = Join-Path $InstallDir 'config.json'
$StartupDir   = [Environment]::GetFolderPath('Startup')
$LauncherPath = Join-Path $StartupDir 'CampusNet自动认证.vbs'
$TaskName     = 'CampusNet-AutoLogin'

function Say { param([string]$m, [string]$c = 'Gray') Write-Host $m -ForegroundColor $c }

# ---------------------------------------------------------------------------
function New-Launcher {
    param([string]$Path)
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # 注意: 不要在 VBS 里直接拼双引号, 用 Chr(34) 才不会被外层引号咬到
    $vbs = @"
' 校园网自动认证 - 开机静默启动守护进程
' 由 Install-AutoLogin.ps1 生成于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Option Explicit
Dim sh, q, psExe, scriptPath, cmd
Set sh = CreateObject("WScript.Shell")
q = Chr(34)
psExe = "$psExe"
scriptPath = "$WatchScript"
cmd = q & psExe & q & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & scriptPath & q
sh.Run cmd, 0, False
"@
    $utf8 = New-Object System.Text.UTF8Encoding($true)   # VBS 带 BOM, WSH 才认 UTF-8
    [System.IO.File]::WriteAllText($Path, $vbs, $utf8)
}

function Get-WatcherProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'Watch-CampusNet\.ps1' }
}

function Start-Watcher {
    $running = @(Get-WatcherProcess)
    if ($running.Count -gt 0) {
        Say ('守护进程已在运行 (PID: ' + ($running.ProcessId -join ',') + ')') 'Yellow'
        return
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
           '-File', ('"' + $WatchScript + '"'))
    Start-Process -FilePath $psExe -ArgumentList $a -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 2
    $running = @(Get-WatcherProcess)
    if ($running.Count -gt 0) {
        Say ('守护进程已启动 (PID: ' + ($running.ProcessId -join ',') + ')') 'Green'
    } else {
        Say '守护进程启动失败, 请手动运行 Watch-CampusNet.ps1 看报错' 'Red'
    }
}

function Stop-Watcher {
    $running = @(Get-WatcherProcess)
    if ($running.Count -eq 0) { Say '守护进程未在运行' 'DarkGray'; return }
    foreach ($p in $running) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Say ('已结束守护进程 PID ' + $p.ProcessId) 'Green' }
        catch { Say ('结束 PID ' + $p.ProcessId + ' 失败: ' + $_.Exception.Message) 'Red' }
    }
}

function Install-ScheduledTask {
    if ($NoScheduledTask) { return }
    Say ''
    Say '---- 尝试注册计划任务(冗余, 需要管理员权限) ----'
    try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $psExe `
            -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $LoginScript + '" -Quiet')

        $t1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(2) `
                -RepetitionInterval (New-TimeSpan -Minutes 5)

        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) `
            -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($t1, $t2) `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Say ('计划任务已注册: ' + $TaskName) 'Green'
    } catch {
        Say ('计划任务注册失败(通常是没管理员权限): ' + $_.Exception.Message) 'Yellow'
        Say '  不影响使用 —— 主方案走启动文件夹, 不需要管理员权限。' 'Yellow'
        Say '  想要冗余就右键以管理员身份重跑本脚本。' 'Yellow'
    }
}

# ===========================================================================
if ($Status) {
    Say ''
    Say '============ 校园网自动认证 安装状态 ============' 'Cyan'
    Say ('安装目录   : ' + $InstallDir)
    Say ('认证脚本   : ' + $(if (Test-Path $LoginScript) { '正常' } else { '缺失!' })) $(if (Test-Path $LoginScript) { 'Green' } else { 'Red' })
    Say ('守护脚本   : ' + $(if (Test-Path $WatchScript) { '正常' } else { '缺失!' })) $(if (Test-Path $WatchScript) { 'Green' } else { 'Red' })
    Say ('配置文件   : ' + $(if (Test-Path $ConfigPath) { '正常' } else { '未生成(请先 -Setup)' })) $(if (Test-Path $ConfigPath) { 'Green' } else { 'Yellow' })

    $cred = Join-Path $InstallDir 'credential.xml'
    Say ('凭据文件   : ' + $(if (Test-Path $cred) { '已保存(DPAPI加密)' } else { '未设置!' })) $(if (Test-Path $cred) { 'Green' } else { 'Red' })

    Say ('开机启动项 : ' + $(if (Test-Path $LauncherPath) { '已安装' } else { '未安装' })) $(if (Test-Path $LauncherPath) { 'Green' } else { 'Yellow' })
    if (Test-Path $LauncherPath) { Say ('             ' + $LauncherPath) 'DarkGray' }

    $running = @(Get-WatcherProcess)
    Say ('守护进程   : ' + $(if ($running.Count -gt 0) { '运行中 PID ' + ($running.ProcessId -join ',') } else { '未运行' })) $(if ($running.Count -gt 0) { 'Green' } else { 'Yellow' })

    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Say ('计划任务   : ' + $t.State) 'Green'
    } catch { Say '计划任务   : 未注册' 'DarkGray' }

    Say ''
    if (Test-Path $LoginScript) {
        Say '---- 当前在线信息 ----'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LoginScript -Status
    }
    Say ''
    exit 0
}

if ($Uninstall) {
    Say ''
    Say '============ 卸载 ============' 'Cyan'
    if (Test-Path $LauncherPath) {
        Remove-Item -LiteralPath $LauncherPath -Force -ErrorAction SilentlyContinue
        Say '已删除开机启动项' 'Green'
    } else { Say '开机启动项不存在' 'DarkGray' }

    Stop-Watcher

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Say '已删除计划任务' 'Green'
    } catch { Say '计划任务不存在或无权删除' 'DarkGray' }

    Say ''
    Say '卸载完成。配置文件、凭据、日志都保留着, 想彻底清掉手动删除整个目录即可:' 'Yellow'
    Say ('  ' + $InstallDir) 'Yellow'
    Say ''
    exit 0
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
Say ''
Say '========= 校园网自动认证 安装程序 =========' 'Cyan'
Say ''

# 0. 前置检查
$missing = @()
foreach ($f in @($LoginScript, $WatchScript)) {
    if (-not (Test-Path $f)) { $missing += $f }
}
if ($missing.Count -gt 0) {
    Say '缺少必需文件:' 'Red'
    $missing | ForEach-Object { Say ('  ' + $_) 'Red' }
    exit 2
}

# 1. 没有配置就先引导配置(优先走安装向导, 它会自动识别 portal)
if (-not (Test-Path $ConfigPath) -or -not (Test-Path (Join-Path $InstallDir 'credential.xml'))) {
    $setupScript = Join-Path $InstallDir 'CampusNetSetup.ps1'
    Say '还没配置账号, 先跑安装向导:' 'Yellow'
    if (Test-Path $setupScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -NoInstall
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LoginScript -Setup
    }
    if ($LASTEXITCODE -ne 0) { Say '配置未完成, 安装中止' 'Red'; exit 2 }
    Say ''
}

# 2. 自检
Say '---- 运行自检 ----'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LoginScript -SelfTest
if ($LASTEXITCODE -ne 0) {
    Say ''
    Say '自检未通过。如果你的学校改了 portal 或认证接口, 需要重新适配。' 'Red'
    Say '可以照样安装, 但能不能用不保证。' 'Yellow'
    Say ''
}

# 3. 立刻测一次
if ($TestNow) {
    Say ''
    Say '---- 立即执行一次认证 ----'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LoginScript
    Say ('退出码: ' + $LASTEXITCODE) $(if ($LASTEXITCODE -eq 0) { 'Green' } else { 'Red' })
}

# 4. 装开机启动项
Say ''
Say '---- 安装开机启动项 ----'
try {
    New-Launcher -Path $LauncherPath
    Say ('已创建: ' + $LauncherPath) 'Green'
} catch {
    Say ('创建启动项失败: ' + $_.Exception.Message) 'Red'
    Say '手工方案: 把下面这行做成快捷方式丢进 shell:startup' 'Yellow'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Say ('  "{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $psExe, $WatchScript) 'Yellow'
}

# 5. 拉起守护进程
Say ''
Say '---- 启动守护进程 ----'
Start-Watcher

# 6. 冗余计划任务
Install-ScheduledTask

Say ''
Say '========= 安装完成 =========' 'Green'
Say ''
Say ('安装目录 : ' + $InstallDir)
Say ('日志目录 : ' + (Join-Path $InstallDir 'logs'))
Say ''
Say '常用命令:' 'Cyan'
Say '  查看状态 : powershell -ExecutionPolicy Bypass -File Install-AutoLogin.ps1 -Status'
Say '  立即认证 : powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1'
Say '  改密码   : powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1 -Setup'
Say '  卸载     : powershell -ExecutionPolicy Bypass -File Install-AutoLogin.ps1 -Uninstall'
Say ''
exit 0
