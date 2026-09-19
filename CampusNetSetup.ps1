#Requires -Version 5.1
<#
=============================================================================
 CampusNetSetup.ps1  —— 校园网自动认证 通用安装向导

 给同学用的一键安装器。只需要三步:
   1. 把浏览器里【登录页】的网址粘进来
   2. 从列表里选一个运营商
   3. 输入学号 + 密码

 剩下全自动: 识别 portal 类型 → 探测加密方式 → 真实试登一次 → 装机。

 支持范围(老实说清楚):
   · 城市热点 Dr.COM ePortal / SAM+  —— 完整支持, 自动适配。国内高校覆盖率很高。
   · 深澜 Srun / 锐捷 / H3C 等其他认证系统 —— 本向导会识别出来并明确告诉你
     "不支持", 不会假装能用。那种情况需要用 capture-portal.ps1 抓素材再适配。

 用法:
   powershell -ExecutionPolicy Bypass -File CampusNetSetup.ps1
   powershell -ExecutionPolicy Bypass -File CampusNetSetup.ps1 -PortalUrl "http://..." 
   powershell -ExecutionPolicy Bypass -File CampusNetSetup.ps1 -SkipVerify -NoInstall

 本文件必须保存为 UTF-8 with BOM。
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$PortalUrl,          # 直接给 portal 网址, 跳过第一步交互
    [string]$UserId,             # 直接给学号
    [string]$Service,            # 直接指定服务名
    [switch]$SkipVerify,         # 跳过真实试登验证
    [switch]$NoInstall,          # 只写配置, 不注册开机启动
    [switch]$Diagnose,           # 只做识别+探测并打印结果, 不配置不装机(排错用)
    [string]$ConfigPath,
    [string]$LogDir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch { }

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
$LoginScript  = Join-Path $ScriptRoot 'CampusNetLogin.ps1'
$InstallScript = Join-Path $ScriptRoot 'Install-AutoLogin.ps1'
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot 'config.json' }
if (-not $LogDir)     { $LogDir     = Join-Path $ScriptRoot 'logs' }

if (-not (Test-Path $LoginScript)) {
    Write-Host ('找不到 CampusNetLogin.ps1, 本向导必须和主脚本放在同一个目录: ' + $ScriptRoot) -ForegroundColor Red
    exit 2
}

# 点源主脚本复用全部函数(带 -AsLibrary, 不会执行主流程)
. $LoginScript -AsLibrary -ConfigPath $ConfigPath -LogDir $LogDir

# ---------------------------------------------------------------------------
# 界面小工具
# ---------------------------------------------------------------------------
function Show-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('==== ' + $Text + ' ' + ('=' * [Math]::Max(0, 56 - $Text.Length))) -ForegroundColor Cyan
}
function Say-Info { param([string]$m) Write-Host $m -ForegroundColor Gray }
function Say-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Say-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Say-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

function Read-HostDefault {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) {
        $v = Read-Host ('{0} [{1}]' -f $Prompt, $Default)
        if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
        return $v.Trim()
    }
    return (Read-Host $Prompt).Trim()
}

# ---------------------------------------------------------------------------
# 解析用户粘贴的网址
# ---------------------------------------------------------------------------
function Resolve-PortalFromUrl {
    param([string]$Raw)

    $s = $Raw.Trim().Trim('"').Trim("'").Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if ($s -notmatch '^[a-zA-Z]+://') { $s = 'http://' + $s }

    $u = $null
    try { $u = New-Object System.Uri($s) } catch { return $null }
    if (-not $u.Host) { return $null }

    $hostPart = $u.Host
    if (-not $u.IsDefaultPort) { $hostPart = '{0}:{1}' -f $u.Host, $u.Port }

    # 取目录部分(去掉文件名)
    $p = $u.AbsolutePath
    if ([string]::IsNullOrEmpty($p)) { $p = '/' }
    $lastSlash = $p.LastIndexOf('/')
    if ($lastSlash -ge 0 -and $p.Substring($lastSlash + 1) -match '\.') {
        $p = $p.Substring(0, $lastSlash + 1)
    }
    if (-not $p.EndsWith('/')) { $p = $p + '/' }

    $qs = ''
    if ($u.Query -and $u.Query.Length -gt 1) { $qs = $u.Query.Substring(1) }

    return [pscustomobject]@{
        Scheme      = $u.Scheme
        Host        = $hostPart
        Path        = $p
        QueryString = $qs
        Full        = $s
    }
}

