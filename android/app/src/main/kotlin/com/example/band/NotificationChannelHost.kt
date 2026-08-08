package com.example.band

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

/**
 * Handlers for the `band/notifications` platform channel.
 *
 * Lives outside `MainActivity` because the channel is registered on the
 * process-lifetime engine (see [BandApplication]): the Dart side must be able to
 * ask "is notification access granted?" and receive forwarded notifications even
 * when no activity exists. Everything here therefore takes an application
 * [Context] and never touches activity state.
 */
object NotificationChannelHost {

    const val CHANNEL = "band/notifications"

    fun install(context: Context, channel: MethodChannel) {
        val app = context.applicationContext
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAccessGranted" -> result.success(isNotificationAccessGranted(app))

                "openAccessSettings" -> {
                    app.startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }

                // Asks the system to re-bind our listener. Android unbinds
                // notification listeners fairly aggressively (after updates, low
                // memory, or a crash) and does not always come back on its own;
                // this is the documented recovery and is what keeps the relay
                // working over days rather than hours.
                "requestRebind" -> {
                    result.success(BandNotificationListener.requestRebind(app))
                }

                "getInstalledApps" -> result.success(getLaunchableApps(app))

                // Used by the optional "don't buzz my wrist while I'm looking
                // at the phone" rule.
                "isScreenOn" -> result.success(isScreenOn(app))

                else -> result.notImplemented()
            }
        }
    }

    /** True when the display is interactive (screen on and not dozing). */
    private fun isScreenOn(context: Context): Boolean = try {
        val pm = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        pm.isInteractive
    } catch (e: Exception) {
        false
    }

    fun isNotificationAccessGranted(context: Context): Boolean {
        val flat = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        val me = ComponentName(context, BandNotificationListener::class.java)
        return flat.split(":").any {
            val c = ComponentName.unflattenFromString(it)
            c != null && c == me
        }
    }

    private fun getLaunchableApps(context: Context): List<Map<String, String>> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, String>>()
        for (ri in pm.queryIntentActivities(intent, 0)) {
            val pkg = ri.activityInfo.packageName ?: continue
            if (pkg == context.packageName) continue
            if (!seen.add(pkg)) continue
            apps.add(mapOf("package" to pkg, "app" to ri.loadLabel(pm).toString()))
        }
        apps.sortBy { (it["app"] ?: "").lowercase() }
        return apps
    }
}
