# 校园网自动认证（城市热点 Dr.COM ePortal 通用版）

开机自动认证、掉线自动重连。你以后再也不用点那个登录页了。

> **Tired of logging into the campus network every day? This system handles it for you — perfectly.**
>
> Automatic authentication at boot, automatic reconnect after a drop. Never click that login page again.
> Works on any campus running **Dr.COM ePortal / SAM+** — the wizard identifies the portal, probes its
> encryption scheme on its own, then verifies by actually logging in once.
>
> 📄 [English README →](README.en.md)

**这套工具不绑定学校**：把登录页网址粘进安装向导，它会自动识别 portal、自己探测加密方式，
然后真登一次验证。凡是 **城市热点 Dr.COM ePortal / SAM+** 的学校，理论上都能直接吃下来。

- 认证系统：**城市热点 Dr.COM ePortal / SAM+**（开发时在真实校园网环境实测通过）
- 登录接口：`POST <portal>/eportal/InterFace.do?method=login`
- 权限要求：**不需要管理员权限**（主方案走启动文件夹）

> 支持范围说实话：只覆盖 Dr.COM ePortal。深澜 Srun / 锐捷 / H3C 之类的系统，
> 向导会**明确告诉你"不支持"**，不会假装能用。那种情况要用 `capture-portal.ps1` 抓素材再适配。

---

## 一、快速开始（自己装）

**最省事**：双击 `一键安装.cmd`，跟着向导走。

**或者命令行**：

```powershell
cd campus-net

# 安装向导：粘网址 → 选服务 → 输账号密码 → 自动试登验证 → 自动装机
powershell -ExecutionPolicy Bypass -File .\CampusNetSetup.ps1

# 看状态
powershell -ExecutionPolicy Bypass -File .\Install-AutoLogin.ps1 -Status
```

向导会问你三件事：

1. **粘贴登录页网址** —— 先把 WiFi 断开重连，等浏览器跳出登录页，**先别登录**，
   把地址栏那一整串（带 `?wlanuserip=...` 的）复制过来
2. **选服务** —— 向导会自己列出你们学校的运营商列表（移动 / 联通 / 电信 / 仅限校内…）
3. **输学号密码** —— 就是智慧校园统一身份认证那一套

然后它会真的试登一次确认能用，成了就自动注册开机启动。

---

## 二、给别人装（分发）

`campus-net` 整个文件夹拷给对方就行，不用改任何代码。对方只要：

```
双击  一键安装.cmd
  ↓
粘贴他自己浏览器里的登录页网址
  ↓
选服务、输他自己的学号和密码
  ↓
完成
```

不同学校、不同运营商都能各自适配，因为 portal 地址、加密公钥、服务名全是**运行时探测**出来的，
没有一处写死在代码里。

**分发前记得清掉自己的隐私数据**，把这几样删掉再打包（本仓库已清理完毕，不含下列任何文件）：

```
credential.xml        你的密码（DPAPI 加密，但别传）
config.json           里面有你的学号
last-querystring.txt  会话参数缓存
logs\                 运行日志
portal-probe\         逆向证据（含测试数据）
```

或者直接跑：

```powershell
powershell -ExecutionPolicy Bypass -File .\打包分发.ps1
```

它会复制出一个干净的 `campus-net-dist\` 目录（已剔除上面那些），你直接压缩发人即可。

---

## 三、验证它是不是真的管用

光看"已联网"不算数，因为你现在本来就通着。要真验证，主动下线再跑：

```powershell
# 主动下线（会把你踢下线）
powershell -ExecutionPolicy Bypass -File .\CampusNetLogin.ps1 -Logout

