package com.example.band

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the UI and the two activity-scoped platform channels:
 *  - band/hwtest      : headless hardware-test trigger (adb intent extra).
 *  - band/sleep_audio : start/stop the microphone service.
 *
 * `band/notifications` is deliberately NOT registered here — it lives on the
 * process-lifetime engine created by [BandApplication], because notifications
 * must reach Dart when no activity exists. See [NotificationChannelHost].
 *
 * This activity *attaches to* the warm engine rather than creating its own, so
 * there is exactly one Dart isolate (and therefore one BLE connection) for the
 * lifetime of the process, and destroying the activity does not kill it.
 */
class MainActivity : FlutterActivity() {
    private val hwtestChannelName = "band/hwtest"
    private val sleepAudioChannelName = "band/sleep_audio"
    private var hwtestChannel: MethodChannel? = null
    private var sleepAudioChannel: MethodChannel? = null
    private var pending = false
    private var pendingSleepCapture = false
    private var pendingStopSleepAudio = false

    /**
     * Reuse the warm engine. Returning null (e.g. if it failed to start) makes
     * FlutterActivity fall back to creating its own, so the UI still works.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(BandApplication.ENGINE_ID)

    /** The engine outlives this activity — it belongs to the application. */
    override fun shouldDestroyEngineWithHost(): Boolean = false

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
                "checkSleepCaptureTrigger" -> {
                    val p = pendingSleepCapture
                    pendingSleepCapture = false
                    result.success(p)
                }
                else -> result.notImplemented()
            }
        }
        if (intent?.getBooleanExtra("run_hwtest", false) == true) {
            pending = true
        }
        if (intent?.getBooleanExtra("sleep_capture", false) == true) {
            pendingSleepCapture = true
        }

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
        if (intent.getBooleanExtra("sleep_capture", false)) {
            val c = hwtestChannel
            if (c != null) {
                c.invokeMethod("applySleepCapture", null)
            } else {
                pendingSleepCapture = true
            }
        }
        if (intent.getBooleanExtra("stop_sleep_audio", false)) {
            val c = sleepAudioChannel
            if (c != null) c.invokeMethod("onStopRequested", null) else pendingStopSleepAudio = true
        }
    }
}
