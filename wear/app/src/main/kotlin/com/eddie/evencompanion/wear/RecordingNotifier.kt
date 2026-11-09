package com.eddie.evencompanion.wear

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status

/**
 * Puts the recording timer on the watch face while the phone records from
 * either mic: an ongoing notification with an [OngoingActivity] attached, so
 * the system shows the icon and a live stopwatch on the watch face and in the
 * recents list. Driven from the mirrored phone state, so it appears whether
 * the recording started from the watch, the glasses or the phone.
 */
object RecordingNotifier {
    private const val CHANNEL_ID = "recording"
    private const val NOTIFICATION_ID = 1

    /** Recording start already shown, so frequent state publishes do not re-post. */
    @Volatile
    private var shownStartedAt: Long? = null

    fun update(context: Context, state: PhoneState?) {
        val startedAt = state?.recordingStartedAt
        if (state == null || !state.recording || startedAt == null) {
            if (shownStartedAt != null) {
                manager(context).cancel(NOTIFICATION_ID)
                shownStartedAt = null
            }
            return
        }
        if (shownStartedAt == startedAt) return
        post(context, startedAt, sourceLabel(state.recordingSource))
        shownStartedAt = startedAt
    }

    fun sourceLabel(source: String?): String =
        if (source == "glasses") "Glasses mic" else "Phone mic"

    private fun post(context: Context, startedAtWallMs: Long, source: String) {
        val nm = manager(context)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Recording", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { setSound(null, null) }
        )
        val openApp = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getBroadcast(
            context, 0,
            Intent(context, StopRecordingReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle("Recording")
            .setContentText(source)
            .setCategory(NotificationCompat.CATEGORY_STOPWATCH)
            .setOngoing(true)
            .setSilent(true)
            .setUsesChronometer(true)
            .setWhen(startedAtWallMs)
            .setContentIntent(openApp)
            .addAction(R.drawable.ic_mic, "Stop", stop)

        // The stopwatch part counts from an elapsedRealtime origin; convert
        // the phone's wall-clock start (phone and watch clocks are synced).
        val elapsedStart = SystemClock.elapsedRealtime() -
            (System.currentTimeMillis() - startedAtWallMs).coerceAtLeast(0)
        val status = Status.Builder()
            .addTemplate("#source# #time#")
            .addPart("source", Status.TextPart(source))
            .addPart("time", Status.StopwatchPart(elapsedStart))
            .build()
        OngoingActivity.Builder(context, NOTIFICATION_ID, builder)
            .setStaticIcon(R.drawable.ic_mic)
            .setTouchIntent(openApp)
            .setStatus(status)
            .build()
            .apply(context)

        try {
            nm.notify(NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted yet; MainActivity asks for it.
        }
    }

    private fun manager(context: Context) =
        context.getSystemService(NotificationManager::class.java)
}