# 立刻让它自动登录回来
powershell -ExecutionPolicy Bypass -File .\CampusNetLogin.ps1
```

第二条命令跑完能重新上网，就说明成了。也可以什么都不做，等守护进程（默认 20 秒一轮）自己把它救回来，看日志：

```
logs\watch-YYYYMMDD.log
logs\autologin-YYYYMMDD.log
```

> 安装向导的"真实试登验证"其实已经替你做了这件事：它会先把你踢下线，再用你刚填的账号登回来。

---

## 四、文件说明

| 文件 | 作用 |
|---|---|
| `一键安装.cmd` | **给别人用的入口**，双击就跑向导 |
| `CampusNetSetup.ps1` | 安装向导：识别 portal、探测加密、选服务、试登、装机 |
| `CampusNetLogin.ps1` | 主程序。检测联网、探测 portal、RSA 加密、提交认证 |
| `Watch-CampusNet.ps1` | 守护进程。常驻后台，断网/切网秒级响应，自动调主程序 |
| `Install-AutoLogin.ps1` | 装机 / 卸载 / 看状态 |
| `capture-portal.ps1` | 现场抓包器（学校改系统时用它重新逆向，见第八节） |
| `打包分发.ps1` | 生成干净的待分发目录 |
| `config.json` | 配置（portal 地址、学号、服务名等）。**首次运行自动生成**，模板见 `config.example.json`；填了学号后**别提交到 Git** |
| `config.example.json` | 配置模板（不含任何个人信息） |
| `credential.xml` | 密码，**DPAPI 加密，绑定当前 Windows 用户**（运行时生成，不入库） |
| `logs\` | 运行日志（UTF-8，自动清理 30 天前的）（运行时生成，不入库） |
| `portal-probe\` | 逆向证据（portal 页面 / JS / 抓包）。**本仓库不含此目录**——需要时用 `capture-portal.ps1` 自己抓 |

### 各脚本开关

```powershell
# CampusNetSetup.ps1 安装向导
-PortalUrl   直接给登录页网址, 跳过第一步交互
-UserId      预填学号
-Service     直接指定服务名
-Diagnose    只识别+探测并打印结果, 不改配置不装机（排错神器）
-SkipVerify  跳过真实试登验证
-NoInstall   只写配置, 不注册开机启动

# CampusNetLogin.ps1 主程序
-Setup      简易配置（只问学号密码, 不自动识别 portal）
-Status     查看当前在线信息（姓名/IP/服务/剩余时长）
-Logout     主动下线（验证用）
-SelfTest   自检：RSA 实现 + 编码 + 连通性
-Force      无视"已在线"，强制走一次认证流程
-Quiet      只写日志，不输出控制台（守护进程用的就是这个）
```

排错先跑这个，一眼看出问题在哪：

```powershell
powershell -ExecutionPolicy Bypass -File .\CampusNetSetup.ps1 -Diagnose
```


---

## 五、逆向出来的技术细节

留档，方便以后学校改系统时对照。

### 4.1 认证流程

```
1. 检测联网        GET http://www.msftconnecttest.com/connecttest.txt
                   期望 200 且内容为 "Microsoft Connect Test"
                   被劫持时会 302 到 portal

2. 取 queryString  未认证时 AC 会把 HTTP 请求劫持到:
                   http://portal.example.edu.cn/eportal/index.jsp?wlanuserip=...&wlanacname=...
                     &ssid=&nasip=...&snmpagentip=&mac=...&t=wireless-v2&url=...
                   取 ? 后面那一整串，就是 queryString

3. 取权威配置      POST http://portal.example.edu.cn/eportal/InterFace.do?method=pageInfo
                   body: queryString=<双重 URL 编码的 queryString>
                   返回关键字段:
                     passwordEncrypt   = "true"   ← 注意 HTML 里静态写的是 false，会被 pageInfo 覆盖
                     publicKeyExponent = "10001"
                     publicKeyModulus  = "94dd...7871"  (1024 位)
                     validCodeUrl      = ""       ← 非空才需要验证码
                     prefixValue       = ""       ← 域名前缀

