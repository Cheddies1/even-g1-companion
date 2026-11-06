package com.eddie.evencompanion.service

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.eddie.evencompanion.MainActivity
import com.eddie.evencompanion.R
import java.io.BufferedWriter
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Gate C harness for walking navigation (docs/plans/navigate-v1-cartographer.md
 * phase 3): records ~1 Hz location fixes to a CSV with the phone pocketed and
 * the screen off. No BLE, no routing.
 *
 * Typed `location` so Android keeps delivering fixes once the app is
 * backgrounded and the screen locks. Debug builds only start it, via:
 *
 *   adb shell am broadcast -p com.eddie.evencompanion -a com.eddie.evencompanion.GPS_TRACE --es cmd start [--es provider fused|gps]
 *   adb shell am broadcast -p com.eddie.evencompanion -a com.eddie.evencompanion.GPS_TRACE --es cmd stop
 *
 * Start it with the app in the foreground: Android 14+ refuses to start a
 * location foreground service from the background. The notification has a
 * Stop action so a walk can end without adb.
 *
 * Traces land in the app's external `files/gps/` dir, one CSV per run,
 * flushed per row so an OS kill loses at most the row in flight. Summarise
 * with `tool/gps_trace_summary.py`.
 */
class GpsTraceService : Service() {

    private var writer: BufferedWriter? = null
    private var file: File? = null
    private var fixes = 0
    private var startedElapsedMs = 0L
    private var lastFixElapsedMs = 0L

    private val listener = LocationListener { loc -> onFix(loc) }

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (writer != null) {
            Log.i(TAG, "already recording to ${file?.name}")
            return START_NOT_STICKY
        }
        startForegroundCompat(buildNotification())
        val provider = resolveProvider(intent?.getStringExtra(EXTRA_PROVIDER))
        if (!openTrace(provider) || !requestUpdates(provider)) {
            stopSelf()
        }
        // Not sticky: a restart after an OS kill would start a new file and
        // hide the kill. The gap in the trace is the evidence gate C needs.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        val lm = getSystemService(LocationManager::class.java)
        runCatching { lm.removeUpdates(listener) }
        writeEvent("stop", "fixes=$fixes")
        runCatching { writer?.close() }
        Log.i(TAG, "trace stopped ${file?.absolutePath} fixes=$fixes")
        writer = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun resolveProvider(requested: String?): String {
        val fusedAvailable = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        return when {
            requested == "gps" -> LocationManager.GPS_PROVIDER
            fusedAvailable -> LocationManager.FUSED_PROVIDER
            else -> LocationManager.GPS_PROVIDER
        }
    }

