package com.eddie.evencompanion.wear

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataItem
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Watch end of the Data Layer link to the phone's WatchBridge.kt. Paths and
 * payloads are documented there. Live only while the activity is started.
 */
class PhoneLink(context: Context) :
    DataClient.OnDataChangedListener,
    MessageClient.OnMessageReceivedListener {

    companion object {
        private const val TAG = "EvenRemote"
        private const val CAPABILITY_PHONE = "evencompanion_phone"
        private const val PATH_COMMAND = "/evencompanion/command"
        private const val PATH_STATE_REQUEST = "/evencompanion/state/request"
        private const val PATH_ACK = "/evencompanion/ack"
        private const val PATH_STATE = "/evencompanion/state"

        /** ask.stop waits for transcription on the phone, so allow for it. */
        private const val ACK_TIMEOUT_MS = 15_000L
    }

    private val dataClient = Wearable.getDataClient(context)
    private val messageClient = Wearable.getMessageClient(context)
    private val capabilityClient = Wearable.getCapabilityClient(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val seq = AtomicLong(System.currentTimeMillis())
    private val pending = ConcurrentHashMap<Long, CompletableDeferred<Ack>>()

    private val _state = MutableStateFlow<PhoneState?>(null)
    val state: StateFlow<PhoneState?> = _state

    private val _phoneReachable = MutableStateFlow<Boolean?>(null)
    val phoneReachable: StateFlow<Boolean?> = _phoneReachable

    fun start() {
        dataClient.addListener(this)
        messageClient.addListener(this)
        scope.launch {
            loadCachedState()
            findPhone()?.let { node -> send(node, PATH_STATE_REQUEST, "{}") }
        }
    }

    fun stop() {
        dataClient.removeListener(this)
        messageClient.removeListener(this)
        pending.values.forEach { it.complete(Ack(false, "Cancelled")) }
        pending.clear()
    }

    fun close() {
        stop()
        scope.cancel()
    }

    suspend fun command(cmd: String, vararg args: Pair<String, String>): Ack {
        val node = findPhone() ?: return Ack(false, "Phone not reachable")
        val id = seq.incrementAndGet()
        val payload = JSONObject().put("seq", id).put("cmd", cmd)
        args.forEach { (k, v) -> payload.put(k, v) }
        val deferred = CompletableDeferred<Ack>()
        pending[id] = deferred
        if (!send(node, PATH_COMMAND, payload.toString())) {
            pending.remove(id)
            return Ack(false, "Send failed")
        }
        val ack = withTimeoutOrNull(ACK_TIMEOUT_MS) { deferred.await() }
        pending.remove(id)
        return ack ?: Ack(false, "No reply from phone")
    }

    private suspend fun findPhone(): String? =
        try {
            val nodes = capabilityClient
                .getCapability(CAPABILITY_PHONE, CapabilityClient.FILTER_REACHABLE)
                .await()
                .nodes
            val node = nodes.firstOrNull { it.isNearby } ?: nodes.firstOrNull()
            _phoneReachable.value = node != null
            node?.id
        } catch (e: Exception) {
            Log.w(TAG, "capability query failed", e)
            _phoneReachable.value = false
            null
        }

    private suspend fun send(node: String, path: String, json: String): Boolean =
        try {
            messageClient.sendMessage(node, path, json.toByteArray(StandardCharsets.UTF_8)).await()
            true
        } catch (e: Exception) {
            Log.w(TAG, "send $path failed", e)
            false
        }

    private suspend fun loadCachedState() {
        try {
            val items = dataClient.dataItems.await()
            try {
                items.filter { it.uri.path == PATH_STATE }.forEach { applyItem(it) }
            } finally {
                items.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "state load failed", e)
        }
    }

    private fun applyItem(item: DataItem) {
        val map = DataMapItem.fromDataItem(item).dataMap
        val json = map.getString("json") ?: return
        val parsed = PhoneState.parse(json, map.getLong("updatedAt")) ?: return
        val current = _state.value
        if (current == null || parsed.updatedAt >= current.updatedAt) {
            _state.value = parsed
        }
    }

    override fun onDataChanged(events: DataEventBuffer) {
        events.filter { it.type == DataEvent.TYPE_CHANGED && it.dataItem.uri.path == PATH_STATE }
            .forEach { applyItem(it.dataItem) }
    }

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != PATH_ACK) return
        try {
            val o = JSONObject(String(event.data, StandardCharsets.UTF_8))
            val ack = Ack(o.optBoolean("ok"), o.optString("message"))
            pending.remove(o.optLong("seq"))?.complete(ack)
        } catch (e: Exception) {
            Log.w(TAG, "bad ack", e)
        }
    }
}