4. 提交认证        POST http://portal.example.edu.cn/eportal/InterFace.do?method=login
                   Content-Type: application/x-www-form-urlencoded; charset=UTF-8
                   body:
                     userId=<双重编码的学号>
                     password=<双重编码的RSA密文>
                     service=<双重编码的服务名，本部署为 移动>
                     queryString=<双重编码的 queryString>
                     operatorPwd=&operatorUserId=&validcode=
                     passwordEncrypt=<双重编码的 true>
```

### 4.2 RSA 加密 —— 这不是标准 PKCS#1

Portal 前端用的是 David Shapiro 那套 Barrett BigInt 库（`security.js` 里的 `RSAUtils`），
跟 .NET 的 `RSA.Encrypt` / `RSACryptoServiceProvider` **完全不兼容**，硬套只会失败。

明文构造：

```javascript
passwordMac = 密码 + ">" + mac     // mac 取自 queryString 的 mac 参数；缺失时用 "111111111"
passwordEncode = passwordMac.split("").reverse().join("")   // 整串反转
```

加密的三个坑：

1. **零填充，不是 PKCS#1 v1.5** —— 明文尾部补 `0x00` 到 `chunkSize` 的整数倍
2. **chunkSize = 2 × biHighIndex(modulus)** —— 1024 位密钥对应 **126 字节**，不是 128
3. **块内小端字节序** —— `digit[j] = a[k] + (a[k+1] << 8)`，低字节在前
4. 输出：**小写 hex，不补前导零**，多块之间用**一个空格**连接

本仓库的 PowerShell 实现（`Get-JsRsaCipher`）已经和 **portal 原版 `security.js`** 做过差分比对，
密文逐字符一致，测试向量固化在 `-SelfTest` 里：

```
chunkSize = 126
pwd=TestPass123! mac=9d4d2299bbbc9b189c95ce532a332372
  -> 3e744017b3b57366...b9b5a034     MATCH
pwd=a mac=111111111
  -> 51cc8c729fa3e6d0...1d6ed12ed    MATCH
```

### 4.3 其他可用接口

浏览器历史里还翻出了这些，脚本里用到了标 ★ 的：

| 接口 | 说明 |
|---|---|
| `method=login` ★ | 认证 |
| `method=pageInfo` ★ | 取密码加密开关和公钥 |
| `method=getOnlineUserInfo` ★ | 取在线信息（姓名/IP/MAC/服务/剩余时长） |
| `method=logout` ★ | 下线 |
| `method=keepalive` | 保活（本部署 `keepaliveInterval=0`，不需要） |
| `method=getServices` | 取服务列表（移动 / 仅限校内） |
| `method=switchService` | 切换服务 |
| `method=registerMac` | 注册 MAC 免认证（本部署 `isAlowMab: false`，不可用） |
| `method=logoutByUserIdAndPass` | 用账号密码下线所有设备 |

自助服务页：`http://selfservice.example.edu.cn/selfservice/`

### 4.4 已踩过的坑

- **本机开着 Clash 系统代理 `127.0.0.1:7897`**：所有探测请求必须 `Proxy = $null` 强制直连，
  否则你抓到的是代理的响应，永远发现不了校园网的 portal 劫持。脚本里默认直连。
- **静态 HTML 里的 `passwordEncrypt=false` 是假的**：真实值以 `pageInfo` 接口为准（`true`）。
- **Windows PowerShell 5.1 读无 BOM 的 UTF-8 源码会按 GBK 解码**：中文注释会让字符串收尾引号被
  双字节字符吃掉，整个脚本语法崩掉。**这几个 `.ps1` 必须保持 UTF-8 with BOM**，
  用记事本/VSCode 改动后务必确认编码还是 UTF-8 BOM。

---

## 六、配置项（config.json）

```json
{
  "PortalScheme": "http",
  "PortalHost": "portal.example.edu.cn",
  "PortalPath": "/eportal/",
  "Service": "移动",
  "UserId": "你的学号",
  "ProbeUrls": [ ... 用来触发 portal 劫持的探针地址 ... ],
  "OnlineCheckUrls": [ ... 判断是否已联网的地址 ... ],
  "UseSystemProxy": false,
  "LoginRetries": 3,
  "RetryDelaySec": 4,
  "LogKeepDays": 30,
  "LogDir": ""
}
```

