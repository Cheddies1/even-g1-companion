package com.eddie.evencompanion.model

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.os.Build
import android.util.Log
import com.eddie.evencompanion.bluetooth.BleManager
import com.eddie.evencompanion.bluetooth.GattWriteQueue

@SuppressLint("MissingPermission")
data class BleDevice(
    val name: String,
    val address: String,
    var gatt: BluetoothGatt?,
    var writeCharacteristic: BluetoothGattCharacteristic?,
    var isConnect: Boolean,
    val channelNumber: String,
) {

    companion object {
        fun createByDevice(
            name: String,
            address: String,
            channelNumber: String,
        ) = BleDevice(name, address, null, null,false, channelNumber)
    }

    fun isLeft() = name.contains("_L_")

    fun isRight() = name.contains("_R_")

    /**
     * Submits one characteristic write to the stack. Returns the raw submit
     * status: [GattWriteQueue.SUBMIT_OK], [GattWriteQueue.SUBMIT_BUSY]
     * (stack already has a write in flight), or [GattWriteQueue.SUBMIT_FAILED].
     *
     * Callers must serialise through [GattWriteQueue] — this method performs
     * no queuing of its own.
     */
    fun writeRaw(data: ByteArray): Int {
        val gatt = this.gatt
        val characteristic = this.writeCharacteristic
        if (gatt == null || characteristic == null) {
            Log.e(BleManager.LOG_TAG, "$name: Gatt or WriteCharacteristic is null")
            return GattWriteQueue.SUBMIT_FAILED
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    data,
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                )
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = data
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                @Suppress("DEPRECATION")
                val accepted = gatt.writeCharacteristic(characteristic)
                if (accepted) GattWriteQueue.SUBMIT_OK else GattWriteQueue.SUBMIT_FAILED
            }
        } catch (e: Exception) {
            Log.e(BleManager.LOG_TAG, "$name: write error = $e")
            GattWriteQueue.SUBMIT_FAILED
        }
    }
}

