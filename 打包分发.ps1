#Requires -Version 5.1
<#
=============================================================================
 打包分发.ps1  —— 生成一个干净的、可以发给同学的目录

 会剔除全部隐私数据:
   credential.xml        你的密码
   config.json           你的学号
   last-querystring.txt  会话参数缓存
   logs\                 运行日志
   portal-probe\         逆向证据
   campus-net-dist\      上一次打包的产物

 用法:
   powershell -ExecutionPolicy Bypass -File 打包分发.ps1
   powershell -ExecutionPolicy Bypass -File 打包分发.ps1 -Zip
   powershell -ExecutionPolicy Bypass -File 打包分发.ps1 -OutDir D:\share\campus-net

 本文件必须保存为 UTF-8 with BOM。
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [switch]$Zip,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $ScriptRoot) 'campus-net-dist' }

$include = @(
    '一键安装.cmd',
    'CampusNetSetup.ps1',
    'CampusNetLogin.ps1',
    'Watch-CampusNet.ps1',
    'Install-AutoLogin.ps1',
    'capture-portal.ps1',
    '打包分发.ps1',
    'README.md'
)

$excludePattern = '(?i)^(credential\.xml|config\.json|last-querystring\.txt)$'

Write-Host ''
Write-Host '==== 打包分发 ====' -ForegroundColor Cyan
Write-Host ('源目录 : ' + $ScriptRoot)
Write-Host ('输出   : ' + $OutDir)
Write-Host ''

if (Test-Path $OutDir) {
    if (-not $Force) {
        $ans = Read-Host ('输出目录已存在, 覆盖它吗? [y/N]')
        if ($ans -notmatch '^(y|Y|yes|YES)$') { Write-Host '已取消'; exit 0 }
    }
    Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$copied = 0
$skipped = New-Object System.Collections.Generic.List[string]

foreach ($name in $include) {
    $src = Join-Path $ScriptRoot $name
    if (-not (Test-Path $src)) { $skipped.Add($name + '  (源文件不存在)'); continue }
    Copy-Item -LiteralPath $src -Destination (Join-Path $OutDir $name) -Force -ErrorAction SilentlyContinue
    Write-Host ('  + ' + $name) -ForegroundColor Green
    $copied++
}

# 兜底: 复制其它 .ps1 / .cmd / .md, 但跳过隐私文件(万一以后加了新脚本)
Get-ChildItem $ScriptRoot -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '(?i)^\.(ps1|cmd|bat|md)$' } |
    Where-Object { $include -notcontains $_.Name } |
    Where-Object { $_.Name -notmatch $excludePattern } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $OutDir $_.Name) -Force -ErrorAction SilentlyContinue
        Write-Host ('  + ' + $_.Name) -ForegroundColor Green
        $copied++
    }

# 预生成一份不含学号的默认 config.json, 让首次运行更顺
$defaultCfg = [pscustomobject]@{
    PortalScheme    = 'http'
    PortalHost      = 'portal.example.edu.cn'
    PortalPath      = '/eportal/'
    Service         = ''
    UserId          = ''
    ProbeUrls       = @(
        'http://www.msftconnecttest.com/connecttest.txt',
        'http://connect.rom.miui.com/generate_204',
        'http://223.5.5.5/',
        'http://1.1.1.1/'
    )
    OnlineCheckUrls = @(
        'http://www.msftconnecttest.com/connecttest.txt',
        'http://connect.rom.miui.com/generate_204'
    )
    UseSystemProxy  = $false
    LoginRetries    = 3
    RetryDelaySec   = 4
    LogKeepDays     = 30
    LogDir          = ''
}
$json = $defaultCfg | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText((Join-Path $OutDir 'config.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '  + config.json  (已清空学号和服务名)' -ForegroundColor Green

# 隐私检查
Write-Host ''
Write-Host '---- 隐私检查 ----' -ForegroundColor Cyan
$leak = $false
$bad = @('credential.xml','last-querystring.txt')
foreach ($b in $bad) {
    if (Test-Path (Join-Path $OutDir $b)) { Write-Host ('  !! 泄漏: ' + $b) -ForegroundColor Red; $leak = $true }
}
foreach ($d in @('logs','portal-probe')) {
    if (Test-Path (Join-Path $OutDir $d)) { Write-Host ('  !! 泄漏目录: ' + $d) -ForegroundColor Red; $leak = $true }
}
$cfgOut = Join-Path $OutDir 'config.json'
if (Test-Path $cfgOut) {
    $c = Get-Content $cfgOut -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($c.UserId) { Write-Host ('  !! config.json 里还有学号: ' + $c.UserId) -ForegroundColor Red; $leak = $true }
}
if (-not $leak) { Write-Host '  干净, 没有发现你的个人信息' -ForegroundColor Green }

if ($Zip) {
    $zipPath = $OutDir + '.zip'
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
    try {
        Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -Force -ErrorAction Stop
        Write-Host ''
        Write-Host ('已打包: ' + $zipPath) -ForegroundColor Green
    } catch {
        Write-Host ('压缩失败: ' + $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ('完成, 共 ' + $copied + ' 个文件') -ForegroundColor Green
Write-Host ('对方拿到后双击 "一键安装.cmd" 即可。') -ForegroundColor Gray
Write-Host ''
exit 0
