#Requires -Version 5.1
<#
    campus-net / capture-portal.ps1
    海鸥出品 —— 校园网 Portal 现场抓包器

    用途：
        在你的校园网掉线 / 重连的窗口期，自动捕获 captive portal 的
        跳转地址、响应头、页面 HTML，以及它加载的所有 JS/CSS/JSON 资源。
        这是后续写自动登录器所需的全部素材。

    为什么必须 no-proxy：
        本机开着系统代理 127.0.0.1:7897（Clash/Mihomo 类）。
        走代理的话请求会被代理吃掉，你抓到的是代理的响应，不是学校 portal。
        所以这里所有 HttpWebRequest 的 Proxy 一律置 null，强制直连。

    用法：
        Set-ExecutionPolicy -Scope Process Bypass -Force
        & '.\campus-net\capture-portal.ps1' -DurationMinutes 25
#>
[CmdletBinding()]
param(
    [int]$DurationMinutes = 25,
    [int]$IntervalSeconds  = 3,
    [string]$OutDir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---- 原生命令(ipconfig/netsh 等)输出是 GBK，不设这个就是一堆乱码 ----
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch { }
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch { }

# 未指定输出目录时落到脚本自己旁边的 logs\，不写死绝对路径
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $OutDir = Join-Path $scriptDir 'logs'
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$script:LogFile = Join-Path $OutDir ('capture-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$script:Quiet   = $false

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", $utf8)
    # stdout 只吐 ASCII，避免中文在管道里变乱码；中文细节看日志文件
    if ($Message -match '^[\x20-\x7E]*$') { Write-Output $line }
}

function Save-Text {
    param([string]$Path, [string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Convert-BytesToText {
    param([byte[]]$Bytes, [string]$CharsetHint)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }

    # 1) 严格 UTF-8 试一把，不合法就说明不是 UTF-8
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($Bytes)
    } catch { }

    # 2) 从 HTTP 头 / meta 标签里嗅探 charset
    $candidates = @()
    if ($CharsetHint) { $candidates += $CharsetHint }
    $latin = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    foreach ($m in [regex]::Matches($latin, '(?i)charset\s*=\s*["'']?([\w\-]+)')) {
        $candidates += $m.Groups[1].Value
    }
    foreach ($cs in ($candidates | Select-Object -Unique)) {
        try {
            $enc = [System.Text.Encoding]::GetEncoding($cs)
            return $enc.GetString($Bytes)
        } catch { }
    }

    # 3) 兜底 GB18030（国内校园网 portal 九成是 GBK 系）
    try { return [System.Text.Encoding]::GetEncoding(936).GetString($Bytes) } catch { }
    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Invoke-Probe {
    <#
        发一个 GET，返回结构化结果。
        -ProxyMode none  : 强制直连（默认，抓校园网必须用这个）
        -ProxyMode system: 走系统代理，用来对照诊断
    #>
    param(
        [string]$Url,
        [ValidateSet('none','system')][string]$ProxyMode = 'none',
        [int]$TimeoutMs = 6000
    )

    $r = [ordered]@{
        Url = $Url; Started = (Get-Date).ToString('HH:mm:ss.fff')
        StatusCode = $null; StatusDescription = ''; Location = ''
        ContentType = ''; Server = ''; BodyLength = 0
        BodyText = ''; Headers = ''; Error = ''; ProxyMode = $ProxyMode
    }

    $req = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method             = 'GET'
        $req.AllowAutoRedirect  = $false          # 关键：不跟跳转，才能读到 Location
        $req.Timeout            = $TimeoutMs
        $req.ReadWriteTimeout   = $TimeoutMs
        $req.KeepAlive          = $false
        $req.UserAgent          = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
        $req.Accept             = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        $req.Headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8'

        if ($ProxyMode -eq 'system') {
            # 手动从注册表读系统代理，避免 GetSystemWebProxy 在不同 .NET 下行为不一致
            $ps = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyServer
            if ($ps) {
                if ($ps -notmatch '^\w+://') { $ps = 'http://' + $ps }
                $req.Proxy = New-Object System.Net.WebProxy($ps)
            }
        } else {
            $req.Proxy = $null
        }

        $resp = $null
        try {
            $resp = $req.GetResponse()
        } catch [System.Net.WebException] {
            $r.Error = 'WebException: ' + $_.Exception.Message
            if ($_.Exception.Response) { $resp = $_.Exception.Response }
        }

        if ($resp) {
            $r.StatusCode        = [int]$resp.StatusCode
            $r.StatusDescription = [string]$resp.StatusDescription
            $r.ContentType       = [string]$resp.ContentType
            $r.Location          = [string]$resp.Headers['Location']
            $serverHdr           = $resp.Headers['Server']
            $r.Server            = if ($serverHdr) { [string]$serverHdr } else { '' }

            $hdrLines = @()
            foreach ($k in $resp.Headers.AllKeys) {
                $hdrLines += ('    {0}: {1}' -f $k, $resp.Headers[$k])
            }
            $r.Headers = ($hdrLines -join "`r`n")

            # 读 body（可能有 gzip/deflate，交给 .NET 解）
            $stream = $null
            try { $stream = $resp.GetResponseStream() }
            catch { $r.Error += ' | GetResponseStream失败: ' + $_.Exception.Message }

            if ($stream) {
                $ms = New-Object System.IO.MemoryStream
                try {
                    $buf = New-Object byte[] 16384
                    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
                    $bytes = $ms.ToArray()
                    $r.BodyLength = $bytes.Length
                    if ($bytes.Length -gt 0 -and $bytes.Length -lt 4MB) {
                        $charset = ''
                        if ($r.ContentType -match '(?i)charset=([\w\-]+)') { $charset = $Matches[1] }
                        $r.BodyText = Convert-BytesToText -Bytes $bytes -CharsetHint $charset
                    }
                } catch {
                    $r.Error += ' | 读body失败: ' + $_.Exception.Message
                } finally {
                    $ms.Dispose()
                }
            }
            $resp.Close()
        }
    } catch {
        $r.Error = 'Exception: ' + $_.Exception.Message
    } finally {
        if ($req) { try { $req.Abort() } catch { } }
    }
    return [pscustomobject]$r
}

function Get-PortalAssets {
    <#
        从 portal 页面 HTML 里把所有 script/link/form action 的地址抠出来，
        逐个下载存盘。深澜/Srun 那类前端签名的登录逻辑全在这些 JS 里。
    #>
    param(
        [string]$PageUrl,
        [string]$Html,
        [string]$CapDir
    )
    if (-not $Html) { return }

    $base = $null
    try { $base = New-Object System.Uri($PageUrl) } catch { return }

    $refs = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Html, '(?i)(?:src|href|action)\s*=\s*["'']([^"''>]+)["'']')) {
        $refs.Add($m.Groups[1].Value.Trim())
    }

    $seen  = @{}
    $index = 0
    $manifest = New-Object System.Collections.Generic.List[string]

    foreach ($rel in $refs) {
        if ($rel -match '^(javascript:|data:|mailto:|#|about:)') { continue }
        if ($rel -match '^(//|\w+://)') {
            # 绝对地址，但排除明显的外部 CDN，优先抓同源
            try { $u = New-Object System.Uri($rel) } catch { continue }
            if ($u.Host -ne $base.Host) { continue }
            $abs = $u.AbsoluteUri
        } else {
            try { $abs = (New-Object System.Uri($base, $rel)).AbsoluteUri } catch { continue }
        }

        if ($seen.ContainsKey($abs)) { continue }
        $seen[$abs] = $true

        if ($abs -notmatch '\.(js|css|json|html?|php|jsp|asp|aspx|do|action)(\?|$)') { continue }

        $resp = Invoke-Probe -Url $abs -TimeoutMs 8000
        $name = ($abs -replace '[^\w\.\-]', '_')
        if ($name.Length -gt 110) { $name = $name.Substring($name.Length - 110) }
        $file = Join-Path $CapDir ('asset-{0:D2}-{1}' -f $index, $name)

        if ($resp.BodyText) { Save-Text -Path $file -Text $resp.BodyText }
        $manifest.Add(('[{0:D2}] {1}  ->  HTTP {2}  ({3} bytes)  Error={4}' -f $index, $abs, $resp.StatusCode, $resp.BodyLength, $resp.Error))
        Write-Log ('  asset[%d] HTTP %s %s bytes  %s' -f $index, $resp.StatusCode, $resp.BodyLength, $abs)
        $index++
        if ($index -ge 40) { Write-Log '  资产数量到上限(40)，停止'; break }
    }

    if ($manifest.Count -gt 0) {
        Save-Text -Path (Join-Path $CapDir 'assets-manifest.txt') -Text ($manifest -join "`r`n")
    }
}

