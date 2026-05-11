package com.eddie.evencompanion

import android.os.Bundle
import android.util.Log
import com.eddie.evencompanion.bluetooth.BleChannelHelper
import com.eddie.evencompanion.bluetooth.BleManager
import com.eddie.evencompanion.bluetooth.BlePermissionUtil
import com.eddie.evencompanion.cpp.Cpp
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity: FlutterActivity(), EventChannel.StreamHandler {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Cpp.init()
        BleManager.instance.initBluetooth(this)
        BlePermissionUtil.ensureNotificationPermission(this)
    }

    override fun onDestroy() {
        BleManager.instance.deinit()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        BleChannelHelper.initChannel(this, flutterEngine)
    }

    /// Interface - EventChannel.StreamHandler
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        Log.i(this::class.simpleName,"EventChannel.StreamHandler - OnListen: arguments = $arguments ,events = $events")
        BleChannelHelper.addEventSink(arguments as String?, events)
    }

    /// Interface - EventChannel.StreamHandler
    override fun onCancel(arguments: Any?) {
        Log.i(this::class.simpleName,"EventChannel.StreamHandler - OnCancel: arguments = $arguments")
        BleChannelHelper.removeEventSink(arguments as String?)
    }

}
