#Requires -Version 5.1
<#
=============================================================================
 CampusNetLogin.ps1   —— 常州纺织服装职业技术学院 校园网自动认证
                          (城市热点 Dr.COM ePortal / SAM+ 认证系统)

 目标 portal : http://portal.example.edu.cn/eportal/
 登录接口    : POST http://portal.example.edu.cn/eportal/InterFace.do?method=login

 认证流程(与服务端前端 JS 完全一致):
   1. 检测联网状态 (绕过本地代理, 否则会抓到 Clash 而不是学校)
   2. 探测被 AC 劫持的 HTTP 响应, 从 302 Location 里取出 queryString
      (含 wlanuserip / wlanacname / nasip / mac / t / url 等会话参数)
   3. POST InterFace.do?method=pageInfo 拿到权威配置:
        passwordEncrypt / publicKeyExponent / publicKeyModulus
        validCodeUrl (非空=需要验证码) / prefixValue (域名前缀)
   4. 按前端逻辑构造登录报文:
        明文 = reverse(密码 + ">" + mac)
        RSA  = 裸模幂, 零填充到 126 字节整数倍, 块内小端字节序, 输出小写 hex
        password 字段 = encodeURIComponent(encodeURIComponent(cipher))
      本实现已与 portal 原版 security.js 做过差分比对, 密文逐字符一致。
   5. 校验 result == "success", 再复核联网状态

 用法:
   powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1 -Setup
   powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1 -Status
   powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1
   powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1 -Force
   powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1 -SelfTest

 退出码: 0=已联网  1=认证失败  2=配置/凭据缺失  3=需要验证码(人工介入)

 注意: 本文件必须保存为 UTF-8 with BOM。
       Windows PowerShell 5.1 读无 BOM 的 UTF-8 源码时会按 GBK 解码,
       中文注释会让字符串引号错位, 整个脚本语法崩掉。
=============================================================================
#>
[CmdletBinding()]
param(
    [switch]$Setup,          # 交互配置账号密码
    [switch]$Status,         # 打印当前在线信息
    [switch]$Force,          # 无视"已在线"直接认证一次
    [switch]$SelfTest,       # 自检: 验证 RSA 实现 + 打印解析出的配置
    [switch]$Quiet,          # 不写控制台, 只写日志
    [switch]$Logout,         # 主动下线(仅用于验证自动登录是否真的有效)
    [switch]$AsLibrary,      # 只加载函数不跑主流程(供 CampusNetSetup.ps1 点源复用)
    [string]$ConfigPath,
    [string]$LogDir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# 基础环境
# ---------------------------------------------------------------------------
# 不要把 [Console]::OutputEncoding 硬改成 936 —— 那会让 UTF-8 终端里的中文变乱码。
# 本脚本不调用原生命令, 控制台编码交给系统默认; 日志文件始终写 UTF-8。
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch { }
try { [System.Net.ServicePointManager]::DefaultConnectionLimit = 16 } catch { }

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }

if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot 'config.json' }
$CredPath = Join-Path (Split-Path -Parent $ConfigPath) 'credential.xml'

if (-not $LogDir) {
    $cfgProbe = $null
    if (Test-Path $ConfigPath) {
        try { $cfgProbe = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($cfgProbe -and $cfgProbe.LogDir) { $LogDir = $cfgProbe.LogDir }
    else { $LogDir = Join-Path $ScriptRoot 'logs' }
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$script:LogFile = Join-Path $LogDir ('autologin-{0:yyyyMMdd}.log' -f (Get-Date))
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 全局: 是否让 HTTP 请求走系统代理。默认 false —— 必须绕过 Clash 系统代理,
# 否则探测到的是代理的响应, 永远发现不了校园网 portal 劫持。
$script:UseSystemProxy = $false

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO'
    )
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1,-5}] {2}' -f (Get-Date), $Level, $Message
    try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", $script:Utf8NoBom) } catch { }
    if (-not $Quiet) { Write-Host $line }
}

function Save-JsonFile {
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, $script:Utf8NoBom)
}

# ---------------------------------------------------------------------------
# JS 兼容的 URL 编码
#   encodeURIComponent 不转义  A-Za-z0-9 - _ . ! ~ * ' ( )
#   .NET EscapeDataString 只保留 A-Za-z0-9 - _ . ~  (RFC3986 unreserved)
#   所以要把 ! * ' ( ) 这五个还原, 否则服务端解出来会不一致
# ---------------------------------------------------------------------------
function ConvertTo-JsUriComponent {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $s = [System.Uri]::EscapeDataString($Value)
    $s = $s.Replace('%21', '!').Replace('%2A', '*').Replace('%27', "'").Replace('%28', '(').Replace('%29', ')')
    return $s
}

function ConvertTo-JsEncodedTwice {
    param([string]$Value)
    return (ConvertTo-JsUriComponent (ConvertTo-JsUriComponent $Value))
}

