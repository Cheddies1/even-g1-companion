package com.eddie.evencompanion.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.eddie.evencompanion.MainActivity
import com.eddie.evencompanion.R
import com.eddie.evencompanion.bluetooth.BleChannelHelper

/**
 * Holds the microphone foreground-service role for the duration of a
 * phone-mic recording.
 *
 * This service does not record anything itself - [PhoneCaptureRecorder] owns
 * the AudioRecord and the PCM file. The service exists purely so Android
 * keeps the mic live once the app is backgrounded or the screen locks. On
 * Android 14+ a process without a `microphone`-typed foreground service is
 * fed silence rather than an error, so without this a locked-screen
 * recording would save a silent WAV and report success.
 *
 * Deliberately separate from [CompanionForegroundService]: that one is typed
 * `specialUse` and runs for the whole app lifetime, so folding the mic type
 * into it would hold a mic grant permanently and require combining service
 * types. This one starts on record and stops on save.
 *
 * The notification carries a Stop action. Tapping it routes back into Dart
 * (`phoneCaptureStopRequested`) rather than stopping the recorder here, so
 * the save, the recordings-list refresh and the glasses HUD teardown all run
 * through the single Dart code path that the in-app button uses.
 */
class PhoneCaptureService : Service() {

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_CAPTURE) {
            forwardStopRequestToFlutter()
            // Do not stop the service here. Dart calls stopPhoneCapture, which
            // calls stop(context) once the WAV is written. Tearing down now
            // would drop the mic grant mid-save.
            return START_NOT_STICKY
        }

        val startedAtMs = intent?.getLongExtra(EXTRA_STARTED_AT_MS, 0L)
            ?.takeIf { it > 0L }
            ?: System.currentTimeMillis()
        startForegroundCompat(buildNotification(startedAtMs))

        // START_NOT_STICKY on purpose. A recording cannot survive process
        // death - the AudioRecord and the PCM stream are gone - so an
        // automatic restart would put up a "Recording" notification with no
        // recording behind it.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(startedAtMs: Long): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            pendingFlags(PendingIntent.FLAG_UPDATE_CURRENT),
        )

        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, PhoneCaptureService::class.java).apply {
                action = ACTION_STOP_CAPTURE
            },
            pendingFlags(PendingIntent.FLAG_UPDATE_CURRENT),
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Recording - phone mic")
            // Android renders and advances the elapsed timer itself from
            // setWhen + setUsesChronometer. The alternative - re-posting the
            // notification once a second from Dart - would put a method-channel
            // round trip and a notification rebuild on every tick for the whole
            // length of a recording, to display the same thing.
            .setWhen(startedAtMs)
            .setUsesChronometer(true)
            .setShowWhen(true)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .addAction(0, "Stop and save", stopIntent)
            .build()
    }

    private fun pendingFlags(baseFlags: Int): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            baseFlags or PendingIntent.FLAG_IMMUTABLE
        } else {
            baseFlags
        }
    }

    private fun forwardStopRequestToFlutter() {
        try {
            BleChannelHelper.bleMC.flutterPhoneCaptureStopRequested()
        } catch (e: Exception) {
            android.util.Log.w("PhoneCapture", "Failed to forward stop request", e)
            // The engine is gone, so no Dart handler will run. Save natively
            // rather than cancelling - the user asked to stop and save, and
            // the audio on disk is the whole point. The recordings list
            // reads MediaStore directly, so the file appears on next launch
            // with no Dart-side bookkeeping needed.
            val outcome = runCatching { PhoneCaptureRecorder.stopAndSave() }
            android.util.Log.i(
                "PhoneCapture",
                "Engine gone - saved natively: ${outcome.getOrNull()?.get("success")}",
            )
            stop(this)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Phone recording",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Active phone-microphone recording"
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "even_companion_phone_capture"
        private const val ACTION_STOP_CAPTURE = "com.eddie.evencompanion.action.STOP_PHONE_CAPTURE"
        private const val EXTRA_STARTED_AT_MS = "startedAtMs"

        // Distinct from CompanionForegroundService's 4102 so the two
        // notifications coexist rather than replacing each other.
        private const val NOTIFICATION_ID = 4103

        /**
         * Starts the service and puts up the recording notification. Call
         * before [PhoneCaptureRecorder.start] so the mic grant is already
         * held when AudioRecord opens.
         *
         * [startedAtMs] seeds the notification's chronometer. Pass the same
         * instant the Dart side uses for its own timer so the two agree.
         */
        fun start(context: Context, startedAtMs: Long = 0L) {
            val intent = Intent(context, PhoneCaptureService::class.java).apply {
                putExtra(EXTRA_STARTED_AT_MS, startedAtMs)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        /** Drops the mic grant and removes the notification. */
        fun stop(context: Context) {
            runCatching {
                context.stopService(Intent(context, PhoneCaptureService::class.java))
            }.onFailure {
                android.util.Log.w("PhoneCapture", "stop failed", it)
            }
        }
    }
}
