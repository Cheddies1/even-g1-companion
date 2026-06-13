package com.eddie.evencompanion.bluetooth

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import android.widget.Toast
import com.eddie.evencompanion.cpp.Cpp
import com.eddie.evencompanion.model.BleDevice
import com.eddie.evencompanion.model.BlePairDevice
import com.eddie.evencompanion.service.GlassesCaptureRecorder
import com.eddie.evencompanion.utils.ByteUtil
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
        // Literal, not BleManager::class.simpleName — R8 obfuscates the class
        // name in release builds, which would tag every native log line as "k".
        const val LOG_TAG = "BleManager"

        private const val SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        private const val WRITE_CHARACTERISTIC_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
        private const val READ_CHARACTERISTIC_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
        private const val CCCD_UUID = "00002902-0000-1000-8000-00805f9b34fb"

        //  SingleInstance
        private var mInstance: BleManager? = null
        val instance: BleManager = mInstance ?: BleManager()
    }

    // Per-leg setup sequencing — each GATT callback closure carries one of these.
    private enum class LegSetupPhase {
        IDLE,
        DESCRIPTOR_WRITE_PENDING,
        MTU_PENDING,
        BOND_PENDING,
        READY
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

    // Bond-state receiver — registered once against applicationContext in initBluetooth,
    // unregistered in deinit. Filters by address inside onReceive.
    private val bondStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            } ?: return

            val paired = connectedDevice ?: return
            val isKnownDevice = device.address == paired.leftDevice?.address ||
                    device.address == paired.rightDevice?.address
            if (!isKnownDevice) return

            val previousBond = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1)
            val newBond = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
            val side = if (device.address == paired.leftDevice?.address) "left" else "right"

            Log.i(LOG_TAG, "Bond state change: $side ${device.name} previousBond=$previousBond newBond=$newBond")

            if (newBond == BluetoothDevice.BOND_NONE && previousBond == BluetoothDevice.BOND_BONDING) {
                // Bonding was attempted and failed — encrypted writes will silently fail.
                Log.e(LOG_TAG, "BOND FAILED for $side leg (${device.name}) — encrypted writes may fail")
                notifyConnectionState("bond_failed")
            } else if (newBond == BluetoothDevice.BOND_BONDED) {
                Log.i(LOG_TAG, "Bond established for $side leg (${device.name})")
            }
        }
    }

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
    private val mainScope: CoroutineScope = MainScope()

    // Per-leg serialised write queues. Android allows one in-flight GATT write
    // per connection; everything outbound goes through these. Declared after
    // mainScope — the initialisers capture it.
    private val writeQueues: Map<String, GattWriteQueue> = mapOf(
        "L" to GattWriteQueue(
            lr = "L",
            scope = mainScope,
            isReady = { deviceFor("L")?.let { it.gatt != null && it.writeCharacteristic != null } == true },
            submit = { data -> deviceFor("L")?.writeRaw(data) ?: GattWriteQueue.SUBMIT_FAILED },
        ),
        "R" to GattWriteQueue(
            lr = "R",
            scope = mainScope,
            isReady = { deviceFor("R")?.let { it.gatt != null && it.writeCharacteristic != null } == true },
            submit = { data -> deviceFor("R")?.writeRaw(data) ?: GattWriteQueue.SUBMIT_FAILED },
        ),
    )

    private fun deviceFor(lr: String): BleDevice? =
        connectedDevice?.let { if (lr == "L") it.leftDevice else it.rightDevice }

    private fun lrForGatt(gatt: BluetoothGatt?): String? {
        val address = gatt?.device?.address ?: return null
        return when (address) {
            connectedDevice?.leftDevice?.address -> "L"
            connectedDevice?.rightDevice?.address -> "R"
            else -> null
        }
    }

    private fun storedDeviceFor(gatt: BluetoothGatt?): BleDevice? =
        lrForGatt(gatt)?.let { deviceFor(it) }

    // QuickNote audio buffer — accumulates the `0x1e c8 ...` stream that
    // follows a right-side `0x21` release.  Flushed on stream-end or timeout.
    private val quickNoteBuffer = QuickNoteAudioBuffer(
        scope = mainScope,
        onFlush = { noteUid, audioPayload ->
            Log.i(LOG_TAG, "QuickNote flush: noteUidBytes=${noteUid.size} audioBytes=${audioPayload.size}")
            BleChannelHelper.bleMC.flutterQuickNoteAudioReady(noteUid, audioPayload)
        },
    )

    //*================= Method - Public =================*//

    /**
     * Init bluetooth manager and get bluetooth adapter.
     * Also registers the bond-state receiver against applicationContext so it survives
     * activity lifecycle events.
     */
    fun initBluetooth(context: Activity) {
        weakActivity = WeakReference(context)
        bluetoothManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.getSystemService(BluetoothManager::class.java)
        } else {
            context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        }
        val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        context.applicationContext.registerReceiver(bondStateReceiver, filter)
        Log.v(LOG_TAG, "BleManager init success, bond-state receiver registered")
    }

    /**
     * Unregister receivers and release resources. Call from MainActivity.onDestroy.
     */
    fun deinit() {
        try {
            weakActivity.get()?.applicationContext?.unregisterReceiver(bondStateReceiver)
        } catch (e: IllegalArgumentException) {
            // Already unregistered — safe to ignore.
        }
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
     * Initial connection — uses autoConnect=false for fast time-to-connect.
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
        // If the pair objects are being replaced (e.g. fresh scan results), close
        // any gatts the old objects still own — otherwise they leak.
        connectedDevice?.let { old ->
            if (old.leftDevice !== leftDevice) closeLegGatt(old.leftDevice, "replaced-by-new-pair")
            if (old.rightDevice !== rightDevice) closeLegGatt(old.rightDevice, "replaced-by-new-pair")
        }
        connectedDevice = BlePairDevice(leftDevice, rightDevice)
        Log.i(
            LOG_TAG,
            "Connection attempt prepared: left=${leftDevice.name} (${leftDevice.address}), right=${rightDevice.name} (${rightDevice.address})"
        )
        weakActivity.get()?.let {
            // autoConnect=false: faster initial connect; the OS attempts once.
            startLegConnect(leftDevice, it, autoConnect = false)
            startLegConnect(rightDevice, it, autoConnect = false)
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

    /**
     * Explicit reconnect for one leg, called from Flutter.
     * Uses autoConnect=true so the OS will keep scanning and reconnect automatically
     * when the device comes back into range.
     */
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
                notifyConnectionState("reconnecting")
                // autoConnect=true: OS maintains a background scan and reconnects when in range.
                startLegConnect(device, activity, autoConnect = true)
            } catch (e: Exception) {
                Log.e(LOG_TAG, "Reconnect request failed for $side leg", e)
            } finally {
                reconnectInFlight.remove(lr)
            }
        }
        return true
    }

    /**
     * Closes and clears a leg's gatt, whether established or still pending-connect.
     * `close()` is the only way to cancel an outstanding `connectGatt` — without
     * it, repeated reconnect attempts each leak a GATT client until the per-app
     * cap (~32) is exhausted and every connect fails with status 133.
     */
    private fun closeLegGatt(device: BleDevice?, reason: String) {
        val gatt = device?.gatt ?: return
        Log.i(LOG_TAG, "Closing gatt for ${device.name} ($reason)")
        try {
            gatt.close()
        } catch (e: Exception) {
            Log.w(LOG_TAG, "gatt.close failed for ${device.name}", e)
        }
        device.gatt = null
        device.writeCharacteristic = null
        device.isConnect = false
    }

    /**
     * Issues a `connectGatt` for one leg, owning the returned instance from the
     * moment of creation. Invariant: at most one outstanding BluetoothGatt per
     * leg — any previous instance (pending or stale) is closed first.
     */
    private fun startLegConnect(device: BleDevice, activity: Activity, autoConnect: Boolean) {
        if (device.isConnect && device.gatt != null) {
            Log.i(LOG_TAG, "startLegConnect skipped — ${device.name} already connected")
            return
        }
        closeLegGatt(device, "superseded-by-new-connect")
        writeQueues[if (device.isLeft()) "L" else "R"]?.flush("new-connect")
        device.gatt = bluetoothAdapter.getRemoteDevice(device.address)
            .connectGatt(activity, autoConnect, bleGattCallBack())
        Log.i(LOG_TAG, "connectGatt issued for ${device.name} autoConnect=$autoConnect")
    }

    /**
     * Tears down both leg connections and fails all queued writes. Called when
     * the Flutter engine goes away (MainActivity finishing) — a connection the
     * engine can no longer drive is an orphan, not an asset.
     */
    fun releaseConnections() {
        Log.i(LOG_TAG, "releaseConnections: engine stopping — closing leg gatts")
        closeLegGatt(connectedDevice?.leftDevice, "engine-stopped")
        closeLegGatt(connectedDevice?.rightDevice, "engine-stopped")
        writeQueues.values.forEach { it.flush("engine-stopped") }
    }

    /**
     * Entry point for Flutter-originated writes. [onComplete] fires exactly once
     * with true only if every targeted leg's write completed.
     */
    fun senData(params: Map<*, *>?, onComplete: ((Boolean) -> Unit)? = null) {
        val data = params?.get("data") as ByteArray? ?: byteArrayOf()
        if (data.isEmpty()) {
            Log.e(LOG_TAG, "Send data is empty")
            onComplete?.invoke(false)
            return
        }
        when (params?.get("lr") as String?) {
            null -> requestData(data, onComplete = onComplete)
            "L" -> requestData(data, sendLeft = true, onComplete = onComplete)
            "R" -> requestData(data, sendRight = true, onComplete = onComplete)
            else -> onComplete?.invoke(false)
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
     * Creates a fresh GATT callback for one leg. Each instance carries its own
     * [LegSetupPhase] so operations are strictly serialised per connection:
     *   onServicesDiscovered → writeDescriptor
     *   onDescriptorWrite    → requestMtu
     *   onMtuChanged         → createBond (if not already bonded) + mark leg ready
     */
    private fun bleGattCallBack(): BluetoothGattCallback = object : BluetoothGattCallback() {

        // Per-closure phase tracker — no shared state needed between legs.
        var phase = LegSetupPhase.IDLE

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
                // A superseded instance (replaced by a newer connectGatt for the same
                // leg) connecting late must not enter setup — close it and move on.
                val stored = storedDeviceFor(gatt)
                if (stored != null && stored.gatt !== gatt) {
                    Log.w(LOG_TAG, "Superseded gatt connected for ${gatt?.device?.name} — closing duplicate")
                    gatt?.close()
                    return
                }
                notifyConnectionState("connecting")
                gatt?.discoverServices()
            } else if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                // Log status first — 8/19/22/133 are the most diagnostic disconnect reasons.
                Log.w(LOG_TAG, "Leg disconnected: device=${gatt?.device?.name} address=${gatt?.device?.address} disconnectStatus=$status")

                // Close the gatt instance we received in this callback. Avoids closing a
                // new connection if reconnectLeg has already replaced the stored reference.
                gatt?.close()
                phase = LegSetupPhase.IDLE

                connectedDevice?.let { paired ->
                    val isLeft = gatt?.device?.address == paired.leftDevice?.address
                    val isRight = gatt?.device?.address == paired.rightDevice?.address
                    // Only the current instance may mutate leg state — a stale
                    // instance disconnecting must not mark the live leg down.
                    if (isLeft && paired.leftDevice?.gatt === gatt) {
                        paired.leftDevice?.gatt = null
                        paired.leftDevice?.writeCharacteristic = null
                        paired.update(isLeftConnect = false)
                        writeQueues["L"]?.flush("disconnect")
                        Log.i(LOG_TAG, "Left leg disconnected: ${gatt?.device?.name}")
                        notifyConnectionState("disconnected")
                    } else if (isRight && paired.rightDevice?.gatt === gatt) {
                        paired.rightDevice?.gatt = null
                        paired.rightDevice?.writeCharacteristic = null
                        paired.update(isRightConnected = false)
                        writeQueues["R"]?.flush("disconnect")
                        Log.i(LOG_TAG, "Right leg disconnected: ${gatt?.device?.name}")
                        notifyConnectionState("disconnected")
                    } else if (isLeft || isRight) {
                        Log.i(LOG_TAG, "Stale gatt disconnect for ${gatt?.device?.name} — state untouched")
                    }
                    Unit
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt?, status: Int) {
            super.onServicesDiscovered(gatt, status)
            Log.i(LOG_TAG, "onServicesDiscovered: device=${gatt?.device?.name} status=$status")

            // The gatt is stored at connectGatt time, so identity is checkable
            // from the very first callback — superseded instances stop here.
            val stored = storedDeviceFor(gatt)
            if (stored == null || stored.gatt !== gatt) {
                Log.w(LOG_TAG, "onServicesDiscovered from superseded gatt (${gatt?.device?.name}) — closing")
                gatt?.close()
                return
            }

            connectedDevice?.let { paired ->
                var isLeft = false
                var isRight = false
                if (gatt?.device?.address == paired.leftDevice?.address) {
                    isLeft = true
                } else if (gatt?.device?.address == paired.rightDevice?.address) {
                    isRight = true
                }

                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.e(LOG_TAG, "onServicesDiscovered failed: status=$status device=${gatt?.device?.name}")
                    return
                }

                // Skip if already marked ready (e.g. spurious re-discovery on reconnect).
                if ((isLeft && paired.leftDevice?.isConnect == true) ||
                    (isRight && paired.rightDevice?.isConnect == true)) {
                    return
                }

                val server = gatt?.getService(UUID.fromString(SERVICE_UUID))
                val readCharacteristic = server?.getCharacteristic(UUID.fromString(READ_CHARACTERISTIC_UUID))
                if (readCharacteristic == null) {
                    Log.e(LOG_TAG, "onServicesDiscovered: readCharacteristic not found on ${gatt?.device?.name}")
                    return
                }
                gatt.setCharacteristicNotification(readCharacteristic, true)

                val writeCharacteristic = server.getCharacteristic(UUID.fromString(WRITE_CHARACTERISTIC_UUID))
                if (writeCharacteristic == null) {
                    Log.e(LOG_TAG, "onServicesDiscovered: writeCharacteristic not found on ${gatt?.device?.name}")
                    return
                }
                if (isLeft) {
                    paired.leftDevice?.writeCharacteristic = writeCharacteristic
                } else {
                    paired.rightDevice?.writeCharacteristic = writeCharacteristic
                }

                // Step 1 of 3: write CCCD to enable notifications. MTU + bond follow in callbacks.
                val descriptor = readCharacteristic.getDescriptor(UUID.fromString(CCCD_UUID))
                descriptor?.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                val written = gatt.writeDescriptor(descriptor)
                Log.d(LOG_TAG, "onServicesDiscovered: CCCD write initiated=$written device=${gatt.device?.name}")
                phase = LegSetupPhase.DESCRIPTOR_WRITE_PENDING
            }
        }

        // Step 2 of 3: descriptor write confirmed — now request MTU.
        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            super.onDescriptorWrite(gatt, descriptor, status)
            val statusLabel = if (status == BluetoothGatt.GATT_SUCCESS) "SUCCESS" else "FAILURE($status)"
            Log.d(LOG_TAG, "onDescriptorWrite: device=${gatt.device?.name} descriptor=${descriptor.uuid} status=$statusLabel")

            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(LOG_TAG, "CCCD descriptor write failed for ${gatt.device?.name} — notifications may not work")
                return
            }
            if (phase != LegSetupPhase.DESCRIPTOR_WRITE_PENDING) return

            phase = LegSetupPhase.MTU_PENDING
            gatt.requestMtu(251)
            Log.d(LOG_TAG, "onDescriptorWrite: MTU request issued for ${gatt.device?.name}")
        }

        // Step 3 of 3: MTU negotiated — conditionally bond, then mark leg ready.
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            super.onMtuChanged(gatt, mtu, status)
            val statusLabel = if (status == BluetoothGatt.GATT_SUCCESS) "SUCCESS" else "FAILURE($status)"
            Log.i(LOG_TAG, "onMtuChanged: device=${gatt.device?.name} mtu=$mtu status=$statusLabel")

            if (phase != LegSetupPhase.MTU_PENDING) return

            // Bond only if not already bonded — avoids stray re-pairing prompts on reconnects.
            if (gatt.device.bondState != BluetoothDevice.BOND_BONDED) {
                phase = LegSetupPhase.BOND_PENDING
                gatt.device.createBond()
                Log.i(LOG_TAG, "onMtuChanged: createBond() issued for ${gatt.device?.name}")
            } else {
                phase = LegSetupPhase.READY
                Log.i(LOG_TAG, "onMtuChanged: device already bonded, skipping createBond() for ${gatt.device?.name}")
            }

            markLegReady(gatt)
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            super.onCharacteristicWrite(gatt, characteristic, status)
            val ok = status == BluetoothGatt.GATT_SUCCESS
            if (!ok) {
                Log.e(LOG_TAG, "onCharacteristicWrite FAILED: device=${gatt.device?.name} char=${characteristic.uuid} status=$status")
            }
            // Drive the per-leg write queue forward. Arrives on a binder thread;
            // onWriteComplete hops onto the main dispatcher internally.
            lrForGatt(gatt)?.let { writeQueues[it]?.onWriteComplete(ok) }
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
                if (isMicData && value.size != 202) {
                    return@launch
                }
                //  eg. LC3 to PCM
                if (isMicData) {
                    val lc3 = value.copyOfRange(2, 202)
                    val pcmData = Cpp.decodeLC3(lc3)!!//200
                    GlassesCaptureRecorder.appendPcmData(pcmData)

                    // TODO
                    // to implement the pcmData for asr in AI answer
                    Log.d(this::class.simpleName, "============Lc3 data = $lc3, Pcm = $pcmData")
                }

                BleChannelHelper.bleReceive(mapOf(
                    "lr" to if (isLeft) "L" else "R",
                    "data" to value,
                    "type" to if (isMicData) "VoiceChunk" else "Receive",
                ))

                // QuickNote audio buffering — additive pathway, runs after bleReceive
                // so existing Dart consumers see every notification first in the original
                // order. Opens on a right-side 0x21 (15-byte), then accumulates 0x1e c8
                // chunks until the post-stream 0x1e (non-audio sub-code) or the watchdog
                // fires.
                routeToQuickNoteBuffer(value, isRight)
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
     * Marks a leg as ready after the setup sequence completes (MTU settled).
     * Sends the initial heartbeat, notifies Flutter of "ready" state, and fires
     * glassesConnected when both legs are up.
     */
    private fun markLegReady(gatt: BluetoothGatt) {
        val paired = connectedDevice ?: return
        val isLeft = gatt.device.address == paired.leftDevice?.address
        val isRight = gatt.device.address == paired.rightDevice?.address

        if (isLeft) {
            paired.update(leftGatt = gatt, isLeftConnect = true)
            Log.i(LOG_TAG, "Left leg ready: ${paired.leftDevice?.name}")
        } else if (isRight) {
            paired.update(rightGatt = gatt, isRightConnected = true)
            Log.i(LOG_TAG, "Right leg ready: ${paired.rightDevice?.name}")
        }

        // Initial heartbeat — fires after notifications are wired and MTU is
        // settled. Targeted at the leg that just came up; the other leg gets
        // its own when it reaches ready.
        requestData(
            byteArrayOf(0xf4.toByte(), 0x01.toByte()),
            sendLeft = isLeft,
            sendRight = isRight,
        )

        if (paired.isBothConnected()) {
            Log.i(LOG_TAG, "Both legs connected: left=${paired.leftDevice?.name}, right=${paired.rightDevice?.name}")
            weakActivity.get()?.runOnUiThread {
                BleChannelHelper.bleMC.flutterGlassesConnected(paired.toConnectedJson())
            }
        }
        notifyConnectionState(if (paired.isBothConnected()) "connected" else "connecting")
    }

    /**
     * Routes a write into the per-leg queues. When [onComplete] is supplied it
     * fires once, after all targeted legs report, with the AND of their results.
     * Completion counters are only ever touched on the main dispatcher (queue
     * callbacks run there), so no synchronisation is needed.
     */
    private fun requestData(
        data: ByteArray,
        sendLeft: Boolean = false,
        sendRight: Boolean = false,
        onComplete: ((Boolean) -> Unit)? = null,
    ) {
        val isBothSend = !sendLeft && !sendRight
        Log.d(LOG_TAG, "Send ${if (isBothSend) "both" else if (sendLeft) "left" else "right"} data = ${ByteUtil.byteToHexArray(data)}")
        val targets = mutableListOf<String>()
        if (sendLeft || isBothSend) targets.add("L")
        if (sendRight || isBothSend) targets.add("R")

        if (onComplete == null) {
            targets.forEach { lr -> writeQueues[lr]?.enqueue(data) }
            return
        }
        var remaining = targets.size
        var allOk = true
        targets.forEach { lr ->
            writeQueues.getValue(lr).enqueue(data) { ok ->
                allOk = allOk && ok
                remaining--
                if (remaining == 0) onComplete(allOk)
            }
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

    /**
     * Routes an incoming notification to the [quickNoteBuffer] state machine.
     *
     * Must be called from [mainScope] (i.e. inside the `mainScope.launch` block in
     * `onCharacteristicChanged`) so all buffer mutations happen on the same thread.
     *
     * Routing rules:
     * - Right-side `0x21` (any length ≥ 7) → open a new QuickNote capture.
     *   Historic firmware emitted 15 bytes; current firmware emits 42 bytes
     *   (notes-list metadata dump). Both are valid triggers — the host sends
     *   `02 01` from Dart to request audio regardless of `0x21` payload shape.
     * - `0x1e` while buffer is open → delegate to [QuickNoteAudioBuffer.onCmd1e],
     *   which appends audio chunks and flushes on non-audio sub-codes.
     * - Any other opcode while buffer is open → defensive flush via
     *   [QuickNoteAudioBuffer.onNonCmd1eWhileOpen].
     *
     * All three branches are additive: the notification still reaches [BleChannelHelper.bleReceive]
     * after this method returns.
     */
    private fun routeToQuickNoteBuffer(value: ByteArray, isRight: Boolean) {
        if (value.isEmpty()) return

        val opcode = value[0].toInt() and 0xff

        when {
            opcode == 0x21 && isRight && value.size >= 7 -> {
                quickNoteBuffer.openOnCmd21(value)
            }
            opcode == 0x1e && quickNoteBuffer.isOpen -> {
                if (value.size < 2) {
                    // Malformed frame — treat as non-audio to flush cleanly.
                    quickNoteBuffer.onNonCmd1eWhileOpen()
                } else {
                    quickNoteBuffer.onCmd1e(value)
                }
            }
            // Note: we deliberately do NOT flush on non-0x1e opcodes.
            // Heartbeats (0x25), F5 status events, and other background
            // traffic arrive constantly during the audio stream. The real
            // end-of-stream signals are:
            //   1. An 0x1e with a non-audio sub-code (handled by onCmd1e)
            //   2. The 500ms watchdog timeout (handled by QuickNoteAudioBuffer)
        }
    }

}
