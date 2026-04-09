package com.example.demo_ai_even.notifications

import android.app.Notification
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationManagerCompat
import com.example.demo_ai_even.bluetooth.BleChannelHelper
import java.util.Locale

class RecentNotificationsListenerService : NotificationListenerService() {
    companion object {
        @Volatile
        private var currentInstance: RecentNotificationsListenerService? = null

        fun isAccessEnabled(context: Context): Boolean {
            return NotificationManagerCompat
                .getEnabledListenerPackages(context)
                .contains(context.packageName)
        }

        fun openSettings(context: Context) {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        }

        fun dismissNotificationByKey(key: String): Boolean {
            val instance = currentInstance ?: return false
            return runCatching {
                instance.cancelNotification(key)
                NotificationFeedStore.remove(key)
                true
            }.getOrDefault(false)
        }
    }

    override fun onCreate() {
        super.onCreate()
        currentInstance = this
    }

    override fun onDestroy() {
        if (currentInstance === this) {
            currentInstance = null
        }
        super.onDestroy()
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        val entries = activeNotifications
            ?.mapNotNull { sbn -> sbn.toDashboardNotification() }
            .orEmpty()
        NotificationFeedStore.replaceAll(entries)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        sbn.toDashboardNotification()?.let {
            NotificationFeedStore.upsertEntry(it)
            BleChannelHelper.notificationEvent(
                mapOf(
                    "type" to "posted",
                    "key" to it.key,
                    "packageName" to it.packageName,
                    "source" to it.source,
                    "message" to it.message,
                    "postedAt" to it.postedAt,
                )
            )
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        NotificationFeedStore.remove(sbn.key)
        BleChannelHelper.notificationEvent(
            mapOf(
                "type" to "removed",
                "key" to sbn.key,
                "packageName" to sbn.packageName,
            )
        )
    }

    private fun StatusBarNotification.toDashboardNotification(): DashboardNotificationEntry? {
        val extras = notification.extras ?: return null
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim().orEmpty()
        val appLabel = resolveAppLabel(packageName)

        val source = appLabel.ifBlank {
            if (title.isNotBlank()) title else packageName.substringAfterLast('.')
        }

        if (shouldIgnoreNotification(packageName, source, title, text, bigText)) {
            return null
        }

        val message = when {
            text.isNotBlank() && title.isNotBlank() && title != source -> "$title: $text"
            bigText.isNotBlank() && title.isNotBlank() && title != source -> "$title: $bigText"
            text.isNotBlank() -> text
            bigText.isNotBlank() -> bigText
            title.isNotBlank() && title != source -> title
            else -> "Open your phone for details"
        }

        if (source.isBlank() && message.isBlank()) {
            return null
        }

        return DashboardNotificationEntry(
            key = key,
            packageName = packageName,
            source = source.ifBlank { "Notification" },
            message = message,
            postedAt = postTime,
        )
    }

    private fun shouldIgnoreNotification(
        packageName: String,
        source: String,
        title: String,
        text: String,
        bigText: String,
    ): Boolean {
        val normalizedPackage = packageName.lowercase(Locale.ROOT)
        val normalizedSource = source.lowercase(Locale.ROOT)
        val combined = listOf(title, text, bigText)
            .joinToString(" ")
            .lowercase(Locale.ROOT)

        if (normalizedPackage == "com.android.systemui" || normalizedSource == "system ui") {
            return true
        }

        if ("charging" in combined || "battery" in combined) {
            return true
        }

        return false
    }

    private fun resolveAppLabel(packageName: String): String {
        return runCatching {
            val appInfo = packageManager.getApplicationInfo(packageName, PackageManager.GET_META_DATA)
            packageManager.getApplicationLabel(appInfo).toString().trim()
        }.getOrDefault("")
    }
}
