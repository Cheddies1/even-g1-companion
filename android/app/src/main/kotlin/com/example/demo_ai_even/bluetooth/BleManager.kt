package com.example.demo_ai_even.bluetooth

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.util.Log
import android.widget.Toast
import com.example.demo_ai_even.cpp.Cpp
import com.example.demo_ai_even.model.BleDevice
import com.example.demo_ai_even.model.BlePairDevice
import com.example.demo_ai_even.service.GlassesCaptureRecorder
import com.example.demo_ai_even.utils.ByteUtil
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

@SuppressLint("MissingPermission")
class BleManager private constructor() {

    companion object {
        val LOG_TAG = BleManager::class.simpleName

        private const val SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        private const val WRITE_CHARACTERISTIC_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
        private const val READ_CHARACTERISTIC_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

        //  SingleInstance
        private var mInstance: BleManager? = null
        val instance: BleManager = mInstance ?: BleManager()
    }

    //  Context
    private lateinit var weakActivity: WeakReference<Activity>
    //  Scan，Connect，Disconnect，Send
    private lateinit var bluetoothManager: BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter
        get() = bluetoothManager.adapter
    //  Save device address
    private val bleDevices: MutableList<BleDevice> = mutableListOf()
    private var connectedDevice: BlePairDevice? = null
    private val reconnectInFlight: MutableMap<String, Boolean> = ConcurrentHashMap()

