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
                val result = gatt!!.writeCharacteristic(
                    writeCharacteristic!!,
                    data,
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                )
                if (data.isNotEmpty() && (data[0].toInt() == 0x15 || data[0].toInt() == 0x20 || data[0].toInt() == 0x16)) {
                    Log.i(
                        BleManager.LOG_TAG,
                        "NavigateBmpTraceNative: device=$name cmd=0x${data[0].toInt().toString(16)} len=${data.size} writeResult=$result"
                    )
                }
                result == BluetoothGatt.GATT_SUCCESS
            } else {
                val result = gatt!!.writeCharacteristic(writeCharacteristic)
                if (data.isNotEmpty() && (data[0].toInt() == 0x15 || data[0].toInt() == 0x20 || data[0].toInt() == 0x16)) {
                    Log.i(
                        BleManager.LOG_TAG,
                        "NavigateBmpTraceNative: device=$name cmd=0x${data[0].toInt().toString(16)} len=${data.size} writeResult=$result"
                    )
                }
                result
            }
        } catch (e: Exception) {
            Log.e(BleManager.LOG_TAG, "$name: send $data error = $e")
            false
        }
    }
}