- `PortalScheme` / `PortalHost` / `PortalPath` 由安装向导根据你粘的网址自动填，**不用手改**
- `PortalHost` 带非标准端口时写成 `主机:端口`
- `Service` 可选 `移动` / `联通` / `电信` / `仅限校内`，具体看向导列出来的列表；
  留空表示用服务端默认
- `UseSystemProxy` 默认 `false`，**别改**，除非你确知自己不需要绕过代理

---

## 七、排错

**先跑这个，一眼看出问题在哪：**

```powershell
powershell -ExecutionPolicy Bypass -File .\CampusNetSetup.ps1 -Diagnose
```

它会打印：识别到的认证系统、portal 基址、加密开关、公钥长度、是否需要验证码、
服务列表、当前在线账号。而且**不会改动任何配置**。

| 现象 | 原因 / 处理 |
|---|---|
| 向导说"没能识别出 ePortal" | 网址粘错了，或者你们学校用的不是城市热点。确认是后者就别折腾了，本工具不支持 |
| 退出码 `2` | 账号/密码没填完。重跑 `CampusNetSetup.ps1` |
| 退出码 `3` | Portal 要求验证码。手动打开登录页把验证码填对登录一次，之后脚本可继续自动跑 |
| 日志里 `no-querystring` | 所有探针都没被劫持。检查是不是还连着别的网（手机热点），或把 `ProbeUrls` 换一个地址 |
| 日志里 `pageinfo-failed` | Portal 变了或网络不通，跑 `capture-portal.ps1` 重新抓一次 |
| 密码对了但认证失败 | 看日志里的 `message` 原文。`未绑定服务对应的运营商` = 宿舍网要去自助服务页绑定运营商账号 |
| 服务选错了 | 重跑 `CampusNetSetup.ps1`，在第 4 步换个运营商 |
| 守护进程没起来 | 手动跑 `powershell -File Watch-CampusNet.ps1` 看报错 |
| 换 Windows 用户后失效 | DPAPI 加密跟用户绑定，新用户下重新跑向导 |

**注意**：校园网公告写着「智慧校园账号每 60 天必须登录一次，否则进入休眠，休眠后宿舍网络要重新绑定运营商账号」。
本脚本走的就是同一个认证接口，正常使用不会触发休眠。

---

## 八、如果学校改了认证系统

改了接口、换了 portal 地址、加了验证码，这套脚本会失效。重新适配的流程：

```powershell
# 1. 把 Clash 系统代理关掉，然后断网重连、打开登录页
# 2. 跑抓包器（默认监听 30 分钟，每隔 3 秒轮询）
powershell -ExecutionPolicy Bypass -File .\capture-portal.ps1 -DurationMinutes 30
# 3. 素材落在 logs\capture-<时间戳>\ 下：
#    probe-report.txt  跳转链、响应头
#    portal-page.html  登录页完整 HTML
#    asset-*.js        前端 JS（RSA 实现和登录逻辑都在这）
#    net-snapshot.txt  现场网络快照
```

拿到新的 JS 后，对照第 5 节确认三件事：登录接口路径、body 字段、加密方式。
如果还是城市热点 ePortal，基本只改 `config.json` 里的 `PortalHost` / `PortalPath` / `Service` 就行。

---

## 九、安全说明

- 密码用 Windows DPAPI 加密存在 `credential.xml`，**只有当前 Windows 用户能解开**，
  换机器或换用户都解不开。这个文件别乱传。
- 脚本只访问学校自己的 portal（`portal.example.edu.cn` / `selfservice.example.edu.cn`）和几个通用探针域名。
- 不写注册表，不改系统代理，不装驱动，不常驻服务。
- 卸载：`powershell -File Install-AutoLogin.ps1 -Uninstall`
