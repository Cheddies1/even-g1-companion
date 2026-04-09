package com.example.demo_ai_even.bluetooth

import com.example.demo_ai_even.MainActivity
import com.example.demo_ai_even.notifications.RecentNotificationsListenerService
import com.example.demo_ai_even.service.CompanionForegroundService
import com.example.demo_ai_even.service.GlassesCaptureRecorder
import com.example.demo_ai_even.model.BlePairDevice
import com.example.demo_ai_even.notifications.NotificationFeedStore
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
            "startGlassesCapture" -> startGlassesCapture(call, result)
            "stopGlassesCapture" -> stopGlassesCapture(call, result)
            "cancelGlassesCapture" -> cancelGlassesCapture(call, result)
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

    fun startGlassesCapture(call: MethodCall, result: MethodChannel.Result) {
        result.success(GlassesCaptureRecorder.start())
    }

    fun stopGlassesCapture(call: MethodCall, result: MethodChannel.Result) {
        result.success(GlassesCaptureRecorder.stopAndSave())
    }

    fun cancelGlassesCapture(call: MethodCall, result: MethodChannel.Result) {
        GlassesCaptureRecorder.cancel()
        result.success(true)
    }

    //* =================== Flutter Call Native =================== *//

    fun flutterFoundPairedGlasses(device: BlePairDevice) = methodChannel.invokeMethod("foundPairedGlasses", device.toInfoJson())

    fun flutterGlassesConnected(deviceInfo: Map<String, Any>) = methodChannel.invokeMethod("glassesConnected", deviceInfo)

    fun flutterGlassesConnecting(deviceInfo: Map<String, Any>) = methodChannel.invokeMethod("glassesConnecting", deviceInfo)

    fun flutterGlassesDisconnected(deviceInfo: Map<String, Any>) = methodChannel.invokeMethod("glassesDisconnected", deviceInfo)

}
