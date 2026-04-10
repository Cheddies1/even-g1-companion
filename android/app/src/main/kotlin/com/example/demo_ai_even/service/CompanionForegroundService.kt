package com.example.demo_ai_even.service

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
import androidx.core.content.ContextCompat
import com.example.demo_ai_even.MainActivity
import com.example.demo_ai_even.R
import com.example.demo_ai_even.bluetooth.BleChannelHelper

class CompanionForegroundService : Service() {

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
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

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(modeLabel: String): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            pendingFlags(PendingIntent.FLAG_UPDATE_CURRENT),
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Even Companion - $modeLabel")
            .setContentText("Companion mode active in background")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .addAction(0, "Glance", buildModeActionPendingIntent("Glance", 1))
            .addAction(0, "Capture", buildModeActionPendingIntent("Capture", 2))
            .addAction(0, "Navigate", buildModeActionPendingIntent("Navigate", 3))
            .addAction(0, "Chat", buildModeActionPendingIntent("Chat", 4))
            .build()
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
        private const val ACTION_SET_MODE = "com.example.demo_ai_even.action.SET_MODE"
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
    }
}
