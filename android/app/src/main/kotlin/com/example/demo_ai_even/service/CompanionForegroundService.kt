package com.example.demo_ai_even.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.example.demo_ai_even.R

class CompanionForegroundService : Service() {

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val modeLabel = intent?.getStringExtra(EXTRA_MODE_LABEL) ?: "Glance"
        startForeground(NOTIFICATION_ID, buildNotification(modeLabel))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(modeLabel: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Even Companion - $modeLabel")
            .setContentText("Companion mode active in background")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
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