    private fun openTrace(provider: String): Boolean {
        val dir = getExternalFilesDir("gps") ?: return false.also { Log.e(TAG, "no external files dir") }
        dir.mkdirs()
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.UK).format(Date())
        val f = File(dir, "trace-$stamp.csv")
        return runCatching {
            writer = f.bufferedWriter()
            file = f
            startedElapsedMs = SystemClock.elapsedRealtime()
            writer!!.write(HEADER)
            writer!!.newLine()
            writeEvent("start", "provider=$provider sdk=${Build.VERSION.SDK_INT} model=${Build.MODEL}")
            Log.i(TAG, "trace started ${f.absolutePath} provider=$provider")
            true
        }.getOrElse {
            Log.e(TAG, "cannot open trace", it)
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun requestUpdates(provider: String): Boolean {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "ACCESS_FINE_LOCATION not granted")
            writeEvent("error", "no fine location permission")
            return false
        }
        val lm = getSystemService(LocationManager::class.java)
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val request = LocationRequest.Builder(INTERVAL_MS)
                    .setQuality(LocationRequest.QUALITY_HIGH_ACCURACY)
                    .setMinUpdateIntervalMillis(INTERVAL_MS)
                    .build()
                lm.requestLocationUpdates(provider, request, mainExecutor, listener)
            } else {
                lm.requestLocationUpdates(provider, INTERVAL_MS, 0f, listener, Looper.getMainLooper())
            }
            true
        }.getOrElse {
            Log.e(TAG, "requestLocationUpdates failed", it)
            writeEvent("error", "request failed: ${it.message}")
            false
        }
    }

    private fun onFix(loc: Location) {
        val fixElapsedMs = loc.elapsedRealtimeNanos / 1_000_000
        val gapMs = if (lastFixElapsedMs == 0L) 0L else fixElapsedMs - lastFixElapsedMs
        lastFixElapsedMs = fixElapsedMs
        fixes++
        writeRow(
            "fix",
            listOf(
                loc.provider ?: "",
                "%.7f".format(Locale.UK, loc.latitude),
                "%.7f".format(Locale.UK, loc.longitude),
                if (loc.hasAccuracy()) "%.1f".format(Locale.UK, loc.accuracy) else "",
                if (loc.hasSpeed()) "%.2f".format(Locale.UK, loc.speed) else "",
                if (loc.hasBearing()) "%.0f".format(Locale.UK, loc.bearing) else "",
            ),
            fixElapsedMs,
        )
        if (gapMs > GAP_LOG_MS) Log.w(TAG, "gap ${gapMs} ms before fix $fixes")
        if (fixes % 60 == 0) Log.i(TAG, "fixes=$fixes battery=${batteryPct()}%")
    }

    private fun writeEvent(kind: String, note: String) {
        writeRow(kind, listOf("", "", "", "", "", "", note.replace(',', ';')), SystemClock.elapsedRealtime())
    }

    // Columns: see HEADER. Fix rows leave `note` empty; event rows leave the
    // location columns empty.
    private fun writeRow(kind: String, fields: List<String>, elapsedMs: Long) {
        val w = writer ?: return
        val padded = if (fields.size < 7) fields + "" else fields
        val row = listOf(
            System.currentTimeMillis().toString(),
            (elapsedMs - startedElapsedMs).toString(),
            kind,
        ) + padded + listOf(batteryPct().toString(), screenState(), idleState())
        runCatching {
            w.write(row.joinToString(","))
            w.newLine()
            w.flush()
        }.onFailure { Log.e(TAG, "write failed", it) }
    }

    private fun batteryPct(): Int =
        getSystemService(BatteryManager::class.java)
            .getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)

    private fun screenState(): String =
        if (getSystemService(PowerManager::class.java).isInteractive) "on" else "off"

    private fun idleState(): String {
        val pm = getSystemService(PowerManager::class.java)
        return if (pm.isDeviceIdleMode) "doze" else "active"
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, GpsTraceService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GPS trace recording")
            .setWhen(System.currentTimeMillis())
            .setUsesChronometer(true)
            .setShowWhen(true)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .addAction(0, "Stop", stopIntent)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(CHANNEL_ID, "GPS trace", NotificationManager.IMPORTANCE_LOW)
            .apply { description = "Debug GPS trace recorder" }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        const val TAG = "G1Gps"
        private const val CHANNEL_ID = "even_companion_gps_trace"
        private const val ACTION_STOP = "com.eddie.evencompanion.action.STOP_GPS_TRACE"
        private const val ACTION_DEBUG = "com.eddie.evencompanion.GPS_TRACE"
        private const val EXTRA_PROVIDER = "provider"
        private const val INTERVAL_MS = 1000L
        private const val GAP_LOG_MS = 3000L
        // Distinct from 4102 (companion) and 4103 (phone capture).
        private const val NOTIFICATION_ID = 4104
        private const val HEADER =
            "wall_ms,t_ms,kind,provider,lat,lon,acc_m,speed_mps,bearing_deg,note,battery_pct,screen,idle"

        private var debugReceiverRegistered = false

        private val debugReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getStringExtra("cmd")) {
                    "start" -> {
                        val start = Intent(context, GpsTraceService::class.java)
                            .putExtra(EXTRA_PROVIDER, intent.getStringExtra(EXTRA_PROVIDER))
                        runCatching { ContextCompat.startForegroundService(context, start) }
                            .onFailure { Log.e(TAG, "start failed - is the app in the foreground?", it) }
                    }
                    "stop" -> context.stopService(Intent(context, GpsTraceService::class.java))
                    else -> Log.e(TAG, "GPS_TRACE needs --es cmd start|stop")
                }
            }
        }

        /** Debuggable builds only. Call from MainActivity.onCreate. */
        fun registerDebugReceiver(activity: Activity) {
            val debuggable = (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            if (!debuggable || debugReceiverRegistered) return
            val filter = IntentFilter(ACTION_DEBUG)
            val ctx = activity.applicationContext
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ctx.registerReceiver(debugReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                ctx.registerReceiver(debugReceiver, filter)
            }
            debugReceiverRegistered = true
            Log.i(TAG, "GPS trace receiver registered")
        }
    }
}
