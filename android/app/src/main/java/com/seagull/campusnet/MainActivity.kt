package com.seagull.campusnet

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast

/** 唯一的界面：填配置、探测 portal、测试登录、开关后台守护。 */
class MainActivity : Activity() {

    private lateinit var prefs: Prefs
    private val handler = Handler(Looper.getMainLooper())

    private lateinit var etHost: EditText
    private lateinit var etPath: EditText
    private lateinit var etService: EditText
    private lateinit var etUser: EditText
    private lateinit var etPwd: EditText
    private lateinit var etInterval: EditText
    private lateinit var cbEnabled: CheckBox
    private lateinit var tvStatus: TextView

    private val refresh = object : Runnable {
        override fun run() {
            tvStatus.text = prefs.lastStatus.ifEmpty { getString(R.string.status_idle) }
            handler.postDelayed(this, 2000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)

        etHost = findViewById(R.id.etHost)
        etPath = findViewById(R.id.etPath)
        etService = findViewById(R.id.etService)
        etUser = findViewById(R.id.etUser)
        etPwd = findViewById(R.id.etPwd)
        etInterval = findViewById(R.id.etInterval)
        cbEnabled = findViewById(R.id.cbEnabled)
        tvStatus = findViewById(R.id.tvStatus)

        loadIntoUi()
        askNotificationPermission()

        findViewById<Button>(R.id.btnDetect).setOnClickListener {
            saveFromUi()
            runAsync(getString(R.string.msg_detecting)) { detectPortal() }
        }
        findViewById<Button>(R.id.btnTest).setOnClickListener {
            saveFromUi()
            runAsync(getString(R.string.msg_testing)) { testLogin() }
        }
        findViewById<Button>(R.id.btnSave).setOnClickListener {
            saveFromUi()
            toast(getString(R.string.msg_saved))
        }
        cbEnabled.setOnCheckedChangeListener { _, checked ->
            saveFromUi()
            prefs.enabled = checked
            if (checked) startDaemon() else stopDaemon()
        }
    }

    override fun onResume() {
        super.onResume()
        handler.post(refresh)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(refresh)
    }

    // ────────────────────────────────────────────────────────────

    private fun loadIntoUi() {
        etHost.setText(prefs.portalHost)
        etPath.setText(prefs.portalPath)
        etService.setText(prefs.service)
        etUser.setText(prefs.userId)
        etPwd.setText(prefs.password)
        etInterval.setText(prefs.intervalSec.toString())
        cbEnabled.isChecked = prefs.enabled
        tvStatus.text = prefs.lastStatus.ifEmpty { getString(R.string.status_idle) }
    }

    private fun saveFromUi() {
        prefs.portalHost = etHost.text.toString()
        prefs.portalPath = etPath.text.toString().ifBlank { PortalClient.DEFAULT_PORTAL_PATH }
        prefs.service = etService.text.toString()
        prefs.userId = etUser.text.toString()
        prefs.password = etPwd.text.toString()
        prefs.intervalSec = etInterval.text.toString().toIntOrNull() ?: 20
    }

    /** 用探针触发 portal 劫持，找出 portal 主机并写进配置。 */
    private fun detectPortal() {
        // 先把已填的 host 清掉，否则探测会一直只试它自己
        val cfg = PortalClient.PortalConfig(
            scheme = prefs.portalScheme,
            host = "",
            path = prefs.portalPath
        )
        var found: String? = null
        for (probe in PortalClient.DEFAULT_PROBES) {
            val r = PortalClient.http(probe, timeoutMs = 6000)
            val loc = r.location
            if (loc.isNotEmpty()) {
                val host = try { java.net.URL(loc).host } catch (e: Exception) { null }
                if (!host.isNullOrEmpty() && !isProbeHost(host)) {
                    found = host
                    break
                }
            }
        }
        if (found == null) {
            setStatus(getString(R.string.detect_failed))
            return
        }
        prefs.portalHost = found
        prefs.portalScheme = "http"
        handler.post {
            etHost.setText(found)
            toast(getString(R.string.detect_ok, found))
        }
        setStatus(getString(R.string.detect_ok, found))
    }

    private fun isProbeHost(host: String): Boolean =
        host.contains("msftconnecttest") ||
            host.contains("miui.com") ||
            host.contains("223.5.5.5") ||
            host == "1.1.1.1"

    private fun testLogin() {
        if (!prefs.isConfigured) {
            setStatus(getString(R.string.need_config))
            return
        }
        val cfg = PortalClient.PortalConfig(
            scheme = prefs.portalScheme,
            host = prefs.portalHost,
            path = prefs.portalPath,
            service = prefs.service,
            userId = prefs.userId
        )
        val outcome = PortalClient.autoLogin(cfg, prefs.password)
        val text = when {
            outcome.reason == "already-online" -> getString(R.string.test_already_online)
            outcome.success -> getString(R.string.test_ok)
            outcome.needCaptcha -> getString(R.string.test_captcha)
            else -> getString(R.string.test_fail, outcome.reason)
        }
        setStatus(text)
        handler.post { toast(text) }
    }

    private fun setStatus(text: String) {
        val line = text
        prefs.lastStatus = line
        handler.post { tvStatus.text = line }
    }

    private fun runAsync(busy: String, work: () -> Unit) {
        setStatus(busy)
        Thread {
            try {
                work()
            } catch (e: Exception) {
                setStatus("${getString(R.string.err_prefix)} ${e.message ?: e.javaClass.simpleName}")
            }
        }.start()
    }

    private fun startDaemon() {
        val svc = Intent(this, AutoLoginService::class.java)
            .setAction(AutoLoginService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(svc)
        } else {
            startService(svc)
        }
        toast(getString(R.string.daemon_started))
    }

    private fun stopDaemon() {
        stopService(Intent(this, AutoLoginService::class.java))
        toast(getString(R.string.daemon_stopped))
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
        }
    }

    private fun toast(msg: String) {
        handler.post { Toast.makeText(this, msg, Toast.LENGTH_SHORT).show() }
    }
}
