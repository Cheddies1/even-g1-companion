package com.eddie.evencompanion.wear

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.WearableListenerService

/**
 * Play services starts this for every phone state publish, even with the app
 * closed, so the watch-face timer and the tile follow recordings started
 * anywhere (watch, glasses or phone).
 */
class StateListenerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        val latest = events
            .filter { it.type == DataEvent.TYPE_CHANGED }
            .mapNotNull { PhoneLink.parseItem(it.dataItem) }
            .maxByOrNull { it.updatedAt }
            ?: return
        RecordingNotifier.update(this, latest)
        RecordTileService.refreshIfChanged(this, latest)
    }
}