# ---------------------------------------------------------------------------
# 裸 RSA —— 复刻 portal 原版 security.js 的 RSAUtils.encryptedString
#
# 关键点(跟标准 PKCS#1 完全不同, 用 .NET 的 RSA.Encrypt 会直接失败):
#   1. 明文按字符取 charCode (1 字符 = 1 字节), 尾部补 0 到 chunkSize 整数倍
#   2. chunkSize = 2 * biHighIndex(modulus)  —— 1024 位密钥时 = 126 字节
#   3. 块内按【小端】字节序解释成大整数: digit[j] = a[2j] + (a[2j+1] << 8)
#   4. c = m^e mod n, 输出【小写 hex, 不补前导零】
#   5. 多块之间用一个空格连接
# 已用 portal 原始 security.js 在 Node vm 下做过差分比对, 输出逐字符一致。
# ---------------------------------------------------------------------------
function ConvertFrom-HexToBigInt {
    param([string]$Hex)
    if ([string]::IsNullOrEmpty($Hex)) { throw 'Hex 为空' }
    if ($Hex.Length % 2 -ne 0) { $Hex = '0' + $Hex }
    $be = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $be.Length; $i++) {
        $be[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    $le = New-Object byte[] ($be.Length + 1)
    for ($i = 0; $i -lt $be.Length; $i++) { $le[$i] = $be[$be.Length - 1 - $i] }
    $le[$be.Length] = 0                       # 补最高位 0, 保证解释为正数
    return [System.Numerics.BigInteger]::new($le)
}

function ConvertFrom-BigIntToHex {
    param([System.Numerics.BigInteger]$Value)
    if ($Value.Sign -eq 0) { return '0' }
    $bytes = $Value.ToByteArray()             # 小端 + 补码
    $sb = New-Object System.Text.StringBuilder
    for ($i = $bytes.Length - 1; $i -ge 0; $i--) { [void]$sb.Append($bytes[$i].ToString('x2')) }
    $h = $sb.ToString().TrimStart('0')
    if ($h -eq '') { $h = '0' }
    return $h
}

function Get-JsRsaChunkSize {
    param([string]$ModulusHex)
    $h = $ModulusHex
    while ($h.Length % 4 -ne 0) { $h = '0' + $h }
    $groups = $h.Length / 4
    $high = 0
    for ($j = 0; $j -lt $groups; $j++) {
        $start = $h.Length - (($j + 1) * 4)
        if ([Convert]::ToInt32($h.Substring($start, 4), 16) -ne 0) { $high = $j }
    }
    return 2 * $high
}

function Get-JsRsaCipher {
    param(
        [Parameter(Mandatory)][string]$PlainText,
        [Parameter(Mandatory)][string]$ModulusHex,
        [Parameter(Mandatory)][string]$ExponentHex
    )
    $n = ConvertFrom-HexToBigInt -Hex $ModulusHex
    $e = ConvertFrom-HexToBigInt -Hex $ExponentHex
    $chunkSize = Get-JsRsaChunkSize -ModulusHex $ModulusHex
    if ($chunkSize -le 0) { throw 'chunkSize 计算异常' }

    # JS: a[i] = s.charCodeAt(i)
    $bytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($PlainText)

    # JS: while (a.length % chunkSize != 0) a[i++] = 0;
    $pad = $chunkSize - ($bytes.Length % $chunkSize)
    if ($pad -eq $chunkSize) { $pad = 0 }
    $padded = New-Object byte[] ($bytes.Length + $pad)
    [Array]::Copy($bytes, $padded, $bytes.Length)

    $parts = New-Object System.Collections.Generic.List[string]
    for ($off = 0; $off -lt $padded.Length; $off += $chunkSize) {
        $block = New-Object byte[] ($chunkSize + 1)
        [Array]::Copy($padded, $off, $block, 0, $chunkSize)
        $block[$chunkSize] = 0
        $m = [System.Numerics.BigInteger]::new($block)          # 小端解释
        $c = [System.Numerics.BigInteger]::ModPow($m, $e, $n)
        $parts.Add((ConvertFrom-BigIntToHex -Value $c))
    }
    return ($parts -join ' ')
}

# ---------------------------------------------------------------------------
# HTTP 客户端
#   默认强制直连(Proxy = $null) —— 本机开着 Clash 系统代理 127.0.0.1:7897,
#   走代理会拿到代理的响应而不是校园网 portal 的劫持页面。
# ---------------------------------------------------------------------------
function Invoke-CampusHttp {
    param(
        [Parameter(Mandatory)][string]$Url,
        [ValidateSet('GET','POST')][string]$Method = 'GET',
        [string]$Body = $null,
        [string]$ContentType = 'application/x-www-form-urlencoded; charset=UTF-8',
        [string]$Referer = $null,
        [int]$TimeoutMs = 8000,
        [switch]$FollowRedirect
    )

    $result = [pscustomobject]@{
        Ok          = $false
        StatusCode  = $null
        StatusDesc  = ''
        Location    = ''
        ContentType = ''
        Server      = ''
        Body        = ''
        Error       = ''
    }

    $req = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method            = $Method
        $req.AllowAutoRedirect = [bool]$FollowRedirect
        $req.Timeout           = $TimeoutMs
        $req.ReadWriteTimeout  = $TimeoutMs
        $req.KeepAlive         = $false
        $req.UserAgent         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
        $req.Accept            = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        $req.Headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8'
        if ($Referer) { $req.Referer = $Referer }

        if ($script:UseSystemProxy) {
            $ps = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyServer
            if ($ps) {
                if ($ps -notmatch '^\w+://') { $ps = 'http://' + $ps }
                $req.Proxy = New-Object System.Net.WebProxy($ps)
            }
        } else {
            $req.Proxy = $null
        }

        if ($Method -eq 'POST' -and $null -ne $Body) {
            $req.ContentType = $ContentType
            $payload = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $req.ContentLength = $payload.Length
            $rs = $req.GetRequestStream()
            $rs.Write($payload, 0, $payload.Length)
            $rs.Close()
        }

        $resp = $null
        try {
            $resp = $req.GetResponse()
            $result.Ok = $true
        } catch [System.Net.WebException] {
            $result.Error = $_.Exception.Message
            if ($_.Exception.Response) { try { $resp = $_.Exception.Response } catch { } }
        }

        if ($resp) {
            $result.StatusCode  = [int]$resp.StatusCode
            $result.StatusDesc  = [string]$resp.StatusDescription
            $result.Location    = [string]$resp.Headers['Location']
            $result.ContentType = [string]$resp.ContentType
            $srvH = $resp.Headers['Server']
            if ($srvH) { $result.Server = [string]$srvH }

            $stream = $null
            try { $stream = $resp.GetResponseStream() } catch { }
            if ($stream) {
                $ms = New-Object System.IO.MemoryStream
                try {
                    $buf = New-Object byte[] 16384
                    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
                    $bytes = $ms.ToArray()
                    if ($bytes.Length -gt 0) {
                        $text = $null
                        try {
                            $strict = New-Object System.Text.UTF8Encoding($false, $true)
                            $text = $strict.GetString($bytes)          # JSON 基本都是 UTF-8
                        } catch {
                            try { $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes) }
                            catch { $text = [System.Text.Encoding]::UTF8.GetString($bytes) }
                        }
                        $result.Body = $text
                    }
                } catch {
                    $result.Error += ' | read-body: ' + $_.Exception.Message
                } finally {
                    $ms.Dispose()
                }
            }
            try { $resp.Close() } catch { }
        }
    } catch {
        $result.Error = 'EX: ' + $_.Exception.Message
    } finally {
        if ($req) { try { $req.Abort() } catch { } }
    }

    return $result
}

