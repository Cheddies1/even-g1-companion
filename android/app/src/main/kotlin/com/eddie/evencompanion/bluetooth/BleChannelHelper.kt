package com.eddie.evencompanion.bluetooth

import android.Manifest
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.eddie.evencompanion.MainActivity
import com.eddie.evencompanion.cpp.Cpp
import com.eddie.evencompanion.notifications.RecentNotificationsListenerService
import com.eddie.evencompanion.service.CompanionForegroundService
import com.eddie.evencompanion.service.GlassesCaptureRecorder
import com.eddie.evencompanion.model.BlePairDevice
import com.eddie.evencompanion.notifications.NotificationFeedStore
import com.eddie.evencompanion.telephony.TelephonyEventService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object BleChannelHelper {

    /// METHOD TAG
    private const val METHOD_CHANNEL_BLE_TAG = "method.bluetooth"

    /// EVENT TAG
    private const val EVENT_BLE_STATUS = "eventBleStatus"
    private const val EVENT_BLE_RECEIVE = "eventBleReceive"
    private const val EVENT_BLE_SPEECH_RECOGNIZE = "eventSpeechRecognize"
    private const val EVENT_NOTIFICATIONS = "eventNotifications"
    private const val EVENT_TELEPHONY = "eventTelephony"

    /// Save EventSink
    private val eventSinks: MutableMap<String, EventSink> = mutableMapOf()
    ///
    private lateinit var bleMethodChannel: BleMethodChannel
    val bleMC: BleMethodChannel
        get() = bleMethodChannel


    //*================ Method - Public ================*//

    /**
     *
     */
    fun initChannel(context: MainActivity, flutterEngine: FlutterEngine) {
        val binaryMessenger = flutterEngine.dartExecutor.binaryMessenger
        GlassesCaptureRecorder.init(context.applicationContext)
        //  Method
        bleMethodChannel = BleMethodChannel(
            context,
            MethodChannel(binaryMessenger, METHOD_CHANNEL_BLE_TAG)
        )
        //  Event
        EventChannel(binaryMessenger, EVENT_BLE_STATUS).setStreamHandler(context)
        EventChannel(binaryMessenger, EVENT_BLE_RECEIVE).setStreamHandler(context)
        EventChannel(binaryMessenger, EVENT_BLE_SPEECH_RECOGNIZE).setStreamHandler(context)
        EventChannel(binaryMessenger, EVENT_NOTIFICATIONS).setStreamHandler(context)
        EventChannel(binaryMessenger, EVENT_TELEPHONY).setStreamHandler(context)
    }

    /**
     *
     */
    fun addEventSink(eventTag: String?, eventSink: EventSink?) {
        if (eventTag == null || eventSink == null) {
            return
        }
        eventSinks[eventTag] = eventSink
    }

    /**
     *
     */
    fun removeEventSink(eventTag: String?) {
        eventTag?.let {
            eventSinks.remove(it)
        }
    }

    //*================ Method - Event Channel ================*//

    fun bleStatus(data: Any) = eventSinks[EVENT_BLE_STATUS]?.success(data)

    fun bleReceive(data: Any) = eventSinks[EVENT_BLE_RECEIVE]?.success(data)

    fun bleSpeechRecognize(data: Any) = eventSinks[EVENT_BLE_SPEECH_RECOGNIZE]?.success(data)

    fun notificationEvent(data: Any) = eventSinks[EVENT_NOTIFICATIONS]?.success(data)

    fun telephonyEvent(data: Any) = eventSinks[EVENT_TELEPHONY]?.success(data)

}

