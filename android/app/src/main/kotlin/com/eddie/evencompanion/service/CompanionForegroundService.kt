package com.eddie.evencompanion.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.eddie.evencompanion.MainActivity
import com.eddie.evencompanion.R
import com.eddie.evencompanion.bluetooth.BleChannelHelper

class CompanionForegroundService : Service() {

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action

        // Without a live engine there is no BLE and no companion — showing the
        // "active in background" notification would be a lie. Covers explicit
        // engine-stopped signals, START_STICKY restarts after process death
        // (intent == null, fresh process, engineAlive == false), and mode-button
        // taps on a stale notification.
        if (action == ACTION_ENGINE_STOPPED || !BleChannelHelper.engineAlive) {
            showStoppedState()
            return START_NOT_STICKY
        }

        if (action == ACTION_SET_MODE) {
            val requestedMode = intent.getStringExtra(EXTRA_MODE_LABEL) ?: "Glance"
            forwardModeSwitchToFlutter(requestedMode)
            startForeground(NOTIFICATION_ID, buildNotification(requestedMode))
            return START_STICKY
        }

        val modeLabel = intent?.getStringExtra(EXTRA_MODE_LABEL) ?: "Glance"
        startForeground(NOTIFICATION_ID, buildNotification(modeLabel))
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swipe-from-recents destroys the activity and engine but leaves this
        // service running — the reliable hook for that is here, not onDestroy.
        BleChannelHelper.engineStopped()
        showStoppedState()
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Swaps the notification to an honest stopped state, leaves the foreground
     * role so the notification becomes dismissible, and stops the service.
     * Tapping the stopped notification relaunches MainActivity; the normal
     * startCompanionService call during CompanionController.init replaces it
     * with the active notification again.
     */
    private fun showStoppedState() {
        val stopped = buildStoppedNotification()
        // Guarantee the foreground contract is met even if we were started cold
        // via startForegroundService, then detach so the notification outlives us.
        startForeground(NOTIFICATION_ID, stopped)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
        runCatching {
            // Re-post so the surviving notification carries the dismissible flags.
            NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, stopped)
        }
        stopSelf()
    }

    private fun buildStoppedNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            pendingFlags(PendingIntent.FLAG_UPDATE_CURRENT),
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Even Companion stopped")
            .setContentText("Tap to resume")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(false)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun buildNotification(modeLabel: String): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            pendingFlags(PendingIntent.FLAG_UPDATE_CURRENT),
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Even Companion - $modeLabel")
            .setContentText("Companion mode active in background")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)

        listOf("Glance", "Navigate", "Chat", "Capture")
            .filter { it != modeLabel }
            .forEachIndexed { index, label ->
                builder.addAction(
                    0,
                    label,
                    buildModeActionPendingIntent(label, index + 1),
                )
            }

        return builder.build()
    }

    private fun buildModeActionPendingIntent(modeLabel: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, CompanionForegroundService::class.java).apply {
            action = ACTION_SET_MODE
            putExtra(EXTRA_MODE_LABEL, modeLabel)
        }
        return PendingIntent.getService(
            this,
            requestCode,
            intent,
            pendingFlags(PendingIntent.FLAG_UPDATE_CURRENT),
        )
    }

    private fun pendingFlags(baseFlags: Int): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            baseFlags or PendingIntent.FLAG_IMMUTABLE
        } else {
            baseFlags
        }
    }

    private fun forwardModeSwitchToFlutter(modeLabel: String) {
        try {
            BleChannelHelper.bleMC.flutterCompanionModeSwitchRequested(modeLabel)
        } catch (e: Exception) {
            android.util.Log.w("CompanionForeground", "Failed to forward mode switch: $modeLabel", e)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Even Companion",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Persistent companion app status"
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "even_companion_mode"
        private const val ACTION_SET_MODE = "com.eddie.evencompanion.action.SET_MODE"
        private const val ACTION_ENGINE_STOPPED = "com.eddie.evencompanion.action.ENGINE_STOPPED"
        private const val EXTRA_MODE_LABEL = "modeLabel"
        private const val NOTIFICATION_ID = 4102

        fun start(context: Context, modeLabel: String) {
            val intent = Intent(context, CompanionForegroundService::class.java).apply {
                putExtra(EXTRA_MODE_LABEL, modeLabel)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun updateMode(context: Context, modeLabel: String) {
            start(context, modeLabel)
        }

        /**
         * Tells a running service the engine is gone so it can swap to the
         * stopped-state notification. Secondary path — the primary swipe-kill
         * hook is [onTaskRemoved]; this covers an activity finishing without
         * task removal. Best-effort: if the service isn't running (or the
         * start is rejected), the engineAlive gate in onStartCommand still
         * prevents a false "active" state on the next start.
         */
        fun notifyEngineStopped(context: Context) {
            runCatching {
                context.startService(
                    Intent(context, CompanionForegroundService::class.java).apply {
                        action = ACTION_ENGINE_STOPPED
                    }
                )
            }.onFailure {
                android.util.Log.w("CompanionForeground", "notifyEngineStopped failed", it)
            }
        }
    }
}
