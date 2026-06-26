package com.example.band

import android.content.ComponentName
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts two platform channels:
 *  - band/hwtest        : headless hardware-test trigger (adb intent extra).
 *  - band/notifications : notification-access permission + installed-app list,
 *                         and (via NotificationBridge) native→Dart notification
 *                         events captured by BandNotificationListener.
 */
class MainActivity : FlutterActivity() {
    private val hwtestChannelName = "band/hwtest"
    private val notifChannelName = "band/notifications"
    private val sleepAudioChannelName = "band/sleep_audio"
    private var hwtestChannel: MethodChannel? = null
    private var sleepAudioChannel: MethodChannel? = null
    private var pending = false
    private var pendingStopSleepAudio = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        hwtestChannel = MethodChannel(messenger, hwtestChannelName)
        hwtestChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkLaunchTrigger" -> {
                    val p = pending
                    pending = false
                    result.success(p)
                }
                else -> result.notImplemented()
            }
        }
        if (intent?.getBooleanExtra("run_hwtest", false) == true) {
            pending = true
        }

        val notifChannel = MethodChannel(messenger, notifChannelName)
        notifChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAccessGranted" -> result.success(isNotificationAccessGranted())
                "openAccessSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "getInstalledApps" -> result.success(getLaunchableApps())
                else -> result.notImplemented()
            }
        }
        // Let the system-bound listener reach Dart through this channel.
        NotificationBridge.channel = notifChannel

        sleepAudioChannel = MethodChannel(messenger, sleepAudioChannelName)
        sleepAudioChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    SleepAudioService.start(this)
                    result.success(true)
                }
                "stopService" -> {
                    SleepAudioService.stop(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        // Deliver a Stop tapped from the service notification before the channel
        // existed (cold start).
        if (pendingStopSleepAudio || intent?.getBooleanExtra("stop_sleep_audio", false) == true) {
            pendingStopSleepAudio = false
            sleepAudioChannel!!.invokeMethod("onStopRequested", null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra("run_hwtest", false)) {
            val c = hwtestChannel
            if (c != null) c.invokeMethod("runHardwareTest", null) else pending = true
        }
        if (intent.getBooleanExtra("stop_sleep_audio", false)) {
            val c = sleepAudioChannel
            if (c != null) c.invokeMethod("onStopRequested", null) else pendingStopSleepAudio = true
        }
    }

    private fun isNotificationAccessGranted(): Boolean {
        val flat = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        val me = ComponentName(this, BandNotificationListener::class.java)
        return flat.split(":").any {
            val c = ComponentName.unflattenFromString(it)
            c != null && c == me
        }
    }

    private fun getLaunchableApps(): List<Map<String, String>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, String>>()
        for (ri in pm.queryIntentActivities(intent, 0)) {
            val pkg = ri.activityInfo.packageName ?: continue
            if (pkg == packageName) continue
            if (!seen.add(pkg)) continue
            apps.add(mapOf("package" to pkg, "app" to ri.loadLabel(pm).toString()))
        }
        apps.sortBy { (it["app"] ?: "").lowercase() }
        return apps
    }
}
