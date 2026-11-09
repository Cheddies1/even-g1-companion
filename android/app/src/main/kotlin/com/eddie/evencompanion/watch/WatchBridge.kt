package com.eddie.evencompanion.watch

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.eddie.evencompanion.bluetooth.BleChannelHelper
import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

/**
 * Phone side of the Galaxy Watch remote (docs/plans/watch-remote-spike.md).
 *
 * Inbound: [WatchListenerService] hands every Data Layer message under
 * [PATH_PREFIX] to [handleMessage]. Commands go to Dart over [METHOD_CHANNEL];
 * Dart's reply becomes the ack to the sending watch node. Commands are never
 * queued: with no live engine the watch gets an immediate failure ack, so a
 * stale command can never fire later on whatever the glasses show by then.
 *
 * Outbound: Dart calls `publishState` with the state JSON, mirrored into one
 * urgent Data Layer item at [PATH_STATE].
 *
 * Wire format (JSON, UTF-8):
 *   watch -> phone  /evencompanion/command        {seq, cmd, ...args}
 *   watch -> phone  /evencompanion/state/request  {}
 *   phone -> watch  /evencompanion/ack            {seq, ok, engineAlive, message}
 *   phone -> watch  /evencompanion/state          DataItem {json, updatedAt}
 */
object WatchBridge {
    const val TAG = "G1Watch"
    const val METHOD_CHANNEL = "method.watch"

    /** Advertised by the watch app; the phone advertises evencompanion_phone (res/values/wear.xml). */
    const val CAPABILITY_WATCH = "evencompanion_watch"

    const val PATH_PREFIX = "/evencompanion"
    const val PATH_COMMAND = "/evencompanion/command"
    const val PATH_STATE_REQUEST = "/evencompanion/state/request"
    const val PATH_ACK = "/evencompanion/ack"
    const val PATH_STATE = "/evencompanion/state"

    private const val ACTION_DEBUG = "com.eddie.evencompanion.WATCH_CMD"
    private const val ENGINE_DOWN_MESSAGE = "Open Even Companion on the phone"