# ---------------------------------------------------------------------------
# 识别 portal 基地址 + 认证系统类型
# ---------------------------------------------------------------------------
function Test-EPortalBase {
    param([string]$Base)

    $probe = $Base + 'InterFace.do?method=getOnlineUserInfo'
    $r = Invoke-CampusHttp -Url $probe -Method GET -TimeoutMs 6000
    if ($r.StatusCode -eq 200 -and $r.Body) {
        $t = $r.Body.Trim()
        if ($t.StartsWith('{') -and ($t -match 'userIndex|"result"|portalIp|samEdition')) {
            return $true
        }
    }
    # 退一步看 index.jsp 的响应特征
    $r2 = Invoke-CampusHttp -Url ($Base + 'index.jsp') -TimeoutMs 6000
    if ($r2.StatusCode -eq 200 -and $r2.Body -and
        ($r2.Body -match 'eportal|InterFace|上网认证|WEB认证设备')) {
        return $true
    }
    return $false
}

function Find-PortalBase {
    param($Parsed)

    $cands = New-Object System.Collections.Generic.List[string]
    $root  = ('{0}://{1}' -f $Parsed.Scheme, $Parsed.Host)
    $primary = $root + $Parsed.Path
    $cands.Add($primary)
    $cands.Add($root + '/eportal/')
    if ($Parsed.Path -ne '/') { $cands.Add($root + '/') }
    if ($Parsed.Path -notmatch 'eportal') { $cands.Add(($primary.TrimEnd('/')) + '/eportal/') }

    $seen = @{}
    foreach ($c in $cands) {
        if ($seen.ContainsKey($c)) { continue }
        $seen[$c] = $true
        Say-Info ('  试探: ' + $c)
        if (Test-EPortalBase -Base $c) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 输入 portal 网址
# ---------------------------------------------------------------------------
function Read-PortalUrl {
    param([string]$Preset)

    if ($Preset) { return (Resolve-PortalFromUrl $Preset) }

    Show-Title '第 1 步 / 5   登录页网址'
    Say-Info '请按下面做, 别跳步:'
    Say-Info '  1) 把 WiFi 断开, 再重新连上校园网'
    Say-Info '  2) 浏览器会跳出"上网认证"登录页 —— 【先别登录!】'
    Say-Info '  3) 把地址栏里那一整串网址完整复制过来'
    Say-Info ''
    Say-Info '长这样: http://xxx.xxx.xxx.xxx/eportal/index.jsp?wlanuserip=...&mac=...'
    Say-Info ''

    for ($i = 1; $i -le 5; $i++) {
        $raw = Read-Host '粘贴登录页网址'
        if ([string]::IsNullOrWhiteSpace($raw)) { Say-Err '不能为空'; continue }
        $p = Resolve-PortalFromUrl $raw
        if (-not $p) { Say-Err '这不是个合法网址, 再来一次'; continue }

        Write-Host ''
        Say-Ok  ('  协议   : ' + $p.Scheme)
        Say-Ok  ('  主机   : ' + $p.Host)
        Say-Ok  ('  路径   : ' + $p.Path)
        if ($p.QueryString) {
            Say-Ok ('  会话参数: 已拿到 (' + $p.QueryString.Length + ' 字符)')
        } else {
            Say-Warn '  会话参数: 没有! 你粘的可能不是登录页(登录页网址里应该有 ? 和一堆参数)'
            $go = Read-HostDefault '  照样继续? (会自动尝试探测) [y/n]' 'y'
            if ($go -notmatch '^(y|Y|yes|YES)$') { continue }
        }
        return $p
    }
    return $null
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
$exitCode = 0

Write-Host ''
Write-Host '########################################################' -ForegroundColor Cyan
Write-Host '#                                                      #' -ForegroundColor Cyan
Write-Host '#        校园网自动认证   安装向导                     #' -ForegroundColor Cyan
Write-Host '#        装完以后开机自动联网, 再也不用点登录页       #' -ForegroundColor Cyan
Write-Host '#                                                      #' -ForegroundColor Cyan
Write-Host '########################################################' -ForegroundColor Cyan

$cfg = Get-Config

# ---- 第 1 步: 网址 ----
$parsed = Read-PortalUrl -Preset $PortalUrl
if (-not $parsed) { Say-Err '没有拿到有效的登录页网址, 退出'; exit 2 }

# ---- 第 2 步: 识别 portal ----
Show-Title '第 2 步 / 5   识别认证系统'
$base = Find-PortalBase -Parsed $parsed
if (-not $base) {
    Say-Err ''
    Say-Err '没能识别出这是城市热点 Dr.COM ePortal 系统。'
    Say-Err ''
    Say-Warn '可能的原因:'
    Say-Warn '  · 你粘的不是登录页网址, 或者粘不全'
    Say-Warn '  · 你们学校用的是别的认证系统(深澜 Srun / 锐捷 / H3C 等)'
    Say-Warn '  · 你现在是已联网状态, 探测被放行了'
    Say-Warn ''
    Say-Warn '确认是上面第二条的话, 这套工具目前不支持你们的系统。'
    Say-Warn '可以用 capture-portal.ps1 抓一份素材, 让懂的人照着适配。'
    Say-Err ''
    exit 3
}
Say-Ok ('识别成功: 城市热点 Dr.COM ePortal')
Say-Ok ('Portal 基址: ' + $base)

# 拆回配置项
$bu = New-Object System.Uri($base)
$cfg.PortalScheme = $bu.Scheme
$cfg.PortalHost   = $(if ($bu.IsDefaultPort) { $bu.Host } else { '{0}:{1}' -f $bu.Host, $bu.Port })
$cfg.PortalPath   = $bu.AbsolutePath

# ---- 第 3 步: 探测加密配置 ----
Show-Title '第 3 步 / 5   探测认证参数'

$qs = $parsed.QueryString
if (-not $qs) {
    Say-Info '手头没有会话参数, 尝试从网络劫持里自动探测...'
    $qs = Get-PortalQueryString -Config $cfg
}
if (-not $qs) {
    Say-Err '拿不到会话参数(queryString), 无法确认加密配置。'
    Say-Warn '请重新断网重连, 打开登录页, 把【带 ? 参数】的完整网址复制过来。'
    exit 3
}

$pageInfo = Get-PortalPageInfo -Config $cfg -QueryString $qs -Referer ($base + 'index.jsp')
if (-not $pageInfo) {
    Say-Err 'pageInfo 接口调用失败, portal 可能改版了。'
    exit 3
}

$pwEncrypt = 'false'
if ($pageInfo.passwordEncrypt) { $pwEncrypt = ([string]$pageInfo.passwordEncrypt).ToLower() }
Say-Ok ('  密码加密   : ' + $pwEncrypt)

if ($pwEncrypt -eq 'true') {
    if (-not $pageInfo.publicKeyModulus) {
        Say-Err '  portal 说要加密, 但没给公钥 —— 可能是老版本实现, 本工具不支持。'
        exit 3
    }
    $cs = Get-JsRsaChunkSize -ModulusHex ([string]$pageInfo.publicKeyModulus)
    Say-Ok ('  公钥       : ' + ([string]$pageInfo.publicKeyModulus).Length + ' hex 字符, 每块 ' + $cs + ' 字节')
} else {
    Say-Warn '  portal 未启用密码加密(明文提交)'
}

if ($pageInfo.prefixValue) { Say-Ok ('  域名前缀   : ' + [string]$pageInfo.prefixValue) }

$needCaptcha = $false
if ($pageInfo.validCodeUrl) {
    $needCaptcha = $true
    Say-Warn ('  验证码     : 需要! (' + [string]$pageInfo.validCodeUrl + ')')
    Say-Warn '  说明: 你的账号现在处于"要求验证码"状态, 通常是之前输错几次密码导致的。'
    Say-Warn '        请先手动打开浏览器登录一次(把验证码填对), 之后一般就不再要求了。'
} else {
    Say-Ok '  验证码     : 不需要'
}

# ---- 诊断模式到此为止 ----
if ($Diagnose) {
    Say-Info ''
    Say-Info '正在枚举服务列表...'
    $dl = Get-PortalServices -Config $cfg -QueryString $qs
    $oi = Get-OnlineInfo -Config $cfg

    Show-Title '诊断结果'
    Say-Ok ('  认证系统   : 城市热点 Dr.COM ePortal')
    Say-Ok ('  Portal基址 : ' + $base)
    Say-Ok ('  Scheme     : ' + $cfg.PortalScheme)
    Say-Ok ('  Host       : ' + $cfg.PortalHost)
    Say-Ok ('  Path       : ' + $cfg.PortalPath)
    Say-Ok ('  queryString: ' + $qs.Length + ' 字符')
    Say-Ok ('  passwordEncrypt : ' + $pwEncrypt)
    if ($pageInfo.publicKeyModulus) {
        Say-Ok ('  公钥长度   : ' + ([string]$pageInfo.publicKeyModulus).Length + ' hex, chunkSize=' + (Get-JsRsaChunkSize -ModulusHex ([string]$pageInfo.publicKeyModulus)))
    }
    Say-Ok ('  validCodeUrl    : ' + $(if ($pageInfo.validCodeUrl) { [string]$pageInfo.validCodeUrl } else { '(空, 不需要验证码)' }))
    Say-Ok ('  prefixValue     : ' + $(if ($pageInfo.prefixValue) { [string]$pageInfo.prefixValue } else { '(空)' }))
    Say-Ok ('  服务列表   : ' + $(if ($dl.Count -gt 0) { ($dl -join ' / ') } else { '(自动枚举失败)' }))
    if ($oi) {
        Say-Ok ('  当前在线   : ' + [string]$oi.userName + ' / ' + [string]$oi.userId + ' / ' + [string]$oi.userIp + ' / ' + [string]$oi.service)
        Say-Ok ('  剩余时长   : ' + [string]$oi.maxLeavingTime)
    } else {
        Say-Warn '  当前在线   : 取不到在线信息'
    }
    Say-Info ''
    Say-Info '诊断结束, 没有改动任何配置。'
    exit 0
}

# ---- 第 4 步: 服务 + 账号 ----
Show-Title '第 4 步 / 5   选择服务 与 输入账号'

$svcList = Get-PortalServices -Config $cfg -QueryString $qs
$defaultSvc = ''
if ($cfg.Service) { $defaultSvc = [string]$cfg.Service }

$onlineInfo = Get-OnlineInfo -Config $cfg
if ($onlineInfo -and $onlineInfo.service) {
    $defaultSvc = [string]$onlineInfo.service
}

if ($svcList.Count -gt 0) {
    Say-Info '检测到以下服务(运营商), 请选择:'
    for ($i = 0; $i -lt $svcList.Count; $i++) {
        $mark = ''
        if ($svcList[$i] -eq $defaultSvc) { $mark = '   <== 当前使用' }
        Write-Host ('  [{0}] {1}{2}' -f ($i + 1), $svcList[$i], $mark) -ForegroundColor White
    }
    $pick = Read-HostDefault '输入序号(直接回车=用当前服务)' ''
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $svcList.Count) {
        $chosenSvc = $svcList[[int]$pick - 1]
    } elseif ([string]::IsNullOrWhiteSpace($pick) -and $defaultSvc) {
        $chosenSvc = $defaultSvc
    } elseif ($pick) {
        $chosenSvc = $pick
    } else {
        $chosenSvc = $defaultSvc
    }
} else {
    Say-Warn '没能自动列出服务列表。'
    Say-Info '一般填 移动 / 联通 / 电信 / 仅限校内, 不确定就直接回车留空(用服务端默认)。'
    $chosenSvc = Read-HostDefault '服务名' $defaultSvc
}
if ($Service) { $chosenSvc = $Service }
Say-Ok ('服务: ' + $(if ($chosenSvc) { $chosenSvc } else { '(服务端默认)' }))

$defUser = ''
if ($UserId)      { $defUser = $UserId }
elseif ($cfg.UserId) { $defUser = [string]$cfg.UserId }
elseif ($onlineInfo -and $onlineInfo.userId) { $defUser = [string]$onlineInfo.userId }

Say-Info ''
Say-Info '账号密码 = 智慧校园统一身份认证那一套(和查成绩/教务系统同一个)。'
$uid = ''
$sec = $null
for ($i = 1; $i -le 5; $i++) {
    $uid = Read-HostDefault '学号 / 用户名' $defUser
    if ([string]::IsNullOrWhiteSpace($uid)) { Say-Err '学号不能为空'; continue }
    $sec = Read-Host '上网密码 (输入时不显示)' -AsSecureString
    if (-not $sec -or $sec.Length -eq 0) { Say-Err '密码不能为空'; continue }
    break
}
if ([string]::IsNullOrWhiteSpace($uid) -or -not $sec -or $sec.Length -eq 0) {
    Say-Err '账号或密码未填写, 退出'
    exit 2
}

# 先落盘(即使后面验证失败, 配置也已经在了)
$cfg.UserId  = $uid
$cfg.Service = $chosenSvc
Save-JsonFile -Path $ConfigPath -Object $cfg
Save-Credential -UserId $uid -Password $sec
Save-PortalQueryString -QueryString $qs
Say-Ok ('配置已写入: ' + $ConfigPath)

# 取出明文密码供登录使用(仅在本进程内存里)
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$plainPwd = $null
try { $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

# ---- 第 5 步: 真实试登验证 ----
Show-Title '第 5 步 / 5   真实试登验证'

if ($SkipVerify) {
    Say-Warn '已跳过验证(按你的要求)。'
} else {
    $wasOnline = Test-CampusOnline -Config $cfg
    $verifyQs  = $qs

    if ($wasOnline) {
        Say-Warn '你现在是已联网状态。'
        Say-Warn '要真正验证"能不能自动登回来", 需要先把你踢下线, 再用上面的账号重新登录。'
        $go = Read-HostDefault '现在做这个验证吗? (出问题你手动打开登录页也能立刻登回来) [Y/n]' 'y'
        if ($go -match '^(y|Y|yes|YES)$') {
            $oi = Get-OnlineInfo -Config $cfg
            if ($oi -and $oi.userIndex) {
                Say-Info '正在下线...'
                $api = $base + 'InterFace.do?method=logout'
                [void](Invoke-CampusHttp -Url $api -Method POST -Body ('userIndex=' + [string]$oi.userIndex) -TimeoutMs 10000)
                Start-Sleep -Seconds 3
            }
            $verifyQs = $null      # 下线后旧会话参数作废, 必须重新探测
        } else {
            Say-Warn '跳过下线, 只做一次"接口可用性"检查(不算完整验证)。'
        }
    }

    if (-not $verifyQs) {
        Say-Info '探测新的会话参数...'
        for ($k = 1; $k -le 6; $k++) {
            $verifyQs = Get-PortalQueryString -Config $cfg
            if ($verifyQs) { break }
            Start-Sleep -Seconds 2
        }
    }

    if (-not $verifyQs) {
        Say-Err '拿不到会话参数, 无法验证。'
        Say-Warn '这不影响已保存的配置 —— 日常运行时会在断网瞬间自动重新探测。'
    } else {
        $res = Invoke-PortalLogin -Config $cfg -UserId $uid -Password $plainPwd -QueryString $verifyQs
        $plainPwd = $null

        if ($res.Success) {
            Start-Sleep -Seconds 2
            if (Test-CampusOnline -Config $cfg) {
                Say-Ok ''
                Say-Ok '########  认证成功! 自动登录已经能用了  ########'
                Save-PortalQueryString -QueryString $verifyQs
            } else {
                Say-Warn '接口报成功, 但联网复核没通过。稍后守护进程会自动再试。'
            }
        } else {
            Say-Err ''
            Say-Err ('认证失败: ' + $res.Reason)
            if ($res.NeedCaptcha) {
                Say-Warn '服务器要求验证码, 请手动登录一次后再运行本向导。'
            } else {
                Say-Warn '常见原因:'
                Say-Warn '  · 学号或密码不对(密码就是智慧校园统一身份认证那个)'
                Say-Warn '  · 服务选错了(试试另一个运营商)'
                Say-Warn '  · 宿舍网还没绑定运营商账号, 要去自助服务页绑定'
            }
            Say-Warn ''
            Say-Warn '配置已经保存了, 你可以改完再跑一次本向导。'
            $exitCode = 1
        }
    }
    $plainPwd = $null
}

# ---- 装机 ----
if ($NoInstall) {
    Say-Warn '已跳过装机(按你的要求)。之后自己跑: Install-AutoLogin.ps1'
} else {
    Show-Title '注册开机自动认证'
    if (-not (Test-Path $InstallScript)) {
        Say-Err ('找不到 ' + $InstallScript + ', 请手动运行它')
        $exitCode = 2
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallScript
        if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
    }
}

Write-Host ''
Write-Host '========================================================' -ForegroundColor Cyan
if ($exitCode -eq 0) {
    Write-Host '  搞定。以后开机自动联网, 掉线自动重连。' -ForegroundColor Green
} else {
    Write-Host '  安装完成, 但认证验证没通过, 看上面的提示。' -ForegroundColor Yellow
}
Write-Host '========================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '常用命令(在安装目录里执行):' -ForegroundColor Gray
Write-Host '  看状态   : powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1 -Status' -ForegroundColor Gray
Write-Host '  立即认证 : powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1' -ForegroundColor Gray
Write-Host '  下线验证 : powershell -ExecutionPolicy Bypass -File CampusNetLogin.ps1 -Logout' -ForegroundColor Gray
Write-Host '  重新配置 : powershell -ExecutionPolicy Bypass -File CampusNetSetup.ps1' -ForegroundColor Gray
Write-Host '  卸载     : powershell -ExecutionPolicy Bypass -File Install-AutoLogin.ps1 -Uninstall' -ForegroundColor Gray
Write-Host ''

exit $exitCode
