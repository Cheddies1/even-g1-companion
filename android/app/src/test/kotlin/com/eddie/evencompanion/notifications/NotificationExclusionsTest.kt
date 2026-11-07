package com.eddie.evencompanion.notifications

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationExclusionsTest {
    @Test
    fun messagingAppMentioningBatteryIsKept() {
        assertFalse(NotificationExclusions.isExcluded("com.whatsapp", "WhatsApp"))
    }

    @Test
    fun systemBatteryAndChargingPostersAreExcluded() {
        assertTrue(NotificationExclusions.isExcluded("com.android.systemui", "System UI"))
        assertTrue(NotificationExclusions.isExcluded("android", "Android System"))
        assertTrue(NotificationExclusions.isExcluded("com.samsung.android.lool", "Device care"))
    }

    @Test
    fun systemUiLabelIsExcludedWhateverThePackage() {
        assertTrue(NotificationExclusions.isExcluded("com.example.wrapper", "System UI"))
    }
}
