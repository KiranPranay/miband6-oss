package com.example.band

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * System-bound listener that receives every posted notification once the user
 * grants "Notification access". Extracts the package, title and text and hands
 * them to [NotificationBridge] (filtering by the user's selected apps happens on
 * the Flutter side).
 *
 * Two classes of bug were fixed here (findings-17):
 *
 *  1. **Text extraction was too narrow.** Only `EXTRA_TITLE` + `EXTRA_TEXT`/
 *     `EXTRA_BIG_TEXT` were read, so `MessagingStyle` notifications — which is
 *     how WhatsApp, Signal, Telegram and Messages all post — frequently yielded
 *     a blank body and were then dropped as empty. `EXTRA_MESSAGES` and
 *     `EXTRA_TEXT_LINES` are now consulted as well.
 *  2. **The service could stay unbound.** Android unbinds notification
 *     listeners after app updates, low memory or a crash, and does not reliably
 *     rebind. [requestRebind] exposes the documented recovery, and
 *     [onListenerDisconnected] asks for it immediately.
 */
class BandNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "Notification listener connected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        // Ask the system to bring us back; without this the relay silently stops
        // working until the user toggles notification access by hand.
        Log.w(TAG, "Notification listener disconnected — requesting rebind")
        requestRebind(applicationContext)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        try {
            sbn ?: return
            val pkg = sbn.packageName ?: return
            if (pkg == packageName) return // ignore our own notifications

            val n = sbn.notification ?: return

            // Group summaries duplicate their children; skip them.
            if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return

            // Ongoing notifications are usually media players and foreground
            // services. Calls are also FLAG_ONGOING, so let the call category
            // through — not to alert the band (call state comes from telephony,
            // see CallStateHost) but because its title is the caller's name.
            val isCall = n.category == Notification.CATEGORY_CALL
            if (!isCall && n.flags and Notification.FLAG_ONGOING_EVENT != 0) return

            val ex = n.extras ?: return
            val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
            val text = extractText(n)

            if (title.isBlank() && text.isBlank()) {
                Log.d(TAG, "Dropping blank notification from $pkg")
                return
            }

            NotificationBridge.dispatch(
                applicationContext,
                pkg,
                title.trim(),
                text.trim(),
                isCall,
            )
        } catch (e: Exception) {
            // Never crash the listener: an exception here gets the service
            // disabled by the system, which loses every future notification.
            Log.e(TAG, "onNotificationPosted failed", e)
        }
    }


    /**
     * Best-effort body text, in decreasing order of usefulness.
     *
     * `MessagingStyle` (used by every major chat app) puts the actual message in
     * `EXTRA_MESSAGES`, not `EXTRA_TEXT`, which is why chat notifications used
     * to arrive blank.
     */
    private fun extractText(n: Notification): String {
        val ex = n.extras ?: return ""

        // MessagingStyle — take the most recent message (API 24+).
        //
        // Read the raw Bundle array rather than
        // Notification.MessagingStyle.extractMessagingStyleFromNotification():
        // the keys below are the documented Message bundle format and work on
        // every API level that has EXTRA_MESSAGES at all, with no androidx
        // dependency and no reflection.
        try {
            val messages = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                ex.getParcelableArray(Notification.EXTRA_MESSAGES)
            } else {
                null
            }
            val last = messages?.lastOrNull() as? Bundle
            if (last != null) {
                val body = last.getCharSequence("text")?.toString().orEmpty()
                val sender = last.getCharSequence("sender")?.toString().orEmpty()
                if (body.isNotBlank()) {
                    return if (sender.isNotBlank()) "$sender: $body" else body
                }
            }
        } catch (e: Exception) {
            Log.d(TAG, "MessagingStyle extraction failed: ${e.message}")
        }

        // InboxStyle — join the visible lines.
        val lines = ex.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
        if (lines != null && lines.isNotEmpty()) {
            val joined = lines.joinToString("\n") { it.toString() }
            if (joined.isNotBlank()) return joined
        }

        val big = ex.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
        if (!big.isNullOrBlank()) return big

        return ex.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
    }

    companion object {
        private const val TAG = "BandNotifListener"

        /**
         * Asks the system to rebind this listener. Returns false on API levels
         * that predate the call (nothing to do there).
         */
        fun requestRebind(context: Context): Boolean = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                // Qualified explicitly: the unqualified name would resolve to
                // this companion's own Context overload.
                NotificationListenerService.requestRebind(
                    ComponentName(context, BandNotificationListener::class.java),
                )
                true
            } else {
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "requestRebind failed", e)
            false
        }
    }
}
