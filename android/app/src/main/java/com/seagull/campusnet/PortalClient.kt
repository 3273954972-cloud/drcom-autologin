package com.seagull.campusnet

import org.json.JSONObject
import java.math.BigInteger
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * Dr.COM ePortal 认证客户端 —— 纯逻辑层，不依赖 Android 框架。
 *
 * 移植自 campus-net 的 PowerShell 实现（CampusNetLogin.ps1）。
 * RSA 算法已用固化测试向量在本地验证通过（chunkSize=126 及两组已知明文/密文逐字符一致），
 * 迁移到这里时保持逐行对应，不要"顺手优化"。
 */
object PortalClient {

    const val DEFAULT_PORTAL_PATH = "/eportal/"

    private const val UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    val DEFAULT_PROBES = listOf(
        "http://www.msftconnecttest.com/connecttest.txt",
        "http://connect.rom.miui.com/generate_204",
        "http://223.5.5.5/",
        "http://1.1.1.1/"
    )

    val DEFAULT_ONLINE_CHECKS = listOf(
        "http://www.msftconnecttest.com/connecttest.txt",
        "http://connect.rom.miui.com/generate_204"
    )

    data class PortalConfig(
        val scheme: String = "http",
        val host: String = "",
        val path: String = DEFAULT_PORTAL_PATH,
        val service: String = "",
        val userId: String = ""
    )

    data class LoginOutcome(
        val success: Boolean,
        val reason: String,
        val needCaptcha: Boolean = false
    )

    data class HttpResult(
        val ok: Boolean,
        val status: Int = 0,
        val location: String = "",
        val body: String = "",
        val error: String = ""
    )

    // ────────────────────────────────────────────────────────────────
    // JS 兼容的 URI 编码 —— encodeURIComponent 不编码 A-Za-z0-9-_.!~*'()
    // Java 的 URLEncoder 会把空格变成 '+' 且编码 '!' 等，不可用，必须手写。
    // ────────────────────────────────────────────────────────────────

    private const val UNRESERVED = "-_.!~*'()"

