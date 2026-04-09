package com.example.demo_ai_even.model

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.os.Build
import android.util.Log
import com.example.demo_ai_even.bluetooth.BleManager

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

    fun sendData(data: ByteArray): Boolean {
        if (gatt == null || writeCharacteristic == null) {
            Log.e(BleManager.LOG_TAG, "$name: Gatt or WriteCharacteristic is null")
            return false
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt!!.writeCharacteristic(writeCharacteristic!!, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
                true
            } else {
                gatt!!.writeCharacteristic(writeCharacteristic)
            }
        } catch (e: Exception) {
            Log.e(BleManager.LOG_TAG, "$name: send $data error = $e")
            false
        }
    }
}

