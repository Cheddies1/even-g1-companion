package com.example.demo_ai_even.notifications

import android.app.Notification
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import com.example.demo_ai_even.bluetooth.BleChannelHelper
import java.io.ByteArrayOutputStream
import java.util.Locale

class RecentNotificationsListenerService : NotificationListenerService() {
    private val debugTag = "MapsNotificationDump"
    private val isMapsDebugEnabled: Boolean
        get() = Log.isLoggable(debugTag, Log.DEBUG)

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
        if (isMapsDebugEnabled) {
            activeNotifications
                ?.filter { it.packageName == "com.google.android.apps.maps" }
                ?.forEach(::logNavigationNotification)
        }
        val entries = activeNotifications
            ?.mapNotNull { sbn -> sbn.toDashboardNotification() }
            .orEmpty()
        NotificationFeedStore.replaceAll(entries)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        logNavigationNotification(sbn)
        sbn.toDashboardNotification()?.let {
            NotificationFeedStore.upsertEntry(it)
            BleChannelHelper.notificationEvent(
                mapOf(
                    "type" to "posted",
                    "key" to it.key,
                    "packageName" to it.packageName,
                    "source" to it.source,
                    "category" to it.category,
                    "channelId" to it.channelId,
                    "tag" to it.tag,
                    "isOngoing" to it.isOngoing,
                    "isMediaStyle" to it.isMediaStyle,
                    "template" to it.template,
                    "summaryText" to it.summaryText,
                    "title" to it.title,
                    "text" to it.text,
                    "bigText" to it.bigText,
                    "subText" to it.subText,
                    "message" to it.message,
                    "navPrimaryInfo" to it.navPrimaryInfo,
                    "navSecondaryInfo" to it.navSecondaryInfo,
                    "navChipExpandedText" to it.navChipExpandedText,
                    "liveScoreHint" to it.liveScoreHint,
                    "navIconPngBase64" to it.navIconPngBase64,
                    "navIconSource" to it.navIconSource,
                    "postedAt" to it.postedAt,
                )
            )
        }
    }

    private fun logNavigationNotification(sbn: StatusBarNotification) {
        if (!isMapsDebugEnabled || sbn.packageName != "com.google.android.apps.maps") {
            return
        }

        val notification = sbn.notification
        val extras = notification.extras ?: Bundle.EMPTY
        val wearableBundle = extras.getBundle("android.wearable.EXTENSIONS")
        val carBundle = extras.getBundle("android.car.EXTENSIONS")
        val actionSummaries = notification.actions
            ?.mapIndexed { index, action ->
                mapOf(
                    "index" to index,
                    "title" to action.title?.toString().orEmpty(),
                    "hasIntent" to (action.actionIntent != null),
                    "remoteInputs" to (action.remoteInputs?.size ?: 0),
                    "extrasKeys" to action.extras?.keySet()?.sorted().orEmpty(),
                    "extras" to summarizeBundle(action.extras),
                )
            }
            .orEmpty()

        val payload = linkedMapOf<String, Any?>(
            "key" to sbn.key,
            "postTime" to sbn.postTime,
            "category" to notification.category,
            "channelId" to notification.channelId,
            "title" to extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            "text" to extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            "bigText" to extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
            "subText" to extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
            "infoText" to extras.getCharSequence(Notification.EXTRA_INFO_TEXT)?.toString(),
            "summaryText" to extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)?.toString(),
            "template" to extras.getString(Notification.EXTRA_TEMPLATE),
            "hasSmallIcon" to (notification.smallIcon != null),
            "hasLargeIcon" to (notification.getLargeIcon() != null),
            "extrasKeys" to extras.keySet().sorted(),
            "extras" to summarizeBundle(extras),
            "actions" to actionSummaries,
            "wearableExtKeys" to wearableBundle?.keySet()?.sorted().orEmpty(),
            "wearableExt" to summarizeBundle(wearableBundle),
            "carExtKeys" to carBundle?.keySet()?.sorted().orEmpty(),
            "carExt" to summarizeBundle(carBundle),
        )

        Log.d(debugTag, payload.toString())
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
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim().orEmpty()
        val summaryText = extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)?.toString()?.trim().orEmpty()
        val template = extras.getString(Notification.EXTRA_TEMPLATE).orEmpty()
        val isMediaStyle = template.contains("MediaStyle") ||
            extras.get(Notification.EXTRA_MEDIA_SESSION) != null ||
            notification.category == Notification.CATEGORY_TRANSPORT
        val appLabel = resolveAppLabel(packageName)
        val navPrimaryInfo = extras.getCharSequence("android.ongoingActivityNoti.primaryInfo")
            ?.toString()
            ?.trim()
            .orEmpty()
        val navSecondaryInfo = extras.getCharSequence("android.ongoingActivityNoti.secondaryInfo")
            ?.toString()
            ?.trim()
            .orEmpty()
        val navChipExpandedText = extras.getCharSequence("android.ongoingActivityNoti.chipExpandedText")
            ?.toString()
            ?.trim()
            .orEmpty()
        val liveScoreHint = extras.getCharSequence("android.ongoingActivityNoti.secondaryInfo")
            ?.toString()
            ?.trim()
            .orEmpty()
        val (navIconPngBase64, navIconSource) = extractBestNavigationIcon(extras)

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
            category = notification.category.orEmpty(),
            channelId = notification.channelId.orEmpty(),
            tag = tag.orEmpty(),
            isOngoing = isOngoing,
            isMediaStyle = isMediaStyle,
            template = template,
            summaryText = summaryText,
            title = title,
            text = text,
            bigText = bigText,
            subText = subText,
            message = message,
            navPrimaryInfo = navPrimaryInfo,
            navSecondaryInfo = navSecondaryInfo,
            navChipExpandedText = navChipExpandedText,
            liveScoreHint = liveScoreHint,
            navIconPngBase64 = navIconPngBase64,
            navIconSource = navIconSource,
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

    private fun summarizeBundle(bundle: Bundle?): Map<String, Any?> {
        if (bundle == null) {
            return emptyMap()
        }
        return bundle.keySet()
            .sorted()
            .associateWith { key -> summarizeValue(bundle.get(key)) }
    }

    private fun summarizeValue(value: Any?): Any? {
        return when (value) {
            null -> null
            is Bundle -> summarizeBundle(value)
            is CharSequence -> value.toString()
            is Array<*> -> value.map { summarizeValue(it) }
            is IntArray -> value.toList()
            is LongArray -> value.toList()
            is FloatArray -> value.toList()
            is DoubleArray -> value.toList()
            is BooleanArray -> value.toList()
            is ByteArray -> "byte[${value.size}]"
            else -> {
                val text = value.toString()
                if (text.length > 240) "${text.take(240)}..." else text
            }
        }
    }

    private fun extractBestNavigationIcon(extras: Bundle): Pair<String, String> {
        val candidates = listOf(
            "android.ongoingActivityNoti.chipIcon",
            "android.ongoingActivityNoti.nowbarIcon",
            "android.ongoingActivityNoti.secondIcon",
        )

        for (key in candidates) {
            val icon = extras.get(key) as? Icon ?: continue
            val pngBase64 = iconToPngBase64(icon)
            if (pngBase64.isNotEmpty()) {
                return pngBase64 to key
            }
        }

        return "" to ""
    }

    private fun iconToPngBase64(icon: Icon): String {
        return runCatching {
            val drawable = icon.loadDrawable(this) ?: return ""
            val bitmap = drawableToBitmap(drawable)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
        }.getOrDefault("")
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            return drawable.bitmap
        }

        val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 126
        val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 126
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }
}
