package com.eddie.evencompanion.watch

import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService

/**
 * Play services starts this for every Data Layer message under /evencompanion
 * and for capability changes, whether or not the app is in front. It only
 * forwards to [WatchBridge].
 */
class WatchListenerService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        WatchBridge.handleMessage(this, event.path, event.data, event.sourceNodeId)
    }

    override fun onCapabilityChanged(info: CapabilityInfo) {
        WatchBridge.handleCapabilityChanged(info)
    }
}
