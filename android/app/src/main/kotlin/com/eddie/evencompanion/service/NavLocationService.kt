package com.eddie.evencompanion.service

import android.Manifest
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
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.eddie.evencompanion.MainActivity
import com.eddie.evencompanion.R
import io.flutter.plugin.common.EventChannel.EventSink
import java.io.File

/**
 * Location source for walking navigation (plan navigate-v1-cartographer, phase 5).
 *
 * A `location`-typed foreground service, so fixes keep flowing with the screen
 * off (gate C, docs/FINDINGS-screen-off-gps.md). Same request as the gate C
 * recorder: `FUSED_PROVIDER`, 1000 ms, high accuracy. Android 14+ refuses to
 * start it from the background, so it is started while the app is in front
 * (a Google Maps share brings the app forward).
 *
 * Replay mode plays a recorded gate C trace CSV from the app's external
 * `files/gps/` dir at its original pace (or faster), through the same path, so
 * the whole navigator can be exercised on the glasses at a desk.
 *
 * Fixes and service events go to Dart through [NavBridge].
 */
class NavLocationService : Service() {

    private val listener = LocationListener { loc -> onFix(loc) }
    private val handler = Handler(Looper.getMainLooper())
    private var running = false
    private var replayRows: List<List<String>> = emptyList()
    private var replayIndex = 0
    private var replaySpeed = 1.0
    private var replayCols: Map<String, Int> = emptyMap()

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            NavBridge.emit(mapOf("kind" to "stopped", "reason" to "notification"))
            stopSelf()
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        try {
            startForegroundCompat(buildNotification(intent?.getStringExtra(EXTRA_TITLE)))
        } catch (e: SecurityException) {
            // Android 14+: a location FGS cannot start while the app is in the
            // background, even with the permission granted. A Google Maps share
            // brings the app forward; adb-driven trips must `am start` it first.
            Log.e(TAG, "cannot start location service from the background", e)
            NavBridge.emit(mapOf("kind" to "error", "reason" to "open the app first (background location start refused)"))
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        val replay = intent?.getStringExtra(EXTRA_REPLAY)
        val ok = if (replay.isNullOrEmpty()) {
            requestUpdates()
        } else {
            replaySpeed = intent.getDoubleExtra(EXTRA_SPEED, 1.0).coerceIn(0.1, 50.0)
            startReplay(replay)
        }
        if (!ok) {
            NavBridge.emit(mapOf("kind" to "error", "reason" to "location start failed"))
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacksAndMessages(null)
        runCatching { getSystemService(LocationManager::class.java).removeUpdates(listener) }
        Log.i(TAG, "stopped")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun requestUpdates(): Boolean {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "ACCESS_FINE_LOCATION not granted")
            return false
        }
        val lm = getSystemService(LocationManager::class.java)
        val provider =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                lm.allProviders.contains(LocationManager.FUSED_PROVIDER)
            ) LocationManager.FUSED_PROVIDER else LocationManager.GPS_PROVIDER
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
            Log.i(TAG, "live location via $provider")
            true
        }.getOrElse {
            Log.e(TAG, "requestLocationUpdates failed", it)
            false
        }
    }

    private fun onFix(loc: Location) {
        NavBridge.emit(
            mapOf(
                "kind" to "fix",
                "t" to loc.elapsedRealtimeNanos / 1_000_000,
                "lat" to loc.latitude,
                "lon" to loc.longitude,
                "acc" to if (loc.hasAccuracy()) loc.accuracy.toDouble() else null,
                "speed" to if (loc.hasSpeed()) loc.speed.toDouble() else null,
            )
        )
    }

    // ---- replay ---------------------------------------------------------------

    private fun startReplay(name: String): Boolean {
        val dir = getExternalFilesDir("gps") ?: return false
        val file = File(dir, File(name).name) // never escape the gps dir
        if (!file.exists()) {
            Log.e(TAG, "replay file not found: ${file.name}")
            return false
        }
        val lines = file.readLines()
        if (lines.size < 2) return false
        replayCols = lines.first().split(',').withIndex().associate { it.value to it.index }
        val kind = replayCols["kind"] ?: return false
        replayRows = lines.drop(1).map { it.split(',') }.filter { it.getOrNull(kind) == "fix" }
        replayIndex = 0
        Log.i(TAG, "replaying ${file.name}: ${replayRows.size} fixes at ${replaySpeed}x")
        NavBridge.emit(mapOf("kind" to "replay", "fixes" to replayRows.size))
        handler.post(::replayNext)
        return replayRows.isNotEmpty()
    }

    private fun replayNext() {
        if (!running) return
        if (replayIndex >= replayRows.size) {
            NavBridge.emit(mapOf("kind" to "stopped", "reason" to "replay finished"))
            stopSelf()
            return
        }
        val row = replayRows[replayIndex]
        fun col(n: String) = replayCols[n]?.let { row.getOrNull(it) }
        val t = col("t_ms")?.toLongOrNull() ?: 0L
        NavBridge.emit(
            mapOf(
                "kind" to "fix",
                "t" to t,
                "lat" to (col("lat")?.toDoubleOrNull() ?: 0.0),
                "lon" to (col("lon")?.toDoubleOrNull() ?: 0.0),
                "acc" to col("acc_m")?.toDoubleOrNull(),
                "speed" to col("speed_mps")?.toDoubleOrNull(),
            )
        )
        replayIndex++
        val nextT = replayRows.getOrNull(replayIndex)
            ?.let { r -> replayCols["t_ms"]?.let { r.getOrNull(it)?.toLongOrNull() } }
        val delay = if (nextT == null) 0L else ((nextT - t) / replaySpeed).toLong().coerceIn(0L, 10_000L)
        handler.postDelayed(::replayNext, delay)
    }

    // ---- foreground plumbing ---------------------------------------------------

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(title: String?): Notification {
        val contentIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, NavLocationService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title ?: "Walking navigation")
            .setContentText("Tap to open, Stop to end the trip")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setUsesChronometer(true)
            .setCategory(Notification.CATEGORY_NAVIGATION)
            .setContentIntent(contentIntent)
            .addAction(0, "Stop", stopIntent)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(CHANNEL_ID, "Walking navigation", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        const val TAG = "G1Nav"
        private const val CHANNEL_ID = "even_companion_walk_nav"
        private const val ACTION_STOP = "com.eddie.evencompanion.action.STOP_WALK_NAV"
        private const val EXTRA_REPLAY = "replay"
        private const val EXTRA_SPEED = "speed"
        private const val EXTRA_TITLE = "title"
        private const val INTERVAL_MS = 1000L
        // Distinct from 4102 companion, 4103 phone capture, 4104 GPS trace.
        private const val NOTIFICATION_ID = 4105

        fun start(context: Context, replay: String?, speed: Double, title: String?) {
            val i = Intent(context, NavLocationService::class.java).apply {
                if (!replay.isNullOrEmpty()) putExtra(EXTRA_REPLAY, replay)
                putExtra(EXTRA_SPEED, speed)
                if (title != null) putExtra(EXTRA_TITLE, title)
            }
            ContextCompat.startForegroundService(context, i)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, NavLocationService::class.java))
        }
    }
}

