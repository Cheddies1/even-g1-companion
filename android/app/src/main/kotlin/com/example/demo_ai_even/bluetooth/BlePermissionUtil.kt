package com.example.demo_ai_even.bluetooth

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

object BlePermissionUtil {

    /**
     *  Bluetooth scan and connect permission
     */
    private val BLUETOOTH_PERMISSIONS = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.ACCESS_FINE_LOCATION,
        )
    } else {
        arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION
        )
    }

    /**
     *  If permission not granted will call system permission dialog
     */
    fun checkBluetoothPermission(context: Activity): Boolean {
        val missingPermissions = BLUETOOTH_PERMISSIONS.filter { permission ->
            ContextCompat.checkSelfPermission(context, permission) != PackageManager.PERMISSION_GRANTED
        }
        if (missingPermissions.isNotEmpty()) {
            ActivityCompat.requestPermissions(context, missingPermissions.toTypedArray(), 1)
            return false
        }
        return true
    }

}