function Invoke-Capture {
    param([string]$Reason)

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $capDir = Join-Path $script:OutDir "capture-$stamp"
    New-Item -ItemType Directory -Path $capDir -Force | Out-Null
    Write-Log ('CAPTURE TRIGGERED ({0}) -> {1}' -f $Reason, $capDir) 'CAPTURE'

    # ---- 0. 现场网络快照 ----
    $snap = New-Object System.Collections.Generic.List[string]
    $snap.Add('=== ipconfig /all ===');                 $snap.Add((ipconfig /all   2>&1 | Out-String))
    $snap.Add('=== route print -4 ===');                $snap.Add((route print -4  2>&1 | Out-String))
    $snap.Add('=== arp -a ===');                        $snap.Add((arp -a          2>&1 | Out-String))
    $snap.Add('=== netsh wlan show interfaces ===');    $snap.Add((netsh wlan show interfaces 2>&1 | Out-String))
    $snap.Add('=== netsh wlan show profiles ===');      $snap.Add((netsh wlan show profiles   2>&1 | Out-String))
    $snap.Add('=== netsh wlan show networks mode=bssid ==='); $snap.Add((netsh wlan show networks mode=bssid 2>&1 | Out-String))
    $snap.Add('=== getmac ===');                        $snap.Add((getmac /v 2>&1 | Out-String))
    Save-Text -Path (Join-Path $capDir 'net-snapshot.txt') -Text ($snap -join "`r`n")

    # ---- 1. 逐个探针，直接抓到了 portal 就是最好结果 ----
    $targets = @(
        'http://www.msftconnecttest.com/connecttest.txt',
        'http://connect.rom.miui.com/generate_204',
        'http://wifi.vivo.com.cn/generate_204',
        'http://www.gstatic.com/generate_204',
        'http://10.21.255.254/',
        'http://10.10.10.10/'
    )

    $report = New-Object System.Collections.Generic.List[string]
    $portalUrls = New-Object System.Collections.Generic.List[string]
    $portalHtml = ''
    $portalPageUrl = ''

    foreach ($t in $targets) {
        $resp = Invoke-Probe -Url $t -TimeoutMs 6000
        $report.Add('--- ' + $t)
        $report.Add(('    HTTP {0} {1}' -f $resp.StatusCode, $resp.StatusDescription))
        $report.Add(('    Location: {0}' -f $resp.Location))
        $report.Add(('    Content-Type: {0}' -f $resp.ContentType))
        $report.Add(('    Server: {0}   BodyLength: {1}' -f $resp.Server, $resp.BodyLength))
        $report.Add(('    Error: {0}' -f $resp.Error))
        $report.Add('    完整响应头:')
        $report.Add($resp.Headers)
        $report.Add('')

        if ($resp.Location) { $portalUrls.Add($resp.Location) }

        if ($resp.BodyText) {
            $safe = ($t -replace '[^\w\.\-]', '_')
            Save-Text -Path (Join-Path $capDir ('body-' + $safe + '.html')) -Text $resp.BodyText
            # 谁返回了像登录页的 HTML，就当作 portal 主页面
            if ($resp.BodyText -match '(?i)(login|登录|认证|portal|username|password|账号|密码)' -and $t -notmatch 'connecttest|generate_204') {
                if (-not $portalPageUrl) { $portalPageUrl = $t; $portalHtml = $resp.BodyText }
            }
        }
    }

    # ---- 2. 顺着 Location 追 portal 主页 ----
    foreach ($u in ($portalUrls | Select-Object -Unique)) {
        if ($u -match '^(/|\.)') { continue }
        if ($u -notmatch '^https?://') { continue }
        $resp = Invoke-Probe -Url $u -TimeoutMs 8000
        $report.Add('=== 追踪 Location: ' + $u)
        $report.Add(('    HTTP {0}  Location: {1}  Len: {2}' -f $resp.StatusCode, $resp.Location, $resp.BodyLength))
        $report.Add('')
        if ($resp.BodyText -and -not $portalHtml) {
            $portalPageUrl = $u
            $portalHtml    = $resp.BodyText
            Save-Text -Path (Join-Path $capDir 'portal-page.html') -Text $resp.BodyText
        }
        # 再跟一层跳转
        if ($resp.Location -and $resp.Location -match '^https?://') {
            $resp2 = Invoke-Probe -Url $resp.Location -TimeoutMs 8000
            $report.Add('=== 二级跳转: ' + $resp.Location)
            $report.Add(('    HTTP {0}  Location: {1}  Len: {2}' -f $resp2.StatusCode, $resp2.Location, $resp2.BodyLength))
            $report.Add('')
            if ($resp2.BodyText -and -not $portalHtml) {
                $portalPageUrl = $resp2.Location
                $portalHtml    = $resp2.BodyText
                Save-Text -Path (Join-Path $capDir 'portal-page.html') -Text $resp2.BodyText
            }
        }
    }

    # ---- 3. 直接怼网关，很多学校 portal 就挂在网关上 ----
    foreach ($gw in @('http://10.21.255.254/','https://10.21.255.254/')) {
        $resp = Invoke-Probe -Url $gw -TimeoutMs 5000
        if ($resp.BodyText -and -not $portalHtml -and $resp.BodyLength -gt 200) {
            $portalPageUrl = $gw
            $portalHtml    = $resp.BodyText
            Save-Text -Path (Join-Path $capDir 'portal-page.html') -Text $resp.BodyText
            $report.Add('=== 网关即 portal: ' + $gw + ' (Len ' + $resp.BodyLength + ')')
        }
    }

    Save-Text -Path (Join-Path $capDir 'probe-report.txt') -Text ($report -join "`r`n")

    # ---- 4. 扒 portal 页面上的所有 JS/CSS ----
    if ($portalHtml -and $portalPageUrl) {
        Write-Log ('portal page found: {0}' -f $portalPageUrl) 'CAPTURE'
        Save-Text -Path (Join-Path $capDir 'portal-page.html') -Text $portalHtml
        Get-PortalAssets -PageUrl $portalPageUrl -Html $portalHtml -CapDir $capDir
    } else {
        Write-Log '没找到明显的 portal 页面，看看 probe-report.txt 和 body-*.html' 'CAPTURE'
    }

    # ---- 5. 对照：走系统代理会怎样（诊断 Clash 是否挡了 portal）----
    $withProxy = Invoke-Probe -Url 'http://www.msftconnecttest.com/connecttest.txt' -ProxyMode system -TimeoutMs 6000
    Save-Text -Path (Join-Path $capDir 'diag-proxy-compare.txt') -Text (
        ('经系统代理(127.0.0.1:7897)访问 connecttest.txt:`r`n' +
         ('  HTTP {0}  Location: {1}  Len: {2}  Error: {3}' -f $withProxy.StatusCode, $withProxy.Location, $withProxy.BodyLength, $withProxy.Error))
    )

    Write-Log ('捕获完成: ' + $capDir) 'CAPTURE'
    return $capDir
}

