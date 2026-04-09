package com.example.demo_ai_even.notifications

data class DashboardNotificationEntry(
    val key: String,
    val packageName: String,
    val source: String,
    val title: String,
    val text: String,
    val bigText: String,
    val message: String,
    val postedAt: Long,
)

object NotificationFeedStore {

    private const val MAX_NOTIFICATIONS = 10
    private val notifications = mutableListOf<DashboardNotificationEntry>()

    @Synchronized
    fun upsertEntry(entry: DashboardNotificationEntry) {
        notifications.removeAll { it.key == entry.key }
        notifications.add(0, entry)
        if (notifications.size > MAX_NOTIFICATIONS) {
            notifications.subList(MAX_NOTIFICATIONS, notifications.size).clear()
        }
    }

    @Synchronized
    fun remove(key: String) {
        notifications.removeAll { it.key == key }
    }

    @Synchronized
    fun replaceAll(entries: List<DashboardNotificationEntry>) {
        notifications.clear()
        notifications.addAll(entries.sortedByDescending { it.postedAt }.take(MAX_NOTIFICATIONS))
    }

    @Synchronized
    fun snapshot(): List<Map<String, Any>> {
        return notifications.map { entry ->
            mapOf(
                "key" to entry.key,
                "packageName" to entry.packageName,
                "source" to entry.source,
                "title" to entry.title,
                "text" to entry.text,
                "bigText" to entry.bigText,
                "message" to entry.message,
                "postedAt" to entry.postedAt,
            )
        }
    }
}