///
class BleMethodChannel(
   val context: MainActivity,
   private val methodChannel: MethodChannel
) {

    init {
        methodChannel.setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startScan" -> startScan(call, result)
            "stopScan" -> stopScan(call, result)
            "connectToGlasses" -> connectToGlasses(call, result)
            "disconnectFromGlasses" -> disconnectFromGlasses(call, result)
            "send" -> send(call, result)
            "startEvenAI" -> startEvenAI(call, result)
            "stopEvenAI" -> stopEvenAI(call, result)
            "getRecentNotifications" -> getRecentNotifications(call, result)
            "dismissNotification" -> dismissNotification(call, result)
            "isNotificationAccessEnabled" -> isNotificationAccessEnabled(call, result)
            "openNotificationAccessSettings" -> openNotificationAccessSettings(call, result)
            "startCompanionService" -> startCompanionService(call, result)
            "updateCompanionMode" -> updateCompanionMode(call, result)
            "reconnectGlassesLeg" -> reconnectGlassesLeg(call, result)
            "startGlassesCapture" -> startGlassesCapture(call, result)
            "stopGlassesCapture" -> stopGlassesCapture(call, result)
            "stopGlassesCaptureToTemp" -> stopGlassesCaptureToTemp(call, result)
            "cancelGlassesCapture" -> cancelGlassesCapture(call, result)
            "listRecordings" -> listRecordings(call, result)
            "renameRecording" -> renameRecording(call, result)
            "deleteRecording" -> deleteRecording(call, result)
            "shareRecording" -> shareRecording(call, result)
            "decodeLc3Frames" -> decodeLc3Frames(call, result)
            "getExternalFilesDir" -> getExternalFilesDir(call, result)
            "requestTelephonyPermissions" -> requestTelephonyPermissions(call, result)
            else -> result.notImplemented()
        }
    }

    //* =================== Native Call Flutter =================== *//

    fun startScan(call: MethodCall, result: MethodChannel.Result) = BleManager.instance.startScan(result)

    fun stopScan(call: MethodCall, result: MethodChannel.Result) = BleManager.instance.stopScan(result)

    fun connectToGlasses(call: MethodCall, result: MethodChannel.Result) {
        val deviceChannel: String = (call.arguments as? Map<*, *>)?.get("deviceName") as? String ?: ""
        if (deviceChannel.isEmpty()) {
            result.error("InvalidArguments", "Invalid arguments", null)
            return
        }
        BleManager.instance.connectToGlass(deviceChannel.replace("Pair_", ""), result)
    }

    fun disconnectFromGlasses(call: MethodCall, result: MethodChannel.Result) = BleManager.instance.disconnectFromGlasses(result)

    fun send(call: MethodCall, result: MethodChannel.Result) {
        BleManager.instance.senData(call.arguments as? Map<*, *>)
        result.success(null)
    }

    fun startEvenAI(call: MethodCall, result: MethodChannel.Result) {
        result.success(null)
    }

    fun stopEvenAI(call: MethodCall, result: MethodChannel.Result) {
        result.success(null)
    }

    fun getRecentNotifications(call: MethodCall, result: MethodChannel.Result) {
        result.success(NotificationFeedStore.snapshot())
    }

    fun dismissNotification(call: MethodCall, result: MethodChannel.Result) {
        val key = (call.arguments as? Map<*, *>)?.get("key") as? String ?: ""
        result.success(key.isNotBlank() && RecentNotificationsListenerService.dismissNotificationByKey(key))
    }

    fun isNotificationAccessEnabled(call: MethodCall, result: MethodChannel.Result) {
        result.success(RecentNotificationsListenerService.isAccessEnabled(context))
    }

    fun openNotificationAccessSettings(call: MethodCall, result: MethodChannel.Result) {
        RecentNotificationsListenerService.openSettings(context)
        result.success(null)
    }

    fun startCompanionService(call: MethodCall, result: MethodChannel.Result) {
        val modeLabel = (call.arguments as? Map<*, *>)?.get("modeLabel") as? String ?: "Glance"
        CompanionForegroundService.start(context, modeLabel)
        result.success(true)
    }

    fun updateCompanionMode(call: MethodCall, result: MethodChannel.Result) {
        val modeLabel = (call.arguments as? Map<*, *>)?.get("modeLabel") as? String ?: "Glance"
        CompanionForegroundService.updateMode(context, modeLabel)
        result.success(true)
    }

    fun reconnectGlassesLeg(call: MethodCall, result: MethodChannel.Result) {
        val lr = (call.arguments as? Map<*, *>)?.get("lr") as? String ?: ""
        if (lr != "L" && lr != "R") {
            result.error("InvalidArguments", "Expected lr=L or lr=R", null)
            return
        }
        result.success(BleManager.instance.reconnectLeg(lr))
    }

    fun startGlassesCapture(call: MethodCall, result: MethodChannel.Result) {
        result.success(GlassesCaptureRecorder.start())
    }

    fun stopGlassesCapture(call: MethodCall, result: MethodChannel.Result) {
        result.success(GlassesCaptureRecorder.stopAndSave())
    }

    fun stopGlassesCaptureToTemp(call: MethodCall, result: MethodChannel.Result) {
        result.success(GlassesCaptureRecorder.stopToTemp())
    }

    fun cancelGlassesCapture(call: MethodCall, result: MethodChannel.Result) {
        GlassesCaptureRecorder.cancel()
        result.success(true)
    }

    fun listRecordings(call: MethodCall, result: MethodChannel.Result) {
        result.success(GlassesCaptureRecorder.listRecordings())
    }

    fun renameRecording(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val uri = args?.get("uri") as? String
        val newName = args?.get("newDisplayName") as? String
        if (uri.isNullOrBlank() || newName.isNullOrBlank()) {
            result.error("InvalidArguments", "Expected uri + newDisplayName", null)
            return
        }
        result.success(GlassesCaptureRecorder.renameRecording(uri, newName))
    }

    fun deleteRecording(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val uri = args?.get("uri") as? String
        if (uri.isNullOrBlank()) {
            result.error("InvalidArguments", "Expected uri", null)
            return
        }
        result.success(GlassesCaptureRecorder.deleteRecording(uri))
    }

    fun shareRecording(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val uri = args?.get("uri") as? String
        val displayName = args?.get("displayName") as? String
        if (uri.isNullOrBlank()) {
            result.error("InvalidArguments", "Expected uri", null)
            return
        }
        result.success(GlassesCaptureRecorder.shareRecording(context, uri, displayName))
    }

    /**
     * Decodes a block of concatenated LC3 audio into raw 16-bit LE PCM.
     *
     * Expected arguments map:
     *   - `audio`     → [ByteArray]  raw LC3 payload (stripped chunk payloads concatenated)
     *   - `frameSize` → [Int]        bytes per LC3 frame (200 = live-mic hypothesis; 80 or 40 as fallbacks)
     *
     * Returns a [ByteArray] of concatenated PCM samples (16-bit LE, 16 kHz, mono).
     * Frames that error are skipped (logged, not fatal) so the caller always receives
     * whatever the decoder could produce from the good frames.
     *
     * If [audio] is shorter than [frameSize] the result is an empty [ByteArray].
     */
    fun decodeLc3Frames(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val audio = args?.get("audio") as? ByteArray
        val frameSize = (args?.get("frameSize") as? Int) ?: 200

        if (audio == null) {
            result.error("InvalidArguments", "decodeLc3Frames: 'audio' missing or wrong type", null)
            return
        }
        if (frameSize <= 0) {
            result.error("InvalidArguments", "decodeLc3Frames: 'frameSize' must be positive", null)
            return
        }

        val fullFrameCount = audio.size / frameSize
        val remainder = audio.size % frameSize

        if (remainder != 0) {
            Log.w("QuickNoteCapture", "decodeLc3Frames: audio.size=${audio.size} is not a multiple of frameSize=$frameSize — $remainder trailing bytes dropped")
        }

        val pcmChunks = ArrayList<ByteArray>(fullFrameCount)
        var totalPcmBytes = 0
        var errorCount = 0

        for (i in 0 until fullFrameCount) {
            val frame = audio.copyOfRange(i * frameSize, (i + 1) * frameSize)
            try {
                val pcm = Cpp.decodeLC3(frame)
                if (pcm != null && pcm.isNotEmpty()) {
                    pcmChunks.add(pcm)
                    totalPcmBytes += pcm.size
                } else {
                    Log.w("QuickNoteCapture", "decodeLc3Frames: frame $i returned null/empty PCM")
                    errorCount++
                }
            } catch (e: Exception) {
                Log.w("QuickNoteCapture", "decodeLc3Frames: frame $i decode error — ${e.message}")
                errorCount++
            }
        }

        Log.i("QuickNoteCapture", "decodeLc3Frames: frameSize=$frameSize frames=$fullFrameCount decoded=${fullFrameCount - errorCount} errors=$errorCount pcmBytes=$totalPcmBytes")

        val combined = ByteArray(totalPcmBytes)
        var offset = 0
        for (chunk in pcmChunks) {
            chunk.copyInto(combined, offset)
            offset += chunk.size
        }

        result.success(combined)
    }

    /**
     * Returns the app's primary external files directory path as a [String].
     *
     * This is `Context.getExternalFilesDir(null)` —
     * typically `/sdcard/Android/data/com.eddie.evencompanion/files`.
     * The directory is accessible via `adb pull` without root.
     * Returns `null` if external storage is unavailable.
     */
    fun getExternalFilesDir(call: MethodCall, result: MethodChannel.Result) {
        val dir = context.getExternalFilesDir(null)
        result.success(dir?.absolutePath)
    }

    //* =================== Flutter Call Native =================== *//

    fun flutterFoundPairedGlasses(device: BlePairDevice) = methodChannel.invokeMethod("foundPairedGlasses", device.toInfoJson())

    fun flutterGlassesConnected(deviceInfo: Map<String, Any>) = methodChannel.invokeMethod("glassesConnected", deviceInfo)

    fun flutterGlassesConnecting(deviceInfo: Map<String, Any>) = methodChannel.invokeMethod("glassesConnecting", deviceInfo)

    fun flutterGlassesDisconnected(deviceInfo: Map<String, Any>) = methodChannel.invokeMethod("glassesDisconnected", deviceInfo)

    fun flutterGlassesConnectionStateChanged(deviceInfo: Map<String, Any>) =
        methodChannel.invokeMethod("glassesConnectionStateChanged", deviceInfo)

    fun flutterCompanionModeSwitchRequested(modeLabel: String) =
        methodChannel.invokeMethod("companionModeSwitchRequested", mapOf("modeLabel" to modeLabel))

    /**
     * Notifies Dart that a QuickNote audio buffer has been flushed and is ready for
     * LC3 decoding.
     *
     * Method channel name: `method.bluetooth`
     * Method name: `quickNoteAudioReady`
     * Arguments map:
     *   - `noteUid`  → [ByteArray] (8 bytes from the `0x21` payload, bytes 7..14)
     *   - `audio`    → [ByteArray] (concatenated stripped chunk payloads; may be empty)
     *
     * Dart handler: `lib/ble_manager.dart` `_methodCallHandler` `case 'quickNoteAudioReady':`,
     * dispatches to `QuickNoteCaptureService`.
     */
    fun flutterQuickNoteAudioReady(noteUid: ByteArray, audio: ByteArray) =
        methodChannel.invokeMethod(
            "quickNoteAudioReady",
            mapOf("noteUid" to noteUid, "audio" to audio),
        )

    //* =================== Telephony Permission =================== *//

    private var pendingTelephonyResult: MethodChannel.Result? = null

    fun requestTelephonyPermissions(call: MethodCall, result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE)
            == PackageManager.PERMISSION_GRANTED
        ) {
            TelephonyEventService.start(context)
            result.success(true)
            return
        }
        pendingTelephonyResult = result
        ActivityCompat.requestPermissions(
            context,
            arrayOf(Manifest.permission.READ_PHONE_STATE),
            REQUEST_CODE_TELEPHONY,
        )
    }

    fun onTelephonyPermissionResult(granted: Boolean) {
        if (granted) {
            TelephonyEventService.start(context)
        }
        pendingTelephonyResult?.success(granted)
        pendingTelephonyResult = null
    }

    companion object {
        const val REQUEST_CODE_TELEPHONY = 3
    }

}
