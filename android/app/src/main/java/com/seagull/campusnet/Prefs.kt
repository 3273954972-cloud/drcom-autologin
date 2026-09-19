package com.seagull.campusnet

import android.content.Context

/**
 * 配置存储。
 *
 * 存在 App 私有 SharedPreferences 里 —— 其他 App 读不到（需 root 才行）。
 * TODO: 如果要更强的保护，把 password 换成 Android Keystore 加密后再存。
 */
class Prefs(ctx: Context) {

    private val sp = ctx.getSharedPreferences("campusnet", Context.MODE_PRIVATE)

    /** 是否启用后台自动登录 */
    var enabled: Boolean
        get() = sp.getBoolean("enabled", false)
        set(v) = sp.edit().putBoolean("enabled", v).apply()

    var portalScheme: String
        get() = sp.getString("portal_scheme", "http") ?: "http"
        set(v) = sp.edit().putString("portal_scheme", v).apply()

    /** 形如 219.230.34.5 或 host:8080 */
    var portalHost: String
        get() = sp.getString("portal_host", "") ?: ""
        set(v) = sp.edit().putString("portal_host", v.trim()).apply()

    var portalPath: String
        get() = sp.getString("portal_path", PortalClient.DEFAULT_PORTAL_PATH)
            ?: PortalClient.DEFAULT_PORTAL_PATH
        set(v) = sp.edit().putString("portal_path", v.trim()).apply()

    /** 移动 / 联通 / 电信 / 仅限校内，留空用服务端默认 */
    var service: String
        get() = sp.getString("service", "") ?: ""
        set(v) = sp.edit().putString("service", v.trim()).apply()

    var userId: String
        get() = sp.getString("user_id", "") ?: ""
        set(v) = sp.edit().putString("user_id", v.trim()).apply()

    var password: String
        get() = sp.getString("password", "") ?: ""
        set(v) = sp.edit().putString("password", v).apply()

    /** 轮询间隔（秒），最小 10 */
    var intervalSec: Int
        get() = sp.getInt("interval_sec", 20)
        set(v) = sp.edit().putInt("interval_sec", if (v < 10) 10 else v).apply()

    /** 最近一次结果，给界面显示用 */
    var lastStatus: String
        get() = sp.getString("last_status", "") ?: ""
        set(v) = sp.edit().putString("last_status", v).apply()

    val isConfigured: Boolean
        get() = portalHost.isNotEmpty() && userId.isNotEmpty() && password.isNotEmpty()
}
