package com.eddie.evencompanion.wear

import android.content.Context
import android.text.format.DateFormat
import androidx.concurrent.futures.SuspendToFutureAdapter
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.android.gms.wearable.Wearable
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.Dispatchers
import java.util.Date

/**
 * One-swipe Record/Stop from the watch face. The phone picks the mic
 * (record.start: glasses when connected and out of the case, else phone).
 * A tap arrives as a LoadAction: onTileRequest sends the command and returns
 * the optimistic layout; the next state publish refreshes it for real.
 */
class RecordTileService : TileService() {

    companion object {
        private const val RESOURCES_VERSION = "1"
        private const val CLICK_RECORD = "record"
        private const val CLICK_OPEN = "open"

        private val RED = 0xFFE5484D.toInt()
        private val ACCENT = 0xFF6FC4B4.toInt()
        private val MUTED = 0xFF9AA5AB.toInt()

        /** Last recording/connection key drawn, so unrelated publishes skip the refresh. */
        @Volatile
        private var lastKey: String? = null

        fun refreshIfChanged(context: Context, state: PhoneState) {
            val key = keyOf(state)
            if (key == lastKey) return
            lastKey = key
            getUpdater(context).requestUpdate(RecordTileService::class.java)
        }

        private fun keyOf(state: PhoneState?) =
            "${state?.recording}|${state?.recordingSource}|${state?.recordingStartedAt}|${state?.recordTarget}"
    }

    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> =
        SuspendToFutureAdapter.launchFuture(Dispatchers.Main) {
            var state = PhoneLink.loadState(Wearable.getDataClient(this@RecordTileService))
            var note: String? = null
            if (requestParams.currentState.lastClickableId == CLICK_RECORD) {
                val stopping = state?.recording == true
                val link = PhoneLink(applicationContext)
                link.start()
                val ack = try {
                    link.command(if (stopping) "record.stop" else "record.start")
                } finally {
                    link.close()
                }
                if (ack.ok && state != null) {
                    // Optimistic until the phone's next publish lands.
                    state = state.copy(
                        recording = !stopping,
                        recordingStartedAt = if (stopping) null else System.currentTimeMillis(),
                    )
                } else if (!ack.ok) {
                    note = ack.message
                }
            }
            lastKey = keyOf(state)
            tile(layout(state, note))
        }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest,
    ): ListenableFuture<ResourceBuilders.Resources> =
        SuspendToFutureAdapter.launchFuture(Dispatchers.Main) {
            ResourceBuilders.Resources.Builder().setVersion(RESOURCES_VERSION).build()
        }

    private fun tile(root: LayoutElementBuilders.LayoutElement) =
        TileBuilders.Tile.Builder()
            .setResourcesVersion(RESOURCES_VERSION)
            .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(root))
            .build()

    private fun layout(state: PhoneState?, note: String?): LayoutElementBuilders.LayoutElement {
        val recording = state?.recording == true
        val startedAt = state?.recordingStartedAt
        val subtitle = when {
            note != null -> note
            state == null -> "Open Even Companion"
            recording && startedAt != null ->
                "${RecordingNotifier.sourceLabel(state.recordingSource)} since " +
                    DateFormat.getTimeFormat(this).format(Date(startedAt))
            else -> RecordingNotifier.sourceLabel(state.recordTarget)
        }
        val button = LayoutElementBuilders.Box.Builder()
            .setWidth(dp(84f))
            .setHeight(dp(84f))
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setBackground(
                        ModifiersBuilders.Background.Builder()
                            .setColor(argb(if (recording) 0xFF3A3A3A.toInt() else RED))
                            .setCorner(ModifiersBuilders.Corner.Builder().setRadius(dp(42f)).build())
                            .build()
                    )
                    .setClickable(
                        ModifiersBuilders.Clickable.Builder()
                            .setId(CLICK_RECORD)
                            .setOnClick(ActionBuilders.LoadAction.Builder().build())
                            .build()
                    )
                    .build()
            )
            .addContent(text(if (recording) "STOP" else "REC", 18f, if (recording) RED else 0xFFFFFFFF.toInt(), bold = true))
            .build()

        val openApp = ModifiersBuilders.Modifiers.Builder()
            .setClickable(
                ModifiersBuilders.Clickable.Builder()
                    .setId(CLICK_OPEN)
                    .setOnClick(
                        ActionBuilders.LaunchAction.Builder()
                            .setAndroidActivity(
                                ActionBuilders.AndroidActivity.Builder()
                                    .setPackageName(packageName)
                                    .setClassName(MainActivity::class.java.name)
                                    .build()
                            )
                            .build()
                    )
                    .build()
            )
            .build()

        return LayoutElementBuilders.Box.Builder()
            .setWidth(expand())
            .setHeight(expand())
            .addContent(
                LayoutElementBuilders.Column.Builder()
                    .addContent(
                        LayoutElementBuilders.Box.Builder().setModifiers(openApp)
                            .addContent(text("Even Remote", 14f, ACCENT, bold = true)).build()
                    )
                    .addContent(spacer(10f))
                    .addContent(button)
                    .addContent(spacer(8f))
                    .addContent(text(subtitle, 12f, if (note != null) RED else MUTED))
                    .build()
            )
            .build()
    }

    private fun spacer(height: Float) =
        LayoutElementBuilders.Spacer.Builder().setHeight(dp(height)).build()

    private fun text(value: String, size: Float, color: Int, bold: Boolean = false) =
        LayoutElementBuilders.Text.Builder()
            .setText(value)
            .setMaxLines(2)
            .setFontStyle(
                LayoutElementBuilders.FontStyle.Builder()
                    .setSize(androidx.wear.protolayout.DimensionBuilders.sp(size))
                    .setColor(argb(color))
                    .setWeight(
                        if (bold) LayoutElementBuilders.FONT_WEIGHT_BOLD else LayoutElementBuilders.FONT_WEIGHT_NORMAL
                    )
                    .build()
            )
            .build()
}