    private val main = Handler(Looper.getMainLooper())
    private val publishExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "WatchStatePublish").apply { isDaemon = true }
    }
    private val lock = Any()

    @Volatile
    private var appContext: Context? = null
    private var channel: MethodChannel? = null // main thread only
    private var lastPublished: String? = null // guarded by lock
    private var queuedState: String? = null // guarded by lock
    private var debugRegistered = false

    fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        val ch = MethodChannel(messenger, METHOD_CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "publishState" -> {
                    publishState(call.argument<String>("json"), call.argument<Boolean>("force") == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        main.post { channel = ch }
    }

    /** Entry point for [WatchListenerService] and the debug receiver; any thread. */
    fun handleMessage(context: Context, path: String?, data: ByteArray?, nodeId: String?) {
        if (path == null || !path.startsWith(PATH_PREFIX)) return
        if (appContext == null) appContext = context.applicationContext
        val json = if (data != null && data.isNotEmpty()) String(data, StandardCharsets.UTF_8) else "{}"
        val seq = readSeq(json)
        Log.i(TAG, "recv $path seq=$seq from=${nodeId ?: "debug"}")
        main.post {
            val ch = channel
            if (ch == null || !BleChannelHelper.engineAlive) {
                if (path == PATH_COMMAND) sendAck(nodeId, seq, false, false, ENGINE_DOWN_MESSAGE)
                return@post
            }
            when (path) {
                PATH_STATE_REQUEST -> ch.invokeMethod("stateRequest", null)
                PATH_COMMAND -> ch.invokeMethod("command", json, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val map = result as? Map<*, *>
                        sendAck(nodeId, seq, map?.get("ok") == true, true, map?.get("message") as? String)
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        sendAck(nodeId, seq, false, true, message ?: code)
                    }

                    override fun notImplemented() {
                        sendAck(nodeId, seq, false, true, "Phone app does not handle watch commands")
                    }
                })
                else -> Log.w(TAG, "unknown path $path")
            }
        }
    }

    /** A watch running our app appeared or went away: push fresh state to it. */
    fun handleCapabilityChanged(info: CapabilityInfo?) {
        if (info == null || info.name != CAPABILITY_WATCH) return
        val names = info.nodes.joinToString { it.displayName }
        Log.i(TAG, "watch capability changed: reachable=[$names]")
        main.post { channel?.invokeMethod("watchConnection", mapOf("reachable" to info.nodes.isNotEmpty())) }
    }

    private fun sendAck(nodeId: String?, seq: Long, ok: Boolean, engineAlive: Boolean, message: String?) {
        val ack = JSONObject()
            .put("seq", seq)
            .put("ok", ok)
            .put("engineAlive", engineAlive)
            .put("message", message ?: "")
            .toString()
        if (nodeId.isNullOrEmpty()) {
            Log.i(TAG, "ack (debug) $ack")
            return
        }
        val ctx = appContext ?: return
        try {
            Wearable.getMessageClient(ctx)
                .sendMessage(nodeId, PATH_ACK, ack.toByteArray(StandardCharsets.UTF_8))
                .addOnFailureListener { e -> Log.w(TAG, "ack to $nodeId failed", e) }
        } catch (e: Throwable) {
            Log.w(TAG, "ack failed", e)
        }
    }

    /**
     * Unchanged states are skipped unless [force]; states arriving while one
     * is still queued replace it, since only the latest matters to the watch.
     */
    private fun publishState(json: String?, force: Boolean) {
        if (json == null) return
        synchronized(lock) {
            if (!force && json == lastPublished) return
            lastPublished = json
            val alreadyQueued = queuedState != null
            queuedState = json
            if (alreadyQueued) return
        }
        publishExecutor.execute { publishQueued() }
    }

    private fun publishQueued() {
        val json: String
        synchronized(lock) {
            json = queuedState ?: return
            queuedState = null
        }
        val ctx = appContext ?: return
        Log.d(TAG, "state $json")
        try {
            val request = PutDataMapRequest.create(PATH_STATE)
            request.dataMap.putString("json", json)
            request.dataMap.putLong("updatedAt", System.currentTimeMillis())
            Wearable.getDataClient(ctx)
                .putDataItem(request.asPutDataRequest().setUrgent())
                .addOnFailureListener { e -> Log.w(TAG, "state publish failed", e) }
        } catch (e: Throwable) {
            Log.w(TAG, "state publish failed", e)
        }
    }

    private fun readSeq(json: String): Long =
        try {
            JSONObject(json).optLong("seq", 0)
        } catch (e: Exception) {
            0
        }

    /**
     * Debuggable builds only. Injects a command through the same path as a
     * real watch message; the ack is logged instead of sent:
     *   adb shell am broadcast -p com.eddie.evencompanion -a com.eddie.evencompanion.WATCH_CMD \
     *     --es cmd mode.set --es mode capture
     *   ... --es cmd state.request
     * Logs: adb logcat -s G1Watch (and Flutter [Watch] lines).
     */
    fun registerDebugReceiver(activity: Activity) {
        val debuggable = (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable || debugRegistered) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val cmd = intent.getStringExtra("cmd") ?: return
                if (cmd == "state.request") {
                    handleMessage(context, PATH_STATE_REQUEST, null, null)
                    return
                }
                val payload = JSONObject().put("seq", 0).put("cmd", cmd)
                intent.getStringExtra("mode")?.let { payload.put("mode", it) }
                handleMessage(context, PATH_COMMAND, payload.toString().toByteArray(StandardCharsets.UTF_8), null)
            }
        }
        val filter = IntentFilter(ACTION_DEBUG)
        val ctx = activity.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            ctx.registerReceiver(receiver, filter)
        }
        debugRegistered = true
        Log.i(TAG, "WATCH_CMD debug receiver registered")
    }
}
