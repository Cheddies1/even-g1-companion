package com.eddie.evencompanion.wear

import org.json.JSONObject

/**
 * The phone's mirrored state (lib/services/watch/watch_protocol.dart,
 * WatchState.toJson). Missing fields fall back to safe defaults so a newer
 * or older phone build never crashes the watch.
 */
data class PhoneState(
    val connected: Boolean,
    val mode: String,
    val status: String,
    val recording: Boolean,
    val recordingStartedAt: Long?,
    val glanceVisible: Boolean,
    val glanceIndex: Int,
    val glanceCount: Int,
    val glanceTitle: String,
    val glanceApp: String,
    val assistantListening: Boolean,
    val assistantThinking: Boolean,
    val walkActive: Boolean,
    val glassesBattery: Int?,
    val caseBattery: Int?,
    /** Phone wall clock at publish, from the DataItem. */
    val updatedAt: Long,
) {
    companion object {
        fun parse(json: String, updatedAt: Long): PhoneState? =
            try {
                val o = JSONObject(json)
                val glance = o.optJSONObject("glance") ?: JSONObject()
                val assistant = o.optJSONObject("assistant") ?: JSONObject()
                val battery = o.optJSONObject("battery") ?: JSONObject()
                PhoneState(
                    connected = o.optBoolean("connected"),
                    mode = o.optString("mode", "glance"),
                    status = o.optString("status"),
                    recording = o.optBoolean("recording"),
                    recordingStartedAt = o.optLongOrNull("recordingStartedAt"),
                    glanceVisible = glance.optBoolean("visible"),
                    glanceIndex = glance.optInt("index"),
                    glanceCount = glance.optInt("count"),
                    glanceTitle = glance.optString("title"),
                    glanceApp = glance.optString("app"),
                    assistantListening = assistant.optBoolean("listening"),
                    assistantThinking = assistant.optBoolean("thinking"),
                    walkActive = o.optBoolean("walkActive"),
                    glassesBattery = battery.optLongOrNull("glasses")?.toInt(),
                    caseBattery = battery.optLongOrNull("case")?.toInt(),
                    updatedAt = updatedAt,
                )
            } catch (e: Exception) {
                null
            }

        private fun JSONObject.optLongOrNull(key: String): Long? =
            if (isNull(key)) null else optLong(key)
    }
}

/** The phone's reply to one command. */
data class Ack(val ok: Boolean, val message: String)