# ============================ 主流程 ============================

$startBanner = @"

========================================================
  校园网 Portal 现场抓包器  (海鸥出品)
  日志目录 : $OutDir
  监听时长 : $DurationMinutes 分钟
  轮询间隔 : $IntervalSeconds 秒
  代理策略 : 强制直连 (绕过 127.0.0.1:7897)
========================================================
  现在去操作你的电脑: 断开 WiFi -> 重新连上 -> 打开浏览器
  等登录页出现。别急着登录, 先让老子把页面扒下来。
========================================================

"@
Write-Output $startBanner
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($script:LogFile, $startBanner + "`r`n", $utf8)

$deadline   = (Get-Date).AddMinutes($DurationMinutes)
$lastState  = ''
$dumpCount  = 0
$maxDumps   = 8
$lastDumpAt = [datetime]::MinValue
$sawCaptive = $false

while ((Get-Date) -lt $deadline) {

    $probe  = Invoke-Probe -Url 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutMs 5000
    $online = ($probe.StatusCode -eq 200 -and $probe.BodyText -match 'Microsoft Connect Test')

    if ($online) {
        $state = 'ONLINE'
    } elseif ($probe.StatusCode -or $probe.Location -or ($probe.BodyLength -gt 0)) {
        $state = 'CAPTIVE'
    } else {
        $state = 'DOWN'
    }

    if ($state -ne $lastState) {
        Write-Log ('STATE CHANGE: {0} -> {1}   (HTTP {2}, Location={3}, Len={4})' -f $lastState, $state, $probe.StatusCode, $probe.Location, $probe.BodyLength) 'STATE'
        $lastState = $state
    }

    if ($state -eq 'CAPTIVE') {
        $sawCaptive = $true
        $dueByCount = $dumpCount -lt $maxDumps
        $dueByTime  = ((Get-Date) - $lastDumpAt).TotalSeconds -gt 20
        if ($dueByCount -and $dueByTime) {
            $dumpCount++
            $lastDumpAt = Get-Date
            [void](Invoke-Capture -Reason ('state=CAPTIVE, HTTP ' + $probe.StatusCode))
            Start-Sleep -Seconds 1
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}

# ---- 收尾报告 ----
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('# 校园网 portal 抓包结果汇总')
$summary.Add('')
$summary.Add(('- 抓包时间: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)))
$summary.Add(('- 监听时长: {0} 分钟' -f $DurationMinutes))
$summary.Add(('- 是否观察到 CAPTIVE 状态: {0}' -f $sawCaptive))
$summary.Add(('- 捕获次数: {0}' -f $dumpCount))
$summary.Add('')
$summary.Add('## 抓到的目录')
foreach ($d in (Get-ChildItem $OutDir -Directory -Filter 'capture-*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $summary.Add(('- `{0}`' -f $d.Name))
    foreach ($f in (Get-ChildItem $d.FullName -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $summary.Add(('    - {0}  ({1} bytes)' -f $f.Name, $f.Length))
    }
}
Save-Text -Path (Join-Path $OutDir 'SUMMARY.md') -Text ($summary -join "`r`n")

Write-Output ''
Write-Output 'DONE. summary written to:'
Write-Output ('  ' + (Join-Path $OutDir 'SUMMARY.md'))
