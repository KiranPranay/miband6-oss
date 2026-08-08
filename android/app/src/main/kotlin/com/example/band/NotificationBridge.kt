package com.example.band

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/**
 * Forwards captured notifications from [BandNotificationListener] (system-bound,
 * runs whether or not any UI exists) to the Dart relay.
 *
 * The channel now lives on the process-lifetime engine created by
 * [BandApplication], so it is normally alive whenever a notification is posted.
 * The bounded queue below covers the remaining gap: the short window during
 * process start before the Dart side has registered its handler, and the
 * pathological case where the warm engine failed to start.
 *
 * Everything here is deliberately fail-soft — a notification listener that
 * throws gets disabled by the system, which would be a much worse outcome than
 * dropping one alert.
 */
object NotificationBridge {

    private const val TAG = "NotificationBridge"

    /** Bounded so a long offline stretch can never grow without limit. */
    private const val MAX_QUEUED = 32

    @Volatile
    private var channel: MethodChannel? = null

    private val main = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<Map<String, String>>()

    /** Called once the engine's channel exists; flushes anything buffered. */
    fun attach(newChannel: MethodChannel) {
        synchronized(this) {
            channel = newChannel
        }
        flush()
    }

    /**
     * Called when a host is going away and its messenger may no longer be valid.
     * Only clears the reference if it is the one being detached, so the warm
     * engine's channel is never dropped because an activity died.
     */
    fun detach(oldChannel: MethodChannel?) {
        synchronized(this) {
            if (channel === oldChannel) channel = null
        }
    }

    fun dispatch(ctx: Context, pkg: String, title: String, text: String) {
        val payload = mapOf(
            "package" to pkg,
            "app" to appLabel(ctx, pkg),
            "title" to title,
            "text" to text,
        )
        val target = channel
        if (target == null) {
            synchronized(pending) {
                while (pending.size >= MAX_QUEUED) pending.removeFirst()
                pending.addLast(payload)
            }
            Log.w(TAG, "No Flutter channel yet — buffered '$pkg' (${pending.size} queued)")
            return
        }
        post(target, payload)
    }

    private fun flush() {
        val target = channel ?: return
        val drained: List<Map<String, String>>
        synchronized(pending) {
            if (pending.isEmpty()) return
            drained = pending.toList()
            pending.clear()
        }
        Log.i(TAG, "Flushing ${drained.size} buffered notification(s)")
        drained.forEach { post(target, it) }
    }

    private fun post(target: MethodChannel, payload: Map<String, String>) {
        main.post {
            try {
                target.invokeMethod("onNotification", payload)
            } catch (e: Exception) {
                Log.e(TAG, "invokeMethod failed", e)
            }
        }
    }

    fun appLabel(ctx: Context, pkg: String): String {
        return try {
            val pm = ctx.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (e: Exception) {
            pkg
        }
    }
}