/**
 * Bridge between Android and the Dart walking navigator: one event stream
 * (fixes, service events, shared destinations, debug trips) and a pending
 * share held until Dart starts listening, so a cold start from a Google Maps
 * share is not lost.
 */
object NavBridge {
    const val EVENT_NAV = "eventNav"
    private const val ACTION_DEBUG = "com.eddie.evencompanion.NAV_TRIP"

    @Volatile
    private var sink: EventSink? = null
    private val pending = mutableListOf<Map<String, Any?>>()
    private val main = Handler(Looper.getMainLooper())
    private var debugRegistered = false

    fun attach(s: EventSink?) {
        main.post {
            sink = s
            if (s != null) {
                pending.forEach { s.success(it) }
                pending.clear()
            }
        }
    }

    fun detach() = main.post { sink = null }

    /** Fixes are dropped while Dart is not listening; anything else is queued. */
    fun emit(event: Map<String, Any?>) {
        main.post {
            val s = sink
            if (s != null) {
                s.success(event)
            } else if (event["kind"] != "fix") {
                pending.add(event)
            }
        }
    }

    /** ACTION_SEND text/plain, e.g. a Google Maps share. */
    fun handleIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type?.startsWith("text/") != true) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
        Log.i(NavLocationService.TAG, "shared text received (${text.length} chars)")
        emit(mapOf("kind" to "share", "text" to text))
    }

    /**
     * Debuggable builds only:
     * Bring the app to the front first (Android 14 refuses a background location FGS):
     *   adb shell am start -n com.eddie.evencompanion/.MainActivity
     *   adb shell am broadcast -p com.eddie.evencompanion -a com.eddie.evencompanion.NAV_TRIP \
     *     --es dest "lat,lon" [--es origin "lat,lon"] [--es replay trace.csv] [--ef speed 1] \
     *     [--es cmd stop]
     */
    fun registerDebugReceiver(activity: Activity) {
        val debuggable = (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable || debugRegistered) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                emit(
                    mapOf(
                        "kind" to "debugTrip",
                        "cmd" to (intent.getStringExtra("cmd") ?: "start"),
                        "dest" to intent.getStringExtra("dest"),
                        "origin" to intent.getStringExtra("origin"),
                        "replay" to intent.getStringExtra("replay"),
                        "speed" to intent.getFloatExtra("speed", 1f).toDouble(),
                    )
                )
            }
        }
        val filter = IntentFilter(ACTION_DEBUG)
        val ctx = activity.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            ctx.registerReceiver(receiver, filter)
        }
        debugRegistered = true
        Log.i(NavLocationService.TAG, "NAV_TRIP debug receiver registered")
    }
}
