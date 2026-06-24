package com.example.band

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Holds the live Flutter MethodChannel and forwards captured notifications from
 * [BandNotificationListener] (system-bound, may run while the UI is backgrounded)
 * to the main Flutter isolate, where they are filtered and sent to the band.
 *
 * The channel is set by [MainActivity] and stays valid while the FlutterEngine
 * is alive (kept up by the foreground service).
 */
object NotificationBridge {
    @Volatile
    var channel: MethodChannel? = null

    private val main = Handler(Looper.getMainLooper())

    fun dispatch(ctx: Context, pkg: String, title: String, text: String) {
        val label = appLabel(ctx, pkg)
        main.post {
            channel?.invokeMethod(
                "onNotification",
                mapOf(
                    "package" to pkg,
                    "app" to label,
                    "title" to title,
                    "text" to text,
                ),
            )
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
