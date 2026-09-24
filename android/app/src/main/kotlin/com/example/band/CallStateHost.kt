package com.example.band

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * The phone's call state, from telephony — the `band/call_state` channel.
 *
 * This is the one source of truth for "is a call ringing". It used to be
 * inferred from the dialer's CATEGORY_CALL *notification*, which is the wrong
 * signal on three counts: the notification is re-posted on every refresh
 * (call timer, hold, audio route), it exists for outgoing calls too, and it
 * says nothing about ringing versus answered. Every re-post buzzed the band
 * with a fresh "incoming call". Gadgetbridge (`PhoneCallReceiver`), Mi Fit
 * (`PhoneStateReceiver`) and Notify all key off `TelephonyManager` call state
 * instead; so does this.
 *
 * Transitions, exactly as Gadgetbridge derives them:
 *
 *   IDLE    → RINGING : "ringing"   (incoming call; alert the band)
 *   RINGING → OFFHOOK : "answered"  (clear the band's call screen)
 *   IDLE    → OFFHOOK : "outgoing"  (nothing for the band)
 *   *       → IDLE    : "ended"     (clear; restore the ringer if we muted it)
 *
 * The same state reported twice is dropped, so the band is never told about
 * a call it already knows about.
 *
 * Also owns "ignore": muting the ringer for the current call. The only API
 * that does this cleanly, `TelecomManager.silenceRinger()`, needs
 * MODIFY_PHONE_STATE, which third-party apps cannot hold. Every companion
 * app instead sets the ringer mode to silent for the duration of the call
 * and puts it back afterwards (GB `PhoneCallReceiver` MUTE_CALL, Notify
 * `i9/j.java G()`), which needs Do Not Disturb access — a user grant from
 * the DND settings page, not a runtime permission.
 *
 * Lives on the process-lifetime engine, like the other hosts: a call arrives
 * with no activity alive.
 */
object CallStateHost {

    const val CHANNEL = "band/call_state"
    private const val TAG = "CallStateHost"

    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var lastState = TelephonyManager.CALL_STATE_IDLE
    private var registered = false
    private var telephonyCallback: TelephonyCallback? = null
    @Suppress("DEPRECATION")
    private var phoneStateListener: PhoneStateListener? = null

    private var savedRingerMode = -1
    private var silencedForCall = false

    fun install(context: Context, ch: MethodChannel) {
        val app = context.applicationContext
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // (Re)register the listener — called at Dart start-up and again
                // after the user grants READ_PHONE_STATE.
                "start" -> result.success(start(app))
                "current" -> result.success(phaseName(lastState))
                "hasDndAccess" -> result.success(hasDndAccess(app))
                "openDndSettings" -> result.success(openDndSettings(app))
                else -> result.notImplemented()
            }
        }
        start(app)
    }

    /** True once the telephony listener is registered. */
    fun start(ctx: Context): Boolean {
        if (registered) return true
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_PHONE_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "READ_PHONE_STATE not granted — call state unavailable")
            return false
        }
        val tm = ctx.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) = onState(ctx, state)
                }
                tm.registerTelephonyCallback(ctx.mainExecutor, cb)
                telephonyCallback = cb
            } else {
                @Suppress("DEPRECATION")
                val l = object : PhoneStateListener() {
                    @Deprecated("Deprecated in Java")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) =
                        onState(ctx, state)
                }
                @Suppress("DEPRECATION")
                tm.listen(l, PhoneStateListener.LISTEN_CALL_STATE)
                phoneStateListener = l
            }
            registered = true
            Log.i(TAG, "listening for call state")
            true
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            false
        }
    }

    private fun phaseName(state: Int): String = when (state) {
        TelephonyManager.CALL_STATE_RINGING -> "ringing"
        TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
        else -> "idle"
    }

    private fun onState(ctx: Context, state: Int) {
        val prev = lastState
        if (state == prev) return
        lastState = state
        val event = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> "ringing"
            TelephonyManager.CALL_STATE_OFFHOOK ->
                if (prev == TelephonyManager.CALL_STATE_RINGING) "answered" else "outgoing"
            else -> "ended"
        }
        if (state == TelephonyManager.CALL_STATE_IDLE) restoreRinger(ctx)
        Log.i(TAG, "call state ${phaseName(prev)} -> ${phaseName(state)}: $event")
        val target = channel ?: return
        main.post {
            try {
                target.invokeMethod("onCallState", mapOf("event" to event))
            } catch (e: Exception) {
                Log.e(TAG, "invokeMethod(onCallState) failed", e)
            }
        }
    }

    /**
     * "Ignore" from the band: mute the ringer for this call only. Returns
     * false when nothing is ringing or Do Not Disturb access is missing.
     * The previous ringer mode comes back when the call reaches IDLE.
     */
    fun silence(ctx: Context): Boolean {
        if (lastState != TelephonyManager.CALL_STATE_RINGING) {
            Log.w(TAG, "silence: no call is ringing (state ${phaseName(lastState)})")
            return false
        }
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return try {
            if (!silencedForCall) savedRingerMode = am.ringerMode
            am.ringerMode = AudioManager.RINGER_MODE_SILENT
            silencedForCall = true
            Log.i(TAG, "ringer silenced for this call (was mode $savedRingerMode)")
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "silence: Do Not Disturb access not granted")
            false
        } catch (e: Exception) {
            Log.e(TAG, "silence failed", e)
            false
        }
    }

    private fun restoreRinger(ctx: Context) {
        if (!silencedForCall) return
        silencedForCall = false
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.ringerMode = savedRingerMode
            Log.i(TAG, "ringer restored to mode $savedRingerMode")
        } catch (e: Exception) {
            Log.w(TAG, "ringer restore failed", e)
        }
    }

    fun hasDndAccess(ctx: Context): Boolean =
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .isNotificationPolicyAccessGranted

    private fun openDndSettings(ctx: Context): Boolean = try {
        ctx.startActivity(
            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (e: Exception) {
        Log.e(TAG, "openDndSettings failed", e)
        false
    }
}
