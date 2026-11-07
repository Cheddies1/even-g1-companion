package com.eddie.evencompanion.notifications

import java.util.Locale

/**
 * Which notifications never reach the app. Decided by package, never by text:
 * a text match on "battery"/"charging" dropped real messages that mentioned
 * either word.
 *
 * Packages are the system and device-care posters on the S24 Ultra (One UI):
 * charging and low-battery cards come from System UI, USB charging and other
 * OS chrome from `android`, battery protection and device-care cards from
 * Samsung Device Care (`lool`) and its security companion.
 */
object NotificationExclusions {
    val excludedPackages: Set<String> = setOf(
        "android",
        "com.android.systemui",
        "com.samsung.android.lool",
        "com.samsung.android.sm.devicesecurity",
    )

    fun isExcluded(packageName: String, source: String): Boolean {
        val pkg = packageName.trim().lowercase(Locale.ROOT)
        return pkg in excludedPackages || source.trim().lowercase(Locale.ROOT) == "system ui"
    }
}
