package com.example.demo_ai_even.model

import android.bluetooth.BluetoothGatt

data class BlePairDevice(
    var leftDevice: BleDevice?,
    var rightDevice: BleDevice?,
) {
    /**
     *
     */
    fun toInfoJson(): Map<String, String> = mapOf(
        "leftDeviceName" to (leftDevice?.name ?: ""),
        "rightDeviceName" to (rightDevice?.name ?: ""),
        "channelNumber" to (leftDevice?.channelNumber ?: ""),
    )

    /**
     *
     */
    fun toConnectedJson(): Map<String, Any> = mapOf(
        "leftDeviceName" to (leftDevice?.name ?: ""),
        "rightDeviceName" to (rightDevice?.name ?: ""),
        "status" to "connected"
    )

    /**
     *
     */
    fun update(leftGatt: BluetoothGatt? = null, isLeftConnect: Boolean? = null, rightGatt: BluetoothGatt? = null, isRightConnected: Boolean? = null) {
        if (leftGatt != null) {
            this.leftDevice?.gatt = leftGatt
        }
        if (isLeftConnect != null) {
            this.leftDevice?.isConnect = isLeftConnect
        }
        if (rightGatt != null) {
            this.rightDevice?.gatt = rightGatt
        }
        if (isRightConnected != null) {
            this.rightDevice?.isConnect = isRightConnected
        }
    }

    /**
     *
     */
    fun deviceName() = leftDevice?.name ?: rightDevice?.name ?: ""

    /**
     *
     */
    fun isBothConnected() = leftDevice?.isConnect == true && rightDevice?.isConnect == true
}