# ---------------------------------------------------------------------------
# 配置与凭据
# ---------------------------------------------------------------------------
function Get-DefaultConfig {
    return [pscustomobject]@{
        # --- portal 定位 (安装向导会根据你粘贴的网址自动填) ---
        PortalScheme    = 'http'          # http 或 https
        PortalHost      = 'portal.example.edu.cn'  # 主机名, 带非标准端口时形如 host:8080
        PortalPath      = '/eportal/'     # ePortal 根路径, 必须以 / 开头结尾
        # --- 认证参数 ---
        Service         = '移动'           # 运营商服务名; 留空则用服务端默认
        UserId          = ''
        # --- 探针 ---
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
}

function Get-Config {
    if (-not (Test-Path $ConfigPath)) {
        $cfg = Get-DefaultConfig
        $cfg.LogDir = $LogDir
        Save-JsonFile -Path $ConfigPath -Object $cfg
        Write-Log ('已生成默认配置文件: ' + $ConfigPath) 'INFO'
        return $cfg
    }
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $cfg = $raw | ConvertFrom-Json
    } catch {
        Write-Log ('配置文件解析失败, 使用默认值: ' + $_.Exception.Message) 'WARN'
        return (Get-DefaultConfig)
    }
    $def = Get-DefaultConfig
    foreach ($p in $def.PSObject.Properties) {
        if ($null -eq $cfg.PSObject.Properties[$p.Name]) {
            $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }
    if (-not $cfg.LogDir) { $cfg.LogDir = $LogDir }
    return $cfg
}

function Save-Credential {
    param([string]$UserId, [securestring]$Password)
    $enc = ConvertFrom-SecureString -SecureString $Password      # DPAPI, 绑定当前用户
    [System.IO.File]::WriteAllText($CredPath, $enc, $script:Utf8NoBom)
}

function Get-CredentialPlain {
    if (-not (Test-Path $CredPath)) { return $null }
    try {
        $enc = (Get-Content -LiteralPath $CredPath -Raw).Trim()
        $sec = ConvertTo-SecureString -String $enc
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Log ('凭据解密失败: ' + $_.Exception.Message) 'ERROR'
        return $null
    }
}

# ---------------------------------------------------------------------------
# 联网状态检测
# ---------------------------------------------------------------------------
function Test-CampusOnline {
    param($Config)
    foreach ($url in $Config.OnlineCheckUrls) {
        $r = Invoke-CampusHttp -Url $url -TimeoutMs 6000
        if ($r.StatusCode -eq 204) { return $true }
        if ($r.StatusCode -eq 200 -and $r.Body -match 'Microsoft Connect Test') { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# portal 基地址 —— 所有接口都由它拼出来, 不在代码里写死任何学校
# ---------------------------------------------------------------------------
function Get-PortalBase {
    param($Config)
    $scheme = 'http'
    if ($Config.PortalScheme) { $scheme = ([string]$Config.PortalScheme).ToLower() }
    $path = '/eportal/'
    if ($Config.PortalPath) { $path = ([string]$Config.PortalPath) }
    if (-not $path.StartsWith('/')) { $path = '/' + $path }
    if (-not $path.EndsWith('/'))   { $path = $path + '/' }
    return ('{0}://{1}{2}' -f $scheme, $Config.PortalHost, $path)
}

# ---------------------------------------------------------------------------
# 从被劫持的响应里提取 queryString
#
# 通用做法, 不写死任何学校的路径: 只要响应里有【指向 portal 主机且带查询串】
# 的跳转地址(Location / meta refresh / JS 跳转 / 超链接), 就把 ? 后面那串取出来。
# ---------------------------------------------------------------------------
function Get-QueryStringFromResponse {
    param(
        [string]$ProbeUrl,
        [string]$Location,
        [string]$Body,
        [string]$PortalHost
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Location) { $candidates.Add($Location) }

    if ($Body) {
        # meta refresh: content="0;url=..."
        foreach ($m in [regex]::Matches($Body, '(?i)content\s*=\s*[''"][^''"]*?url=([^''";>\s]+)')) {
            $candidates.Add($m.Groups[1].Value)
        }
        # JS: location.href="..." / location.replace("...") / window.open("...")
        foreach ($m in [regex]::Matches($Body, '(?i)(?:location\.(?:href|replace)\s*\(?\s*|window\.open\s*\(\s*)[''"]([^''"]+)[''"]')) {
            $candidates.Add($m.Groups[1].Value)
        }
        # 普通超链接
        foreach ($m in [regex]::Matches($Body, '(?i)href\s*=\s*[''"]([^''"]+)[''"]')) {
            $candidates.Add($m.Groups[1].Value)
        }
    }

    $hostOnly = ([string]$PortalHost) -split ':' | Select-Object -First 1

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $abs = $c.Trim()
        if ($abs -match '^(/|\.)') {
            try { $abs = (New-Object System.Uri((New-Object System.Uri($ProbeUrl)), $abs)).AbsoluteUri }
            catch { continue }
        }
        if ($abs -notmatch '^https?://') { continue }
        $u = $null
        try { $u = New-Object System.Uri($abs) } catch { continue }
        if ($u.Host -ne $hostOnly) { continue }
        if ($u.Query -and $u.Query.Length -gt 1) {
            return $u.Query.Substring(1)     # 去掉开头的 '?'
        }
    }
    return $null
}

function Get-PortalQueryString {
    param($Config)

    $probes = @($Config.ProbeUrls)
    if ($probes.Count -eq 0) { $probes = (Get-DefaultConfig).ProbeUrls }
    # 永远额外试一次 portal 本身 —— 未认证时 AC 一般会把它 302 到带参数的登录页
    $probes += ('{0}://{1}/' -f $(if ($Config.PortalScheme) { $Config.PortalScheme } else { 'http' }), $Config.PortalHost)

    foreach ($url in $probes) {
        $r = Invoke-CampusHttp -Url $url -TimeoutMs 6000
        $cand = Get-QueryStringFromResponse -ProbeUrl $url -Location $r.Location -Body $r.Body -PortalHost $Config.PortalHost
        if ($cand) {
            Write-Log ('从 ' + $url + ' 的劫持响应中取得 queryString (' + $cand.Length + ' 字符)') 'DEBUG'
            return $cand
        }
        Write-Log ('探针无劫持: {0}  HTTP={1}  Loc={2}' -f $url, $r.StatusCode, $r.Location) 'DEBUG'
    }

    # 兜底: 复用上次成功的 queryString (同 IP 同 MAC 通常仍然有效)
    $cacheFile = Join-Path (Split-Path -Parent $ConfigPath) 'last-querystring.txt'
    if (Test-Path $cacheFile) {
        $cached = (Get-Content -LiteralPath $cacheFile -Raw).Trim()
        if ($cached) {
            Write-Log '所有探针都没拿到劫持响应, 回退到上次缓存的 queryString' 'WARN'
            return $cached
        }
    }
    return $null
}

function Save-PortalQueryString {
    param([string]$QueryString)
    if (-not $QueryString) { return }
    $cacheFile = Join-Path (Split-Path -Parent $ConfigPath) 'last-querystring.txt'
    [System.IO.File]::WriteAllText($cacheFile, $QueryString, $script:Utf8NoBom)
}

function Get-QueryStringParam {
    param([string]$QueryString, [string]$Name)
    if (-not $QueryString) { return $null }
    $m = [regex]::Match($QueryString, '(?:^|&)' + [regex]::Escape($Name) + '=([^&]*)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# ---------------------------------------------------------------------------
# pageInfo —— 权威配置
# ---------------------------------------------------------------------------
function Get-PortalPageInfo {
    param($Config, [string]$QueryString, [string]$Referer)

    $api = (Get-PortalBase -Config $Config) + 'InterFace.do?method=pageInfo'
    $body = 'queryString=' + (ConvertTo-JsEncodedTwice $QueryString)
    $r = Invoke-CampusHttp -Url $api -Method POST -Body $body -Referer $Referer `
                           -TimeoutMs 10000

    if ($r.StatusCode -ne 200 -or -not $r.Body) {
        Write-Log ('pageInfo 调用失败: HTTP={0} Loc={1} Err={2}' -f $r.StatusCode, $r.Location, $r.Error) 'ERROR'
        return $null
    }
    try { return ($r.Body | ConvertFrom-Json) }
    catch {
        Write-Log ('pageInfo 返回不是合法 JSON: ' + $r.Body.Substring(0, [Math]::Min(300, $r.Body.Length))) 'ERROR'
        return $null
    }
}

# ---------------------------------------------------------------------------
# 执行登录
# ---------------------------------------------------------------------------
function Invoke-PortalLogin {
    param($Config, [string]$UserId, [string]$Password, [switch]$DryRun, [string]$QueryString)

    $refIndex = (Get-PortalBase -Config $Config) + 'index.jsp'

    $qs = $QueryString
    if (-not $qs) { $qs = Get-PortalQueryString -Config $Config }
    if (-not $qs) {
        Write-Log '无法获取 portal queryString (没被劫持也没缓存), 认证无法进行' 'ERROR'
        return [pscustomobject]@{ Success = $false; Reason = 'no-querystring'; NeedCaptcha = $false }
    }
    Save-PortalQueryString -QueryString $qs

    $info = Get-PortalPageInfo -Config $Config -QueryString $qs -Referer $refIndex
    if (-not $info) {
        return [pscustomobject]@{ Success = $false; Reason = 'pageinfo-failed'; NeedCaptcha = $false }
    }

    if ($info.validCodeUrl) {
        Write-Log ('portal 要求验证码 (validCodeUrl=' + $info.validCodeUrl + '), 需要人工登录一次') 'WARN'
        return [pscustomobject]@{ Success = $false; Reason = 'captcha-required'; NeedCaptcha = $true }
    }

    $prefix = ''
    if ($info.prefixValue) { $prefix = [string]$info.prefixValue }
    $userForSend = $prefix + $UserId

    $serviceName = [string]$Config.Service

    # ---- 密码字段 ----
    $encryptFlag = 'false'
    if ($info.passwordEncrypt) { $encryptFlag = ([string]$info.passwordEncrypt).ToLower() }

    $mac = Get-QueryStringParam -QueryString $qs -Name 'mac'
    if ([string]::IsNullOrEmpty($mac)) { $mac = '111111111' }

    if ($encryptFlag -eq 'true') {
        if (-not $info.publicKeyModulus -or -not $info.publicKeyExponent) {
            Write-Log 'pageInfo 说密码要加密, 但没给公钥' 'ERROR'
            return [pscustomobject]@{ Success = $false; Reason = 'no-pubkey'; NeedCaptcha = $false }
        }
        $raw = $Password + '>' + $mac
        $arr = $raw.ToCharArray()
        [Array]::Reverse($arr)                         # JS: split("").reverse().join("")
        $reversed = -join $arr
        $cipher = Get-JsRsaCipher -PlainText $reversed `
                                  -ModulusHex ([string]$info.publicKeyModulus) `
                                  -ExponentHex ([string]$info.publicKeyExponent)
        $passwordField = ConvertTo-JsEncodedTwice $cipher
        Write-Log ('密码 RSA 加密完成 (chunkSize={0}, 密文 {1} hex 字符)' -f (Get-JsRsaChunkSize ([string]$info.publicKeyModulus)), $cipher.Length) 'DEBUG'
    } else {
        $passwordField = ConvertTo-JsEncodedTwice $Password
        Write-Log 'portal 未启用密码加密, 明文提交' 'DEBUG'
    }

    $body = 'userId='        + (ConvertTo-JsEncodedTwice $userForSend) +
            '&password='     + $passwordField +
            '&service='      + (ConvertTo-JsEncodedTwice $serviceName) +
            '&queryString='  + (ConvertTo-JsEncodedTwice $qs) +
            '&operatorPwd='  + '' +
            '&operatorUserId=' + '' +
            '&validcode='    + '' +
            '&passwordEncrypt=' + (ConvertTo-JsEncodedTwice $encryptFlag)

    if ($DryRun) {
        Write-Log '--- DryRun, 不实际提交 ---' 'WARN'
        Write-Log ('参考 index URL: ' + $refIndex) 'WARN'
        Write-Log ('queryString 长度: ' + $qs.Length) 'WARN'
        Write-Log ('userId(发送值): ' + $prefix + '***') 'WARN'
        Write-Log ('service: ' + $serviceName + '   passwordEncrypt: ' + $encryptFlag) 'WARN'
        return [pscustomobject]@{ Success = $false; Reason = 'dryrun'; NeedCaptcha = $false; QueryString = $qs; PageInfo = $info }
    }

    $api = (Get-PortalBase -Config $Config) + 'InterFace.do?method=login'
    $r = Invoke-CampusHttp -Url $api -Method POST -Body $body -Referer $refIndex `
                           -TimeoutMs 12000

    if ($r.StatusCode -ne 200 -or -not $r.Body) {
        Write-Log ('登录请求异常: HTTP={0} Err={1}' -f $r.StatusCode, $r.Error) 'ERROR'
        return [pscustomobject]@{ Success = $false; Reason = 'http-error'; NeedCaptcha = $false }
    }

    $res = $null
    try { $res = $r.Body | ConvertFrom-Json }
    catch {
        Write-Log ('登录返回不是 JSON: ' + $r.Body.Substring(0, [Math]::Min(300, $r.Body.Length))) 'ERROR'
        return [pscustomobject]@{ Success = $false; Reason = 'bad-json'; NeedCaptcha = $false }
    }

    if ([string]$res.result -eq 'success') {
        Write-Log ('认证成功: ' + [string]$res.message) 'OK'
        if ($res.keepaliveInterval) { Write-Log ('keepaliveInterval=' + $res.keepaliveInterval) 'INFO' }
        return [pscustomobject]@{ Success = $true; Reason = 'ok'; NeedCaptcha = $false; Result = $res }
    }

    $msg = [string]$res.message
    Write-Log ('认证失败: ' + $msg) 'ERROR'
    $needCaptcha = $false
    if ($res.validCodeUrl) { $needCaptcha = $true }
    if ($msg -match '验证码') { $needCaptcha = $true }
    return [pscustomobject]@{ Success = $false; Reason = $msg; NeedCaptcha = $needCaptcha; Result = $res }
}

# ---------------------------------------------------------------------------
# 在线信息
# ---------------------------------------------------------------------------
function Get-OnlineInfo {
    param($Config)
    $api = (Get-PortalBase -Config $Config) + 'InterFace.do?method=getOnlineUserInfo'
    $r = Invoke-CampusHttp -Url $api -Method GET -TimeoutMs 8000
    if ($r.StatusCode -ne 200 -or -not $r.Body) { return $null }
    try { return ($r.Body | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------------------
# 枚举 portal 提供的服务(运营商), 供安装向导选择
#   优先 getServices; 退而求其次解析 getOnlineUserInfo 里的 serviceList
#   返回的是需要填进 net_access_type 的值(即 selectService 的第一个参数)
# ---------------------------------------------------------------------------
function Get-PortalServices {
    param($Config, [string]$QueryString)

    $list = New-Object System.Collections.Generic.List[string]

    function Add-ServiceName {
        param([string]$Name, $List)
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        $n = $Name.Trim()
        if ($n -match '^\[-\d+-\d+\]') { return }        # "系统默认服务" 这类占位
        if ($n -eq '系统默认服务') { return }
        if (-not $List.Contains($n)) { $List.Add($n) }
    }

    if ($QueryString) {
        $api = (Get-PortalBase -Config $Config) + 'InterFace.do?method=getServices&queryString=' + (ConvertTo-JsEncodedTwice $QueryString)
        $r = Invoke-CampusHttp -Url $api -Method POST -Body '' -TimeoutMs 8000
        if ($r.Body) {
            foreach ($m in [regex]::Matches($r.Body, "(?i)selectService\(\s*'([^']+)'")) {
                Add-ServiceName -Name $m.Groups[1].Value -List $list
            }
        }
    }

    $info = Get-OnlineInfo -Config $Config
    if ($info) {
        Add-ServiceName -Name ([string]$info.service)         -List $list
        Add-ServiceName -Name ([string]$info.realServiceName) -List $list
        if ($info.serviceList) {
            foreach ($m in [regex]::Matches([string]$info.serviceList, "(?i)selectService\(\s*'([^']+)'")) {
                Add-ServiceName -Name $m.Groups[1].Value -List $list
            }
        }
    }

    return $list
}

# ---------------------------------------------------------------------------
# 模式: -Setup
# ---------------------------------------------------------------------------
function Invoke-SetupMode {
    param($Config)
    Write-Host ''
    Write-Host '================ 校园网自动认证 配置向导 ================' -ForegroundColor Cyan
    Write-Host ('Portal      : ' + (Get-PortalBase -Config $Config))
    Write-Host ''

    $defUser = if ($Config.UserId) { $Config.UserId } else { '' }
    $uid = Read-Host ("学号/用户名" + $(if ($defUser) { " [$defUser]" } else { '' }))
    if ([string]::IsNullOrWhiteSpace($uid)) { $uid = $defUser }
    if ([string]::IsNullOrWhiteSpace($uid)) { Write-Host '学号不能为空' -ForegroundColor Red; return 2 }

    $svc = Read-Host ("服务名（可选: 移动 / 仅限校内） [" + $Config.Service + ']')
    if ([string]::IsNullOrWhiteSpace($svc)) { $svc = $Config.Service }

    $sec = Read-Host '上网密码（与智慧校园统一身份认证一致）' -AsSecureString
    if (-not $sec -or $sec.Length -eq 0) { Write-Host '密码不能为空' -ForegroundColor Red; return 2 }

    $Config.UserId = $uid
    $Config.Service = $svc
    Save-JsonFile -Path $ConfigPath -Object $Config
    Save-Credential -UserId $uid -Password $sec

    Write-Host ''
    Write-Host '已保存:' -ForegroundColor Green
    Write-Host ('  配置   : ' + $ConfigPath)
    Write-Host ('  凭据   : ' + $CredPath + '   (DPAPI 加密, 只有当前 Windows 用户能解)')
    Write-Host ''
    Write-Host '下一步: 运行 Install-AutoLoginTask.ps1 注册开机自动认证' -ForegroundColor Yellow
    return 0
}

# ---------------------------------------------------------------------------
# 模式: -Status
# ---------------------------------------------------------------------------
function Invoke-StatusMode {
    param($Config)
    Write-Host ''
    $online = Test-CampusOnline -Config $Config
    Write-Host ('联网状态 : ' + $(if ($online) { '已联网' } else { '未认证 / 无网络' })) -ForegroundColor $(if ($online) { 'Green' } else { 'Yellow' })

    $info = Get-OnlineInfo -Config $Config
    if ($info) {
        Write-Host ('认证结果 : ' + $info.result)
        if ($info.userName)  { Write-Host ('姓名     : ' + $info.userName) }
        if ($info.userId)    { Write-Host ('学号     : ' + $info.userId) }
        if ($info.userIp)    { Write-Host ('IP       : ' + $info.userIp) }
        if ($info.userMac)   { Write-Host ('MAC      : ' + $info.userMac) }
        if ($info.service)   { Write-Host ('服务     : ' + $info.service) }
        if ($info.userGroup) { Write-Host ('用户组   : ' + $info.userGroup) }
        if ($info.maxLeavingTime) { Write-Host ('剩余时长 : ' + $info.maxLeavingTime) }
        if ($info.accountFee)     { Write-Host ('余额     : ' + $info.accountFee) }
    } else {
        Write-Host '在线信息 : 取不到（可能未认证）' -ForegroundColor DarkGray
    }
    Write-Host ''
    return $(if ($online) { 0 } else { 1 })
}

# ---------------------------------------------------------------------------
# 模式: -SelfTest
# ---------------------------------------------------------------------------
function Invoke-SelfTestMode {
    $ok = $true
    Write-Host ''
    Write-Host '============= 自检 =============' -ForegroundColor Cyan

    # 1. RSA 差分测试向量（来自 portal 原版 security.js 的实测输出）
    $mod = '94dd2a8675fb779e6b9f7103698634cd400f27a154afa67af6166a43fc26417222a79506d34cacc7641946abda1785b7acf9910ad6a0978c91ec84d40b71d2891379af19ffb333e7517e390bd26ac312fe940c340466b4a5d4af1d65c3b5944078f96a1a51a5a53e4bc302818b7c9f63c4a1b07bd7d874cef1c3d4b2f5eb7871'
    $exp = '10001'
    $cs = Get-JsRsaChunkSize -ModulusHex $mod
    Write-Host ('[1] chunkSize = ' + $cs + '  (期望 126)') -ForegroundColor $(if ($cs -eq 126) { 'Green' } else { 'Red' })
    if ($cs -ne 126) { $ok = $false }

    $vectors = @(
        @{ pwd = 'TestPass123!'; mac = '9d4d2299bbbc9b189c95ce532a332372'
           expect = '3e744017b3b57366711800f1b674a0d57b87f593e60cb7986dba1f735f6774684eeabb8820e181702c5bf165c34b940da1895dbeb5eea7098efc5edc885c06e28eba572d33e82161bc1da6f933e49fa3e94bddb04522f8eebc7c92b1bddb46140bed1b3f88c12c31d5089a1e067bab84ee43fd4ffb4ae02f1fe3ba03b9b5a034' },
        @{ pwd = 'a'; mac = '111111111'
           expect = '51cc8c729fa3e6d04dd4e5fbb372249a2135fc23a37690baa77000bdbf2739193b32c035cf8b74908c8fb79331a990680fcbafbd5504c09189f4aad78cb8964078ce5d79af4bf2c7d7e28d5d37e5d168431a23d6d7d0e84f5b989df07e55578ef7715dbed6264615a58c22ae06aea8548a24b98bcddbe0872ea40231d6ed12ed' }
    )
    $i = 2
    foreach ($v in $vectors) {
        $raw = $v.pwd + '>' + $v.mac
        $arr = $raw.ToCharArray(); [Array]::Reverse($arr)
        $got = Get-JsRsaCipher -PlainText (-join $arr) -ModulusHex $mod -ExponentHex $exp
        $good = ($got -ceq $v.expect)
        Write-Host ('[' + $i + '] RSA 向量 pwd=' + $v.pwd + '  -> ' + $(if ($good) { 'MATCH' } else { 'MISMATCH' })) -ForegroundColor $(if ($good) { 'Green' } else { 'Red' })
        if (-not $good) { $ok = $false; Write-Host ('      期望: ' + $v.expect); Write-Host ('      实际: ' + $got) }
        $i++
    }

    # 2. 编码一致性
    $e1 = ConvertTo-JsUriComponent "a b!'()*~-_.中"
    $want = "a%20b!'()*~-_.%E4%B8%AD"
    $goodEnc = ($e1 -ceq $want)
    Write-Host ('[' + $i + '] JS 兼容编码: ' + $e1 + ' -> ' + $(if ($goodEnc) { 'MATCH' } else { 'MISMATCH, 期望 ' + $want })) -ForegroundColor $(if ($goodEnc) { 'Green' } else { 'Red' })
    if (-not $goodEnc) { $ok = $false }
    $i++

    # 3. 连通性
    $cfg = Get-Config
    Write-Host ('[' + $i + '] 直连探测 www.msftconnecttest.com ...') -ForegroundColor Gray
    $r = Invoke-CampusHttp -Url 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutMs 6000
    Write-Host ('      HTTP=' + $r.StatusCode + '  Len=' + $r.Body.Length + '  Location=' + $r.Location) -ForegroundColor Gray
    $i++

    Write-Host ''
    if ($ok) { Write-Host '自检通过' -ForegroundColor Green; return 0 }
    Write-Host '自检失败' -ForegroundColor Red
    return 1
}

# ---------------------------------------------------------------------------
# 模式: -Logout  (主动下线, 用来验证自动登录是不是真的能把网救回来)
# ---------------------------------------------------------------------------
function Invoke-LogoutMode {
    param($Config)

    $info = Get-OnlineInfo -Config $Config
    if (-not $info -or -not $info.userIndex) {
        Write-Host '拿不到 userIndex, 当前可能本来就没在线, 无需下线' -ForegroundColor Yellow
        return 1
    }

    Write-Host ('即将下线: {0} / {1} / {2}' -f $info.userName, $info.userId, $info.userIp) -ForegroundColor Yellow
    $api = (Get-PortalBase -Config $Config) + 'InterFace.do?method=logout'
    # 前端就是裸拼 "userIndex=" + userIndex, 这里保持一致
    $r = Invoke-CampusHttp -Url $api -Method POST -Body ('userIndex=' + [string]$info.userIndex) `
                           -TimeoutMs 10000

    if ($r.StatusCode -ne 200 -or -not $r.Body) {
        Write-Host ('下线请求失败: HTTP=' + $r.StatusCode + ' ' + $r.Error) -ForegroundColor Red
        return 1
    }
    Write-Host ('下线返回: ' + $r.Body) -ForegroundColor Gray

    Start-Sleep -Seconds 3
    if (Test-CampusOnline -Config $Config) {
        Write-Host '注意: 下线后仍然联网(可能被 portal 立即重认证或被 AC 直通)' -ForegroundColor Yellow
        return 1
    }
    Write-Host '已成功下线, 现在可以运行本脚本验证自动登录:' -ForegroundColor Green
    Write-Host '  powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1' -ForegroundColor Cyan
    return 0
}

# ===========================================================================
# 主流程
# ===========================================================================
function Invoke-Main {
    param($Config)

    if (-not $Config.UserId) {
        Write-Log '还没有配置学号, 请先运行: CampusNetLogin.ps1 -Setup' 'ERROR'
        return 2
    }
    $password = Get-CredentialPlain
    if (-not $password) {
        Write-Log '读不到上网密码, 请重新运行: CampusNetLogin.ps1 -Setup' 'ERROR'
        return 2
    }

    if (-not $Force) {
        if (Test-CampusOnline -Config $Config) {
            Write-Log '当前已联网, 无需认证' 'INFO'
            return 0
        }
        Write-Log '检测到未认证, 开始自动登录' 'INFO'
    } else {
        Write-Log '强制认证模式' 'INFO'
    }

    $retries = 1
    if ($Config.LoginRetries) { $retries = [int]$Config.LoginRetries }
    if ($retries -lt 1) { $retries = 1 }
    $delay = 4
    if ($Config.RetryDelaySec) { $delay = [int]$Config.RetryDelaySec }

    for ($attempt = 1; $attempt -le $retries; $attempt++) {
        Write-Log ('第 {0}/{1} 次尝试认证' -f $attempt, $retries) 'INFO'
        $res = Invoke-PortalLogin -Config $Config -UserId $Config.UserId -Password $password

        if ($res.Success) {
            Start-Sleep -Seconds 2
            if (Test-CampusOnline -Config $Config) {
                Write-Log '联网复核通过, 认证流程结束' 'OK'
                return 0
            }
            Write-Log '接口报成功但联网复核未通过, 继续重试' 'WARN'
            continue
        }

        if ($res.NeedCaptcha) {
            Write-Log '需要输入验证码, 请手动打开 http://portal.example.edu.cn/ 登录一次, 之后本脚本可继续自动运行' 'ERROR'
            return 3
        }

        if ($attempt -lt $retries) {
            Write-Log ('等待 {0} 秒后重试' -f $delay) 'INFO'
            Start-Sleep -Seconds $delay
        }
    }

    Write-Log '多次尝试后仍未认证成功' 'ERROR'
    return 1
}

function Remove-OldLogs {
    param($Config)
    $days = 30
    if ($Config.LogKeepDays) { $days = [int]$Config.LogKeepDays }
    $cut = (Get-Date).AddDays(-$days)
    Get-ChildItem $LogDir -File -Filter 'autologin-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cut } |
        ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue } catch { } }
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 被 CampusNetSetup.ps1 点源时只导出函数, 不执行主流程
# ---------------------------------------------------------------------------
if ($AsLibrary) { return }

$exit = 0
$cfg = Get-Config
$cfgPathResolved = $ConfigPath
if ($cfg.UseSystemProxy) { $script:UseSystemProxy = $true }

if ($SelfTest) {
    $exit = Invoke-SelfTestMode
} elseif ($Setup) {
    $exit = Invoke-SetupMode -Config $cfg
} elseif ($Status) {
    $exit = Invoke-StatusMode -Config $cfg
} elseif ($Logout) {
    $exit = Invoke-LogoutMode -Config $cfg
} else {
    Remove-OldLogs -Config $cfg
    $exit = Invoke-Main -Config $cfg
}

exit $exit
