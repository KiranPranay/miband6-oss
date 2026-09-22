package com.example.band

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Handlers for the `band/call_control` platform channel — the phone-side half
 * of the band's call buttons.
 *
 * Lives on the process-lifetime engine (see [BandApplication]), like the
 * notification channel, because a call arrives when no activity exists and
 * the band's "reject" press has to be acted on then.
 *
 * Everything here is a best-effort thin wrapper over Android APIs that vary by
 * version and OEM; each returns a plain boolean so Dart can tell the band (and
 * the user) whether the action actually happened rather than assuming it did.
 */
object CallControlHost {

    const val CHANNEL = "band/call_control"
    private const val TAG = "CallControlHost"

    fun install(context: Context, channel: MethodChannel) {
        val app = context.applicationContext
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Hang up / decline the current call.
                "endCall" -> result.success(endCall(app))

                // Stop the ringer for this call without declining it — the
                // caller keeps ringing on their side and can leave voicemail.
                "silenceRinger" -> result.success(silenceRinger(app))

                // Decline with an SMS: end the call, then send the chosen text.
                "sendSms" -> {
                    val number = call.argument<String>("number")
                    val text = call.argument<String>("text")
                    if (number.isNullOrBlank() || text.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        result.success(sendSms(app, number, text))
                    }
                }

                // Find-my-phone from the band: ring at full volume until told
                // to stop, ignoring the ring/silent setting.
                "ringPhone" -> result.success(ringPhone(app))
                "stopRinging" -> result.success(stopRinging())

                "hasPermissions" -> result.success(
                    mapOf(
                        "answerPhoneCalls" to has(app, Manifest.permission.ANSWER_PHONE_CALLS),
                        "readPhoneState" to has(app, Manifest.permission.READ_PHONE_STATE),
                        "sendSms" to has(app, Manifest.permission.SEND_SMS),
                    ),
                )

                else -> result.notImplemented()
            }
        }
    }

    private var ringtone: android.media.Ringtone? = null
    private var savedRingVolume: Int = -1

    private fun ringPhone(ctx: Context): Boolean = try {
        stopRinging()
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        savedRingVolume = am.getStreamVolume(AudioManager.STREAM_RING)
        am.setStreamVolume(
            AudioManager.STREAM_RING,
            am.getStreamMaxVolume(AudioManager.STREAM_RING),
            0,
        )
        val uri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE)
        val r = android.media.RingtoneManager.getRingtone(ctx, uri)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) r.isLooping = true
        r.audioAttributes = android.media.AudioAttributes.Builder()
            .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        r.play()
        ringtone = r
        Log.i(TAG, "ringPhone: started")
        true
    } catch (e: Exception) {
        Log.e(TAG, "ringPhone failed", e)
        false
    }

    private fun stopRinging(): Boolean = try {
        ringtone?.stop()
        ringtone = null
        Log.i(TAG, "stopRinging")
        true
    } catch (e: Exception) {
        Log.e(TAG, "stopRinging failed", e)
        false
    }

    private fun has(ctx: Context, perm: String): Boolean =
        ContextCompat.checkSelfPermission(ctx, perm) == PackageManager.PERMISSION_GRANTED

    /**
     * `TelecomManager.endCall()` is the supported way since API 28 and needs
     * ANSWER_PHONE_CALLS. It ends a ringing call (declines it) or an active
     * one (hangs up). Returns false when the permission is missing or there
     * was no call to end.
     */
    @Suppress("DEPRECATION")
    private fun endCall(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            Log.w(TAG, "endCall unsupported below API 28")
            return false
        }
        if (!has(ctx, Manifest.permission.ANSWER_PHONE_CALLS)) {
            Log.w(TAG, "endCall: ANSWER_PHONE_CALLS not granted")
            return false
        }
        return try {
            val tm = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val ended = tm.endCall()
            Log.i(TAG, "endCall -> $ended")
            ended
        } catch (e: SecurityException) {
            Log.w(TAG, "endCall denied", e)
            false
        } catch (e: Exception) {
            Log.e(TAG, "endCall failed", e)
            false
        }
    }

    /**
     * Silences the ringer for the current incoming call.
     *
     * `TelecomManager.silenceRinger()` (API 21+, needs MODIFY_PHONE_STATE which
     * third-party apps cannot hold) is tried first because it is scoped to the
     * call; the fallback mutes STREAM_RING, which OEM dialers honour and which
     * the user's next volume press restores.
     */
    private fun silenceRinger(ctx: Context): Boolean {
        try {
            val tm = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.silenceRinger()
            Log.i(TAG, "silenceRinger via TelecomManager")
            return true
        } catch (e: SecurityException) {
            // expected for third-party apps — fall through
        } catch (e: Exception) {
            Log.w(TAG, "TelecomManager.silenceRinger failed", e)
        }
        return try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.adjustStreamVolume(
                AudioManager.STREAM_RING,
                AudioManager.ADJUST_MUTE,
                0,
            )
            Log.i(TAG, "silenceRinger via STREAM_RING mute")
            true
        } catch (e: Exception) {
            Log.e(TAG, "silenceRinger failed", e)
            false
        }
    }

    private fun sendSms(ctx: Context, number: String, text: String): Boolean {
        if (!has(ctx, Manifest.permission.SEND_SMS)) {
            Log.w(TAG, "sendSms: SEND_SMS not granted")
            return false
        }
        return try {
            val sms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                ctx.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
            val parts = sms.divideMessage(text)
            if (parts.size == 1) {
                sms.sendTextMessage(number, null, text, null, null)
            } else {
                sms.sendMultipartTextMessage(number, null, parts, null, null)
            }
            Log.i(TAG, "sendSms -> ${number.take(4)}… (${text.length} chars)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "sendSms failed", e)
            false
        }
    }
}