    /// Scan Config
    //  - Setting: Low latency
    private val scanSettings = ScanSettings
        .Builder()
        .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
        .build()
    //  -
    private val scanCallback: ScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            super.onScanResult(callbackType, result)
            val device = result?.device
            //  eg. G1_45_L_92333
            if (device == null ||
                device.name.isNullOrEmpty() ||
                !device.name.contains("G\\d+".toRegex()) ||
                device.name.split("_").size != 4 ||
                bleDevices.firstOrNull { it.address == device.address } != null) {
                return
            }
            Log.i(LOG_TAG, "ScanCallback - Result: CallbackType = $callbackType, DeviceName = ${device.name}")
            //  1. Get same channel num device,and make pair
            val channelNum = device.name.split("_")[1]
            bleDevices.add(BleDevice.createByDevice(device.name, device.address, channelNum))
            val pairDevices = bleDevices.filter { it.name.contains("_$channelNum" + "_") }
            if (pairDevices.size <= 1) {
                return
            }
            val leftDevice = pairDevices.firstOrNull { it.isLeft() }
            val rightDevice = pairDevices.firstOrNull { it.isRight() }
            if (leftDevice == null || rightDevice == null) {
                return
            }
            Log.i(
                LOG_TAG,
                "Paired scan result discovered: channel=$channelNum, left=${leftDevice.name}, right=${rightDevice.name}"
            )
            BleChannelHelper.bleMC.flutterFoundPairedGlasses(BlePairDevice(leftDevice, rightDevice))
        }
        override fun onScanFailed(errorCode: Int) {
            super.onScanFailed(errorCode)
            Log.e(LOG_TAG, "ScanCallback - Failed: ErrorCode = $errorCode")
        }
    }

    /// UI Thread
    private val  mainScope: CoroutineScope = MainScope()

    //*================= Method - Public =================*//

    /**
     * Init bluetooth manager and get bluetooth adapter
     *
     * @param context
     *
     */
    fun initBluetooth(context: Activity) {
        weakActivity = WeakReference(context)
        bluetoothManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.getSystemService(BluetoothManager::class.java)
        } else {
            context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        }
        Log.v(LOG_TAG, "BleManager init success")
    }

    /**
     *
     */
    fun startScan(result: MethodChannel.Result) {
        if (!checkBluetoothStatus()) {
            result.error("Permission", "", null)
            return
        }
        bleDevices.clear()
        bluetoothAdapter.bluetoothLeScanner.startScan(null, scanSettings, scanCallback)
        Log.v(LOG_TAG, "Start scan")
        result.success("Scanning for devices...")
    }

    /**
     *
     */
    fun stopScan(result: MethodChannel.Result? = null) {
        if (!checkBluetoothStatus()) {
            result?.error("Permission", "", null)
            return
        }
        bluetoothAdapter.bluetoothLeScanner.stopScan(scanCallback)
        Log.v(LOG_TAG, "Stop scan")
        result?.success("Scan stopped")
    }

    /**
     *
     */
    fun connectToGlass(deviceChannel: String, result: MethodChannel.Result) {
        Log.i(LOG_TAG, "connectToGlass: deviceChannel = $deviceChannel")
        val leftPairChannel = "_$deviceChannel" + "_L_"
        var leftDevice = connectedDevice?.leftDevice
        if (leftDevice?.name?.contains(leftPairChannel) != true) {
            leftDevice = bleDevices.firstOrNull { it.name.contains(leftPairChannel) }
        }
        val rightPairChannel = "_$deviceChannel" + "_R_"
        var rightDevice = connectedDevice?.rightDevice
        if (rightDevice?.name?.contains(rightPairChannel) != true) {
            rightDevice = bleDevices.firstOrNull { it.name.contains(rightPairChannel) }
        }
        if (leftDevice == null || rightDevice == null) {
            result.error("PeripheralNotFound", "One or both peripherals are not found", null)
            return
        }
        connectedDevice = BlePairDevice(leftDevice, rightDevice)
        Log.i(
            LOG_TAG,
            "Connection attempt prepared: left=${leftDevice.name} (${leftDevice.address}), right=${rightDevice.name} (${rightDevice.address})"
        )
        weakActivity.get()?.let {
            bluetoothAdapter.getRemoteDevice(leftDevice.address).connectGatt(it, false, bleGattCallBack())
            bluetoothAdapter.getRemoteDevice(rightDevice.address).connectGatt(it, false, bleGattCallBack())
        }
        result.success("Connecting to G1_$deviceChannel ...")
    }

    /**
     *
     */
    fun disconnectFromGlasses(result: MethodChannel.Result) {
        Log.i(LOG_TAG, "connectToGlass: G1_${connectedDevice?.deviceName()}")
        result.success("Disconnected all devices.")
    }

    fun reconnectLeg(lr: String): Boolean {
        val side = if (lr == "L") "left" else "right"
        if (reconnectInFlight[lr] == true) {
            Log.i(LOG_TAG, "Reconnect already in flight for $side leg")
            return false
        }
        val device = connectedDevice?.let {
            if (lr == "L") it.leftDevice else it.rightDevice
        } ?: return false
        val activity = weakActivity.get() ?: return false

        reconnectInFlight[lr] = true
        mainScope.launch {
            try {
                Log.i(LOG_TAG, "Reconnect requested for $side leg: ${device.name}")
                device.gatt?.disconnect()
                device.gatt?.close()
                device.gatt = null
                device.writeCharacteristic = null
                device.isConnect = false
                notifyConnectionState("reconnecting")
                bluetoothAdapter.getRemoteDevice(device.address)
                    .connectGatt(activity, false, bleGattCallBack())
            } catch (e: Exception) {
                Log.e(LOG_TAG, "Reconnect request failed for $side leg", e)
            } finally {
                reconnectInFlight.remove(lr)
            }
        }
        return true
    }

    /**
     *
     */
    fun senData(params: Map<*, *>?) {
        val data = params?.get("data") as ByteArray? ?: byteArrayOf()
        if (data.isEmpty()) {
            Log.e(LOG_TAG, "Send data is empty")
            return
        }
        val lr = params?.get("lr") as String?
        when (lr) {
            null -> requestData(data)
            "L" -> requestData(data, sendLeft = true)
            "R" -> requestData(data, sendRight = true)
        }
    }

    //*================= Method - Private =================*//

    /**
     *  Check if Bluetooth is turned on and permission status
     */
    private fun checkBluetoothStatus(): Boolean {
        if (weakActivity.get() == null) {
            return false
        }
        if (!bluetoothAdapter.isEnabled) {
            Toast.makeText(weakActivity.get()!!, "Bluetooth is turned off, please turn it on first!", Toast.LENGTH_SHORT).show()
            return false
        }
        if (!BlePermissionUtil.checkBluetoothPermission(weakActivity.get()!!)) {
            return false
        }
        return true
    }

    /**
     *
     */
    private fun bleGattCallBack(): BluetoothGattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
            super.onConnectionStateChange(gatt, status, newState)
            val stateLabel = when (newState) {
                BluetoothGatt.STATE_CONNECTED -> "CONNECTED"
                BluetoothGatt.STATE_CONNECTING -> "CONNECTING"
                BluetoothGatt.STATE_DISCONNECTED -> "DISCONNECTED"
                BluetoothGatt.STATE_DISCONNECTING -> "DISCONNECTING"
                else -> "STATE_$newState"
            }
            Log.i(
                LOG_TAG,
                "Gatt connection state change: device=${gatt?.device?.name} address=${gatt?.device?.address} status=$status state=$stateLabel"
            )
            if (newState == BluetoothGatt.STATE_CONNECTED) {
                notifyConnectionState("connecting")
                gatt?.discoverServices()
            } else if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                connectedDevice?.let {
                    val isLeft = gatt?.device?.address == it.leftDevice?.address
                    val isRight = gatt?.device?.address == it.rightDevice?.address
                    if (isLeft) {
                        it.update(isLeftConnect = false)
                        Log.i(LOG_TAG, "Left leg disconnected: ${gatt?.device?.name}")
                    } else if (isRight) {
                        it.update(isRightConnected = false)
                        Log.i(LOG_TAG, "Right leg disconnected: ${gatt?.device?.name}")
                    }
                    notifyConnectionState("disconnected")
                    Unit
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt?, status: Int) {
            super.onServicesDiscovered(gatt, status)
            Log.e(
                LOG_TAG,
                "BluetoothGattCallback - onServicesDiscovered: $gatt, status = $status"
            )
            connectedDevice?.let {
                //  1. Save gatt
                var isLeft = false
                var isRight = false
                if (gatt?.device?.address == it.leftDevice?.address) {
                    it.update(leftGatt = gatt)
                    isLeft = true
                } else if (gatt?.device?.address == it.rightDevice?.address) {
                    it.update(rightGatt = gatt)
                    isRight = true
                }
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    //  1. Check if it is already connected, and if it is, do not repeat the process
                    if ((isLeft && it.leftDevice?.isConnect == true) ||
                        (isRight && it.rightDevice?.isConnect == true)) {
                        return
                    }
                    //  2. Get Bluetooth read-write services
                    val server = gatt?.getService(UUID.fromString(SERVICE_UUID))
                    //  3. Check if gatt can read character
                    val readCharacteristic =
                        server?.getCharacteristic(UUID.fromString(READ_CHARACTERISTIC_UUID))
                    if (readCharacteristic == null) {
                        Log.e(
                            LOG_TAG,
                            "BluetoothGattCallback - onServicesDiscovered: $gatt, Not found readCharacteristicUuid from $server"
                        )
                        return
                    }
                    gatt.setCharacteristicNotification(readCharacteristic, true)
                    //  4. Check if gatt can write character
                    val writeCharacteristic =
                        server.getCharacteristic(UUID.fromString(WRITE_CHARACTERISTIC_UUID))
                    if (writeCharacteristic == null) {
                        Log.e(LOG_TAG, "BluetoothGattCallback - onServicesDiscovered: $gatt, Not found readCharacteristicUuid from $server")
                        return
                    }
                    if (isLeft) {
                        connectedDevice?.leftDevice?.writeCharacteristic = writeCharacteristic
                    } else {
                        connectedDevice?.rightDevice?.writeCharacteristic = writeCharacteristic
                    }
                    //  5.
                    val descriptor =
                        readCharacteristic.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
                    Log.d(LOG_TAG, "BluetoothGattCallback - onServicesDiscovered: $gatt, get descriptor :${descriptor}")
                    descriptor?.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    val isWrite = gatt.writeDescriptor(descriptor)
                    Log.d(LOG_TAG, "BluetoothGattCallback - onServicesDiscovered: descriptor isWrite :${isWrite}")
                    //  6.
                    gatt.requestMtu(251)
                    //  7.
                    gatt.device?.createBond()
                    //  8. Update connect status，and check is both connected
                    if (isLeft) {
                        it.update(leftGatt = gatt, isLeftConnect = true)
                        Log.i(LOG_TAG, "Left leg ready: ${it.leftDevice?.name}")
                    } else if (isRight) {
                        it.update(rightGatt = gatt, isRightConnected = true)
                        Log.i(LOG_TAG, "Right leg ready: ${it.rightDevice?.name}")
                    }
                    requestData(byteArrayOf(0xf4.toByte(), 0x01.toByte()))
                    if (it.isBothConnected()) {
                        Log.i(
                            LOG_TAG,
                            "Both legs connected: left=${it.leftDevice?.name}, right=${it.rightDevice?.name}"
                        )
                        weakActivity.get()?.runOnUiThread {
                            BleChannelHelper.bleMC.flutterGlassesConnected(it.toConnectedJson())
                        }
                    }
                    notifyConnectionState(if (it.isBothConnected()) "connected" else "connecting")
                }
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            super.onCharacteristicChanged(gatt, characteristic, value)
            mainScope.launch {
                val isLeft = gatt.device.address == connectedDevice?.leftDevice?.address
                val isRight = gatt.device.address == connectedDevice?.rightDevice?.address
                if (!isLeft && !isRight) {
                    return@launch
                }
                //  Mic data:
                //  - each pack data length must be 202
                //  - data index: 0 = cmd, 1 = pack serial number，2～201 = real mic data
                val isMicData = value[0] == 0xF1.toByte()
                if(isMicData && value.size != 202) {
                    return@launch
                }
                //  eg. LC3 to PCM
                if (isMicData) {
                    val lc3 = value.copyOfRange(2, 202)
                    val pcmData = Cpp.decodeLC3(lc3)!!//200
                    GlassesCaptureRecorder.appendPcmData(pcmData)

                    // TODO 
                    // to implement the pcmData for asr in AI answer
                    Log.d(this::class.simpleName,"============Lc3 data = $lc3, Pcm = $pcmData")
                }
                BleChannelHelper.bleReceive(mapOf(
                    "lr" to if (isLeft)  "L" else "R",
                    "data" to value,
                    "type" to if (isMicData)  "VoiceChunk" else "Receive",
                 ))
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            super.onCharacteristicRead(gatt, characteristic, value, status)
            print("===========onCharacteristicRead: $value")
        }

    }

    /**
     *
     */
    private fun requestData(data: ByteArray, sendLeft: Boolean = false, sendRight: Boolean = false) {
        val isBothSend = !sendLeft && !sendRight
        Log.d(LOG_TAG, "Send ${ if (isBothSend) "both" else if (sendLeft)  "left" else "right"} data = ${ByteUtil.byteToHexArray(data)}")
        if (sendLeft || isBothSend) {
            connectedDevice?.leftDevice?.sendData(data)
        }
        if (sendRight || isBothSend) {
            connectedDevice?.rightDevice?.sendData(data)
        }
    }

    private fun notifyConnectionState(status: String) {
        connectedDevice?.let {
            weakActivity.get()?.runOnUiThread {
                BleChannelHelper.bleMC.flutterGlassesConnectionStateChanged(
                    it.toConnectionStateJson(status)
                )
            }
        }
    }

}
