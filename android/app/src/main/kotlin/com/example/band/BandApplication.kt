package com.example.band

import android.util.Log
import io.flutter.app.FlutterApplication
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Owns a process-lifetime ("warm") FlutterEngine.
 *
 * Why this exists (findings-17): notifications never reached the band in normal
 * use because [NotificationBridge]'s MethodChannel was created on
 * `MainActivity`'s own FlutterEngine. `FlutterActivity` destroys that engine
 * together with the activity, and after detach `FlutterJNI.dispatchPlatformMessage`
 * silently drops messages (it logs a warning rather than throwing). So the moment
 * the user swiped the app away — or the system bound the listener service on its
 * own after a reboot — every captured notification went nowhere, with no error
 * anywhere to explain it. That is the steady state for a band app, not an edge
 * case: the whole point is to run with no UI on screen.
 *
 * Creating the engine here instead means:
 *  - the Dart isolate (and therefore the BLE manager and the relay) exists for
 *    as long as the process does, independent of any activity;
 *  - [MainActivity] *attaches to* this engine rather than creating its own, so
 *    there is still exactly one isolate and one BLE connection;
 *  - the notification channel is registered once, on an engine that will still
 *    be alive when the system delivers a notification at 3 a.m.
 *
 * The engine starts headless. `runApp` works fine without a rendering surface;
 * the UI simply attaches later when the activity comes up.
 */
class BandApplication : FlutterApplication() {

    override fun onCreate() {
        super.onCreate()
        try {
            val engine = FlutterEngine(this)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)

            // Register the notification channel on the warm engine — NOT on the
            // activity — so it survives the activity being destroyed.
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                NotificationChannelHost.CHANNEL,
            )
            NotificationChannelHost.install(this, channel)
            NotificationBridge.attach(channel)

            // Same reasoning for call control: the band's "reject" press has
            // to hang the call up at 3 a.m. with no activity alive.
            CallControlHost.install(
                this,
                MethodChannel(engine.dartExecutor.binaryMessenger, CallControlHost.CHANNEL),
            )
            Log.i(TAG, "Warm FlutterEngine started and cached as '$ENGINE_ID'")
        } catch (e: Exception) {
            // Never take the app down over this: without the warm engine the app
            // still works while its UI is open, which is strictly better than
            // failing to start.
            Log.e(TAG, "Failed to start warm FlutterEngine", e)
        }
    }

    companion object {
        const val ENGINE_ID = "band_engine"
        private const val TAG = "BandApplication"
    }
}
