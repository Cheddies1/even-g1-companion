package com.eddie.evencompanion.telephony

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.eddie.evencompanion.bluetooth.BleChannelHelper

object TelephonyEventService {

    private const val TAG = "TelephonyEvent"

    private const val STATE_IDLE    = "idle"
    private const val STATE_RINGING = "ringing"
    private const val STATE_OFFHOOK = "offhook"

    private var telephonyManager: TelephonyManager? = null
    private var lastState: String = STATE_IDLE
    private var isRegistered: Boolean = false

    // API 31+ callback — held so we can unregister it
    private var telephonyCallback: TelephonyCallback? = null

    // Pre-API-31 listener — held so we can unregister it
    @Suppress("DEPRECATION")
    private var legacyListener: PhoneStateListener? = null

    //*================ Public API ================*//

    /**
     * Checks READ_PHONE_STATE permission, registers the appropriate call-state listener
     * for the running API level, and begins emitting telephony events to Dart.
     *
     * Returns true if the listener was started (or was already running).
     * Returns false if the permission is absent or registration throws.
     */
    fun start(context: Context): Boolean {
        if (isRegistered) {
            return true
        }

        val appContext = context.applicationContext

        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "start: READ_PHONE_STATE not granted — aborting")
            return false
        }

        val tm = appContext.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        if (tm == null) {
            Log.w(TAG, "start: TelephonyManager unavailable on this device")
            return false
        }

        telephonyManager = tm

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                registerModernCallback(tm, appContext)
            } else {
                registerLegacyListener(tm)
            }
            isRegistered = true
            Log.i(TAG, "start: telephony listener registered (API ${Build.VERSION.SDK_INT})")
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "start: SecurityException registering listener — ${e.message}")
            telephonyManager = null
            false
        }
    }

    /**
     * Unregisters the call-state listener and resets internal state.
     */
    fun stop() {
        if (!isRegistered) return

        val tm = telephonyManager
        if (tm != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                telephonyCallback?.let { tm.unregisterTelephonyCallback(it) }
                telephonyCallback = null
            } else {
                @Suppress("DEPRECATION")
                legacyListener?.let { tm.listen(it, PhoneStateListener.LISTEN_NONE) }
                legacyListener = null
            }
        }

        telephonyManager = null
        lastState = STATE_IDLE
        isRegistered = false
        Log.i(TAG, "stop: telephony listener unregistered")
    }

    //*================ Private — API 31+ ================*//

    private fun registerModernCallback(tm: TelephonyManager, appContext: Context) {
        val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
            override fun onCallStateChanged(state: Int) {
                handleStateChange(state, number = null)
            }
        }
        telephonyCallback = callback
        tm.registerTelephonyCallback(appContext.mainExecutor, callback)
    }

    //*================ Private — Pre-API-31 ================*//

    @Suppress("DEPRECATION")
    private fun registerLegacyListener(tm: TelephonyManager) {
        val listener = object : PhoneStateListener() {
            override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                handleStateChange(state, number = phoneNumber)
            }
        }
        legacyListener = listener
        tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
    }

    //*================ Private — Shared State Handler ================*//

    private fun handleStateChange(state: Int, number: String?) {
        val newState = when (state) {
            TelephonyManager.CALL_STATE_RINGING  -> STATE_RINGING
            TelephonyManager.CALL_STATE_OFFHOOK  -> STATE_OFFHOOK
            else                                  -> STATE_IDLE
        }

        if (newState == lastState) return

        val isOutgoing = lastState == STATE_IDLE && newState == STATE_OFFHOOK
        lastState = newState

        Log.i(TAG, "onCallStateChanged: state=$newState isOutgoing=$isOutgoing")

        val data = mutableMapOf<String, Any?>(
            "state"      to newState,
            "isOutgoing" to isOutgoing,
            "number"     to number,
        )
        BleChannelHelper.telephonyEvent(data)
    }

}