    fun jsUriComponent(s: String): String {
        val sb = StringBuilder(s.length + 16)
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val v = b.toInt() and 0xFF
            val c = v.toChar()
            if (c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || UNRESERVED.indexOf(c) >= 0) {
                sb.append(c)
            } else {
                sb.append('%')
                val hex = Integer.toHexString(v).uppercase()
                if (hex.length == 1) sb.append('0')
                sb.append(hex)
            }
        }
        return sb.toString()
    }

    fun jsEncodeTwice(s: String): String = jsUriComponent(jsUriComponent(s))

    // ────────────────────────────────────────────────────────────────
    // 裸 RSA —— 复刻 portal 原版 security.js 的 RSAUtils.encryptedString
    //
    // 跟标准 PKCS#1 完全不同，用 Java 的 Cipher.getInstance("RSA") 会直接失败：
    //   1. 明文按 charCode 取值（1 字符 = 1 字节），尾部补 0x00 到 chunkSize 整数倍
    //   2. chunkSize = 2 * biHighIndex(modulus)，1024 位密钥 = 126 字节
    //   3. 每块按【小端】字节序解释为大整数
    //   4. c = m^e mod n，输出小写 hex、不补前导零
    //   5. 多块用一个空格连接
    // ────────────────────────────────────────────────────────────────

    fun jsChunkSize(modulusHex: String): Int {
        var h = modulusHex
        while (h.length % 4 != 0) h = "0$h"
        val groups = h.length / 4
        var high = 0
        for (j in 0 until groups) {
            val start = h.length - (j + 1) * 4
            if (h.substring(start, start + 4).toInt(16) != 0) high = j
        }
        return 2 * high
    }

    fun jsRsaEncrypt(plainText: String, modulusHex: String, exponentHex: String): String {
        val n = BigInteger(modulusHex, 16)
        val e = BigInteger(exponentHex, 16)
        val chunk = jsChunkSize(modulusHex)
        require(chunk > 0) { "chunkSize 计算异常: $chunk" }

        // JS charCodeAt 语义 = Latin-1 逐字符取字节
        val data = plainText.toByteArray(Charsets.ISO_8859_1)

        var pad = chunk - (data.size % chunk)
        if (pad == chunk) pad = 0
        val padded = ByteArray(data.size + pad)
        System.arraycopy(data, 0, padded, 0, data.size)

        val parts = ArrayList<String>(padded.size / chunk)
        var off = 0
        while (off < padded.size) {
            // 小端块 -> 大端字节数组 + 前导 0（保证正数）
            val be = ByteArray(chunk + 1)
            for (i in 0 until chunk) be[i] = padded[off + chunk - 1 - i]
            be[chunk] = 0
            val m = BigInteger(1, be)
            parts.add(m.modPow(e, n).toString(16))
            off += chunk
        }
        return parts.joinToString(" ")
    }

    // ────────────────────────────────────────────────────────────────
    // HTTP —— 强制不跟随重定向（未认证时 AC 会 302 到登录页，Location 才是我们要的）
    // ────────────────────────────────────────────────────────────────

    fun http(
        url: String,
        method: String = "GET",
        body: String? = null,
        referer: String? = null,
        timeoutMs: Int = 8000
    ): HttpResult {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                instanceFollowRedirects = false
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
                useCaches = false
                setRequestProperty("User-Agent", UA)
                setRequestProperty(
                    "Accept",
                    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
                )
                setRequestProperty("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
                if (referer != null) setRequestProperty("Referer", referer)
                if (method == "POST") {
                    doOutput = true
                    setRequestProperty(
                        "Content-Type",
                        "application/x-www-form-urlencoded; charset=UTF-8"
                    )
                }
            }
            if (method == "POST" && body != null) {
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val code = conn.responseCode
            val loc = conn.getHeaderField("Location") ?: ""
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val bytes = try {
                stream?.use { it.readBytes() } ?: ByteArray(0)
            } catch (e: Exception) {
                ByteArray(0)
            }
            HttpResult(true, code, loc, decodeBody(bytes), "")
        } catch (e: Exception) {
            HttpResult(false, 0, "", "", e.message ?: e.javaClass.simpleName)
        } finally {
            try { conn?.disconnect() } catch (_: Exception) { }
        }
    }

    private fun decodeBody(bytes: ByteArray): String {
        if (bytes.isEmpty()) return ""
        // 优先严格 UTF-8（portal 的 JSON 都是 UTF-8），失败再退 GBK
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (e: Exception) {
            try {
                String(bytes, charset("GBK"))
            } catch (e2: Exception) {
                String(bytes, Charsets.UTF_8)
            }
        }
    }

    // ────────────────────────────────────────────────────────────────
    // 从劫持响应里挖出 queryString
    // ────────────────────────────────────────────────────────────────

    private val RE_META = Regex("""(?i)content\s*=\s*['"][^'"]*?url=([^'";>\s]+)""")
    private val RE_JS = Regex(
        """(?i)(?:location\.(?:href|replace)\s*\(?\s*|window\.open\s*\(\s*)['"]([^'"]+)['"]"""
    )
    private val RE_HREF = Regex("""(?i)href\s*=\s*['"]([^'"]+)['"]""")

    fun extractQueryString(
        probeUrl: String,
        location: String,
        body: String,
        portalHost: String
    ): String? {
        val candidates = ArrayList<String>()
        if (location.isNotEmpty()) candidates.add(location)
        if (body.isNotEmpty()) {
            RE_META.findAll(body).forEach { candidates.add(it.groupValues[1]) }
            RE_JS.findAll(body).forEach { candidates.add(it.groupValues[1]) }
            RE_HREF.findAll(body).forEach { candidates.add(it.groupValues[1]) }
        }

        val hostOnly = portalHost.split(":").first()
        for (c in candidates) {
            var abs = c.trim()
            if (abs.isEmpty()) continue
            if (abs.startsWith("/") || abs.startsWith(".")) {
                abs = try {
                    URL(URL(probeUrl), abs).toString()
                } catch (e: Exception) {
                    continue
                }
            }
            if (!abs.startsWith("http://") && !abs.startsWith("https://")) continue
            val u = try { URL(abs) } catch (e: Exception) { continue }
            if (!u.host.equals(hostOnly, ignoreCase = true)) continue
            val q = u.query
            if (!q.isNullOrEmpty()) return q
        }
        return null
    }

    fun queryParam(qs: String, name: String): String? =
        Regex("(?:^|&)" + Regex.escape(name) + "=([^&]*)").find(qs)?.groupValues?.get(1)

    // ────────────────────────────────────────────────────────────────
    // 业务动作
    // ────────────────────────────────────────────────────────────────

    fun portalBase(cfg: PortalConfig): String {
        val p = if (cfg.path.endsWith("/")) cfg.path else cfg.path + "/"
        return "${cfg.scheme}://${cfg.host}$p"
    }

    /** 是否已经能上网。未认证时 connecttest 会被劫持并返回 portal 页面，所以要看内容。 */
    fun checkOnline(urls: List<String>): Boolean {
        for (u in urls) {
            val r = http(u, timeoutMs = 5000)
            if (!r.ok || r.status !in 200..299) continue
            if (r.status == 204) return true
            if (r.body.contains("Microsoft Connect Test", ignoreCase = true)) return true
        }
        return false
    }

    fun getQueryString(cfg: PortalConfig, probes: List<String>): String? {
        val all = ArrayList(probes)
        // 永远额外试一次 portal 自身 —— 未认证时 AC 一般会把它 302 到带参数的登录页
        all.add("${cfg.scheme}://${cfg.host}/")
        for (u in all) {
            val r = http(u, timeoutMs = 6000)
            val q = extractQueryString(u, r.location, r.body, cfg.host)
            if (q != null) return q
        }
        return null
    }

    fun pageInfo(cfg: PortalConfig, qs: String): JSONObject? {
        val api = portalBase(cfg) + "InterFace.do?method=pageInfo"
        val referer = portalBase(cfg) + "index.jsp"
        val body = "queryString=" + jsEncodeTwice(qs)
        val r = http(api, "POST", body, referer, 10000)
        if (!r.ok || r.status != 200 || r.body.isEmpty()) return null
        return try { JSONObject(r.body) } catch (e: Exception) { null }
    }

    fun login(cfg: PortalConfig, password: String, qs: String): LoginOutcome {
        val base = portalBase(cfg)
        val referer = base + "index.jsp"

        val info = pageInfo(cfg, qs)
            ?: return LoginOutcome(false, "pageinfo-failed")

        if (info.optString("validCodeUrl").isNotEmpty()) {
            return LoginOutcome(false, "captcha-required", needCaptcha = true)
        }

        val prefix = info.optString("prefixValue")
        val userForSend = prefix + cfg.userId
        val encryptFlag = info.optString("passwordEncrypt", "false").lowercase()
        val mac = queryParam(qs, "mac")?.takeIf { it.isNotEmpty() } ?: "111111111"

        val passwordField = if (encryptFlag == "true") {
            val mod = info.optString("publicKeyModulus")
            val exp = info.optString("publicKeyExponent")
            if (mod.isEmpty() || exp.isEmpty()) return LoginOutcome(false, "no-pubkey")
            // JS: passwordMac.split("").reverse().join("")
            val reversed = (password + ">" + mac).reversed()
            jsEncodeTwice(jsRsaEncrypt(reversed, mod, exp))
        } else {
            jsEncodeTwice(password)
        }

        val body = buildString {
            append("userId=").append(jsEncodeTwice(userForSend))
            append("&password=").append(passwordField)
            append("&service=").append(jsEncodeTwice(cfg.service))
            append("&queryString=").append(jsEncodeTwice(qs))
            append("&operatorPwd=")
            append("&operatorUserId=")
            append("&validcode=")
            append("&passwordEncrypt=").append(jsEncodeTwice(encryptFlag))
        }

        val r = http(base + "InterFace.do?method=login", "POST", body, referer, 12000)
        if (!r.ok || r.status != 200 || r.body.isEmpty()) {
            return LoginOutcome(false, "http-error")
        }
        val res = try { JSONObject(r.body) } catch (e: Exception) {
            return LoginOutcome(false, "bad-json")
        }
        if (res.optString("result") == "success") return LoginOutcome(true, "ok")

        val msg = res.optString("message")
        val needCaptcha =
            res.optString("validCodeUrl").isNotEmpty() || msg.contains("验证码")
        return LoginOutcome(false, msg.ifEmpty { "unknown" }, needCaptcha)
    }

    /** 一次完整流程：已在线就直接返回，否则拿 queryString 再登录。 */
    fun autoLogin(
        cfg: PortalConfig,
        password: String,
        probes: List<String> = DEFAULT_PROBES,
        onlineChecks: List<String> = DEFAULT_ONLINE_CHECKS
    ): LoginOutcome {
        if (cfg.host.isEmpty()) return LoginOutcome(false, "no-portal-host")
        if (checkOnline(onlineChecks)) return LoginOutcome(true, "already-online")
        val qs = getQueryString(cfg, probes)
            ?: return LoginOutcome(false, "no-querystring")
        return login(cfg, password, qs)
    }
}
