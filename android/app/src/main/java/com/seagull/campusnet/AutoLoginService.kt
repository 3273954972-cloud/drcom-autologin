package com.seagull.campusnet

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 后台守护服务。
 *
 * 用【轮询】而不是 ConnectivityManager 回调：校园网掉线时 IP 通常还在，
 * 系统不会上报网络变化，只有主动探测才靠得住（和 PC 版 Watch-CampusNet.ps1 同思路）。
 */
class AutoLoginService : Service() {

    companion object {
        const val CHANNEL_ID = "campusnet"
        const val NOTIF_ID = 1001
        const val ACTION_START = "com.seagull.campusnet.START"
        const val ACTION_STOP = "com.seagull.campusnet.STOP"

        @Volatile
        var running: Boolean = false
            private set
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var prefs: Prefs
    private var working = false

    private val tick = object : Runnable {
        override fun run() {
            if (!working) {
                working = true
                Thread {
                    try {
                        checkAndLogin()
                    } finally {
                        working = false
                    }
                }.start()
            }
            handler.postDelayed(this, prefs.intervalSec * 1000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        createChannel()
        startForeground(NOTIF_ID, buildNotification("正在守护校园网认证"))
        running = true
        handler.post(tick)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ────────────────────────────────────────────────────────────

    private fun checkAndLogin() {
        if (!prefs.isConfigured) {
            setStatus("未配置：请先填 portal 地址、学号和密码")
            return
        }
        val cfg = PortalClient.PortalConfig(
            scheme = prefs.portalScheme,
            host = prefs.portalHost,
            path = prefs.portalPath,
            service = prefs.service,
            userId = prefs.userId
        )
        val outcome = try {
            PortalClient.autoLogin(cfg, prefs.password)
        } catch (e: Exception) {
            setStatus("异常：${e.message ?: e.javaClass.simpleName}")
            return
        }
        val tag = when {
            outcome.reason == "already-online" -> "在线"
            outcome.success -> "登录成功"
            outcome.needCaptcha -> "需要验证码，请手动登录一次"
            else -> "登录失败：${outcome.reason}"
        }
        setStatus(tag)
    }

    private fun setStatus(text: String) {
        val line = "${stamp()}  $text"
        prefs.lastStatus = line
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, buildNotification(text))
        } catch (_: Exception) {
        }
    }

    private fun stamp(): String =
        SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault()).format(Date())

    // ────────────────────────────────────────────────────────────

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID,
                    "校园网自动认证",
                    NotificationManager.IMPORTANCE_LOW
                )
                ch.description = "保持校园网认证在线的常驻通知"
                nm.createNotificationChannel(ch)
            }
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, AutoLoginService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("校园网自动认证")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(
                    null, "停止", stop
                ).build()
            )
            .setOngoing(true)
            .build()
    }
}
