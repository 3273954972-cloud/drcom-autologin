# Campus Network Auto-Login (Dr.COM ePortal universal)

> **Tired of logging into the campus network every day? This system handles it for you — perfectly.**

Automatic authentication at boot, automatic reconnect after a drop. Never click that login page again.

This tool is **not tied to any specific campus**: paste your login page URL into the wizard, and it
identifies the portal, probes the encryption scheme on its own, then verifies by actually logging in
once. Any campus running **Dr.COM ePortal / SAM+** should work out of the box.

- Auth system: **Dr.COM ePortal / SAM+**
- Login endpoint: `POST <portal>/eportal/InterFace.do?method=login`
- Privileges: **no administrator rights required** (the main path uses the Startup folder)
- Platform: Windows, PowerShell 5.1+

> **Scope, honestly:** this covers Dr.COM ePortal only. For Srun / Ruijie / H3C, the wizard will
> **explicitly tell you it is unsupported** rather than pretend otherwise. In that case use
> `capture-portal.ps1` to capture fresh material and adapt it yourself.

📄 中文文档见 [README.md](README.md)

---

## Quick start

Double-click `一键安装.cmd` and follow the wizard. Or from the command line:

```powershell
powershell -ExecutionPolicy Bypass -File .\CampusNetSetup.ps1
powershell -ExecutionPolicy Bypass -File .\Install-AutoLogin.ps1 -Status
```

The wizard asks three things:

1. **Paste the login page URL** — disconnect and reconnect Wi-Fi, wait for the browser to bounce to the
   login page, **do not log in yet**, and copy the whole address bar (the one carrying `?wlanuserip=...`)
2. **Pick a service** — the wizard lists your campus's carrier options (China Mobile / Unicom / Telecom /
   on-campus only …)
3. **Enter your student ID and password** — the same credentials as your campus single sign-on

Then it performs a real test login, and registers itself to run at startup.

## Verify it actually works

Showing "connected" proves nothing — you are connected already. Take yourself offline and let it bring
you back:

```powershell
# Force logout (this kicks you off the network)
powershell -ExecutionPolicy Bypass -File .\CampusNetLogin.ps1 -Logout

# Let it log you straight back in
powershell -ExecutionPolicy Bypass -File .\CampusNetLogin.ps1
```

## Troubleshooting: start here

```powershell
powershell -ExecutionPolicy Bypass -File .\CampusNetSetup.ps1 -Diagnose
```

It prints the detected auth system, portal base, encryption switch, key length, captcha requirement,
service list, and current online account — **without modifying any configuration**.

## Files

| File | Purpose |
|---|---|
| `一键安装.cmd` | End-user entry point — double-click to run the wizard |
| `CampusNetSetup.ps1` | Setup wizard: detect portal, probe encryption, pick service, test login, install |
| `CampusNetLogin.ps1` | Main program: connectivity check, portal probe, RSA encryption, auth submission |
| `Watch-CampusNet.ps1` | Daemon: stays resident, reacts to drops and network switches within seconds |
| `Install-AutoLogin.ps1` | Install / uninstall / status |
| `capture-portal.ps1` | Live portal capture — for re-reverse-engineering when your campus changes systems |
| `打包分发.ps1` | Produce a clean distribution directory |
| `config.example.json` | Configuration template (contains no personal data) |

## The interesting part: RSA that is *not* PKCS#1

The portal front end uses David Shapiro's Barrett BigInt library (`RSAUtils` in `security.js`), which is
**completely incompatible** with .NET's `RSA.Encrypt` / `RSACryptoServiceProvider`. Naively wrapping it
around just fails. The plaintext is built like this:

```javascript
passwordMac    = password + ">" + mac      // mac comes from the queryString; "111111111" when absent
passwordEncode = passwordMac.split("").reverse().join("")   // the whole string, reversed
```

Three traps:

1. **Zero padding, not PKCS#1 v1.5** — pad the plaintext with `0x00` up to a multiple of `chunkSize`
2. **`chunkSize = 2 × biHighIndex(modulus)`** — a 1024-bit key means **126 bytes**, not 128
3. **Little-endian byte order inside each block** — `digit[j] = a[k] + (a[k+1] << 8)`
4. Output: lowercase hex, no leading zeros, chunks joined by a **single space**

The PowerShell implementation in this repo (`Get-JsRsaCipher`) was diffed against the portal's original
`security.js`: ciphertexts match character for character, with test vectors frozen into `-SelfTest`.

## Gotchas worth knowing

- **Windows PowerShell 5.1 decodes BOM-less UTF-8 source as GBK.** A Chinese comment can then swallow
  the closing quote of the following string and break the entire script's syntax. **These `.ps1` files
  must stay UTF-8 with BOM** — after editing in Notepad or VS Code, verify the encoding is still UTF-8 BOM.
- **If you run a system proxy (e.g. Clash on `127.0.0.1:7897`)**, every probe request must set
  `Proxy = $null` to force a direct connection. Otherwise you capture the proxy's response and never see
  the portal hijack. The scripts force direct connections by default.

## Security notes

- Your password is stored DPAPI-encrypted in `credential.xml`, readable **only by the current Windows
  user**. Do not share that file.
- The scripts talk only to your campus portal plus a few generic connectivity-probe domains.
- No registry writes, no system proxy changes, no drivers, no Windows service.
- Uninstall: `powershell -File Install-AutoLogin.ps1 -Uninstall`
- **Never commit `config.json` or `credential.xml`** — `.gitignore` already excludes them.

## License

MIT — see [LICENSE](LICENSE).
