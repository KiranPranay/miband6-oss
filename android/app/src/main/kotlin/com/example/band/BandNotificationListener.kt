package com.example.band

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * System-bound listener that receives every posted notification once the user
 * grants "Notification access". Extracts the package, title and text and hands
 * them to [NotificationBridge] for forwarding to the band (filtering by the
 * user's selected apps happens on the Flutter side).
 */
class BandNotificationListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        try {
            sbn ?: return
            val pkg = sbn.packageName ?: return
            if (pkg == packageName) return // ignore our own notifications

            val n = sbn.notification ?: return
            // Skip ongoing (music/foreground services) and group summaries.
            if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return
            if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return

            val ex = n.extras ?: return
            val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
            val text = (ex.getCharSequence(Notification.EXTRA_TEXT)
                ?: ex.getCharSequence(Notification.EXTRA_BIG_TEXT))
                ?.toString().orEmpty()

            if (title.isBlank() && text.isBlank()) return

            NotificationBridge.dispatch(applicationContext, pkg, title.trim(), text.trim())
        } catch (_: Exception) {
            // never crash the listener
        }
    }
}
