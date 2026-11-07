package com.eddie.evencompanion.service

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.eddie.evencompanion.MainActivity
import com.eddie.evencompanion.R
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * Region builds on cartographer (plan region-sync, phase 3), Android side.
 *
 * Dart POSTs the build and hands the job id over. From then on the job lives
 * here: persisted in [RegionJobStore], polled by [RegionJobWorker] through
 * WorkManager (survives screen-off, Doze, process death and reboot), and
 * reported by a phone notification when it is done or failed. Builds can take
 * seconds or an hour; jobs persist on the server indefinitely, so polling
 * simply resumes after a disconnect.
 */
object RegionSync {
    const val TAG = "G1Regions"
    const val EVENT_REGIONS = "eventRegions"
    private const val ACTION_DEBUG = "com.eddie.evencompanion.REGION_SYNC"
    private const val CHANNEL_ID = "even_companion_region_sync"
    private const val WORK_PREFIX = "region-job-"
    private const val FIRST_POLL_S = 15L
    const val BACKOFF_S = 20L
    private const val OFFER_ID = 0x5259 // fixed: a newer offer replaces the last

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

    fun emit(event: Map<String, Any?>) {
        main.post {
            val s = sink
            // Progress ticks are only for an open page; outcomes and debug
            // requests wait for Dart to attach.
            if (s != null) s.success(event) else if (event["kind"] != "jobUpdate") pending.add(event)
        }
    }

    /** Persist and start polling a build the server accepted. */
    fun watch(context: Context, baseUrl: String, jobId: String, regionId: String, name: String) {
        RegionJobStore.put(context, RegionJobStore.Job(jobId, regionId, name, baseUrl, "queued", null))
        enqueue(context, jobId, FIRST_POLL_S)
        Log.i(TAG, "watching job $jobId ($regionId)")
    }

    /** Re-enqueue anything persisted but not scheduled (e.g. after a data clear of WorkManager). */
    fun resumeAll(context: Context) {
        RegionJobStore.all(context).forEach {
            WorkManager.getInstance(context)
                .enqueueUniqueWork(WORK_PREFIX + it.jobId, ExistingWorkPolicy.KEEP, request(it.jobId, 0))
        }
    }

    private fun enqueue(context: Context, jobId: String, delayS: Long) {
        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_PREFIX + jobId, ExistingWorkPolicy.REPLACE, request(jobId, delayS))
    }

    private fun request(jobId: String, delayS: Long) =
        OneTimeWorkRequestBuilder<RegionJobWorker>()
            .setInputData(workDataOf(RegionJobWorker.KEY_JOB to jobId))
            .setInitialDelay(delayS, TimeUnit.SECONDS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.LINEAR, BACKOFF_S, TimeUnit.SECONDS)
            .build()

    fun pendingForDart(context: Context): List<Map<String, Any?>> =
        RegionJobStore.all(context).map {
            mapOf("jobId" to it.jobId, "regionId" to it.regionId, "name" to it.name,
                "state" to it.state, "stage" to it.stage)
        }

    fun notifyFinished(context: Context, job: RegionJobStore.Job, ok: Boolean, reason: String?) {
        post(context, job.jobId.hashCode(),
            if (ok) "Region ready: ${job.name}" else "Region sync failed: ${job.name}",
            if (ok) "Walking routes are available in ${job.name}." else (reason ?: "Unknown failure"))
    }

    /**
     * Phase 4: a shared walk falls outside every synced region. The action
     * starts a build centred on ([lat], [lon]) without needing the app open:
     * [RegionOfferReceiver] -> [RegionBuildWorker] -> [watch].
     */
    fun offerSync(
        context: Context, baseUrl: String, lat: Double, lon: Double, name: String?, text: String,
    ) {
        val action = PendingIntent.getBroadcast(
            context, OFFER_ID,
            Intent(context, RegionOfferReceiver::class.java)
                .putExtra("baseUrl", baseUrl).putExtra("lat", lat).putExtra("lon", lon)
                .putExtra("name", name),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        post(context, OFFER_ID, "Sync this area?", text) {
            addAction(0, "Sync this area", action)
        }
        Log.i(TAG, "sync offered")
    }

    fun cancelOffer(context: Context) = NotificationManagerCompat.from(context).cancel(OFFER_ID)

    internal fun post(
        context: Context, id: Int, title: String, text: String,
        extra: NotificationCompat.Builder.() -> Unit = {},
    ) {
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(open)
            .apply(extra)
            .build()
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "notifications not permitted; dropped \"$title\"")
            return
        }
        NotificationManagerCompat.from(context).notify(id, n)
    }

    /** Builds started from the offer action, one at a time; never retried (POST is not idempotent). */
    internal fun enqueueBuild(context: Context, baseUrl: String, lat: Double, lon: Double, name: String?) {
        WorkManager.getInstance(context).enqueueUniqueWork(
            "region-build", ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<RegionBuildWorker>()
                .setInputData(workDataOf("baseUrl" to baseUrl, "lat" to lat, "lon" to lon, "name" to name))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build(),
        )
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val ch = NotificationChannel(CHANNEL_ID, "Region sync", NotificationManager.IMPORTANCE_DEFAULT)
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
    }

    /**
     * One fresh fix for "Sync current location". The app is in front when the
     * button is pressed, so no foreground service is needed. Falls back to the
     * last known fix if no fresh one arrives within 30 s.
     */
    @SuppressLint("MissingPermission")
    fun currentFix(context: Context, result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("no_permission", "ACCESS_FINE_LOCATION not granted", null)
            return
        }
        val lm = context.getSystemService(LocationManager::class.java)
        val provider =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                lm.allProviders.contains(LocationManager.FUSED_PROVIDER)
            ) LocationManager.FUSED_PROVIDER else LocationManager.GPS_PROVIDER
        var done = false
        fun reply(loc: android.location.Location?) {
            if (done) return
            done = true
            val l = loc ?: runCatching { lm.getLastKnownLocation(provider) }.getOrNull()
            if (l == null) result.error("no_fix", "no location fix", null)
            else result.success(mapOf("lat" to l.latitude, "lon" to l.longitude,
                "acc" to if (l.hasAccuracy()) l.accuracy.toDouble() else null))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val cancel = CancellationSignal()
            main.postDelayed({ cancel.cancel(); reply(null) }, 30_000)
            lm.getCurrentLocation(provider, cancel, context.mainExecutor) { reply(it) }
        } else {
            reply(null)
        }
    }

    /**
     * Debuggable builds only:
     *   adb shell am broadcast -p com.eddie.evencompanion -a com.eddie.evencompanion.REGION_SYNC \
     *     --es at "lat,lon" [--es name "Test"] [--ez pinned true]
     * Goes through the same Dart path as the button (POST, then this poller).
     */
    fun registerDebugReceiver(activity: Activity) {
        val debuggable = (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable || debugRegistered) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val parts = intent.getStringExtra("at")?.split(',')?.map { it.trim().toDoubleOrNull() }
                emit(mapOf(
                    "kind" to "debugSync",
                    "lat" to parts?.getOrNull(0),
                    "lon" to parts?.getOrNull(1),
                    "name" to intent.getStringExtra("name"),
                    "pinned" to intent.getBooleanExtra("pinned", false),
                ))
            }
        }
        val ctx = activity.applicationContext
        val filter = IntentFilter(ACTION_DEBUG)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            ctx.registerReceiver(receiver, filter)
        }
        debugRegistered = true
        Log.i(TAG, "REGION_SYNC debug receiver registered")
    }

    internal fun jobUrl(baseUrl: String, jobId: String) =
        "${baseUrl.trimEnd('/')}/v1/regions/jobs/${URLEncoder.encode(jobId, "UTF-8")}"
}

/** Builds the phone is waiting on, in SharedPreferences so they survive process death. */
object RegionJobStore {
    private const val PREFS = "region_jobs"

    data class Job(
        val jobId: String,
        val regionId: String,
        val name: String,
        val baseUrl: String,
        val state: String?,
        val stage: String?,
    ) {
        fun toJson(): String = JSONObject().apply {
            put("jobId", jobId); put("regionId", regionId); put("name", name)
            put("baseUrl", baseUrl); put("state", state ?: JSONObject.NULL); put("stage", stage ?: JSONObject.NULL)
        }.toString()

        companion object {
            fun fromJson(s: String): Job? = runCatching {
                val o = JSONObject(s)
                fun opt(k: String) = if (o.isNull(k)) null else o.optString(k).ifEmpty { null }
                Job(o.getString("jobId"), o.getString("regionId"), o.getString("name"),
                    o.getString("baseUrl"), opt("state"), opt("stage"))
            }.getOrNull()
        }
    }

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun put(c: Context, job: Job) = prefs(c).edit().putString(job.jobId, job.toJson()).apply()

    @Synchronized
    fun get(c: Context, jobId: String): Job? = prefs(c).getString(jobId, null)?.let { Job.fromJson(it) }

    @Synchronized
    fun remove(c: Context, jobId: String) = prefs(c).edit().remove(jobId).apply()

    @Synchronized
    fun all(c: Context): List<Job> =
        prefs(c).all.values.mapNotNull { (it as? String)?.let(Job::fromJson) }
}

/**
 * One poll of `GET /v1/regions/jobs/{id}`. Still running or unreachable ->
 * `retry()` (linear backoff from [RegionSync.BACKOFF_S]); done/failed or an
 * unknown job -> notify, drop from the store, `success()`.
 */
class RegionJobWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    override fun doWork(): Result {
        val jobId = inputData.getString(KEY_JOB) ?: return Result.failure()
        val job = RegionJobStore.get(applicationContext, jobId) ?: return Result.success()
        val conn = (URL(RegionSync.jobUrl(job.baseUrl, jobId)).openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 20_000
        }
        try {
            val code = conn.responseCode
            val body = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code == 404) {
                finish(job, ok = false, reason = "The server no longer knows this build (unknown_job).", state = "failed")
                return Result.success()
            }
            if (code != 200) {
                Log.w(RegionSync.TAG, "job $jobId poll HTTP $code; retrying")
                return Result.retry()
            }
            val o = JSONObject(body)
            val state = o.optString("state")
            val stage = if (o.isNull("stage")) null else o.optString("stage")
            when (state) {
                "done" -> finish(job, ok = true, reason = null, state = state)
                "failed" -> finish(job, ok = false,
                    reason = if (o.isNull("reason")) null else o.optString("reason"), state = state)
                else -> {
                    if (state != job.state || stage != job.stage) {
                        RegionJobStore.put(applicationContext, job.copy(state = state, stage = stage))
                        RegionSync.emit(mapOf("kind" to "jobUpdate", "jobId" to jobId))
                    }
                    Log.i(RegionSync.TAG, "job $jobId $state ${stage ?: ""} (attempt $runAttemptCount)")
                    return Result.retry()
                }
            }
            return Result.success()
        } catch (e: Exception) {
            Log.w(RegionSync.TAG, "job $jobId poll failed: $e; retrying")
            return Result.retry()
        } finally {
            conn.disconnect()
        }
    }

    private fun finish(job: RegionJobStore.Job, ok: Boolean, reason: String?, state: String) {
        Log.i(RegionSync.TAG, "job ${job.jobId} $state ${reason ?: ""}")
        RegionJobStore.remove(applicationContext, job.jobId)
        RegionSync.notifyFinished(applicationContext, job, ok, reason)
        RegionSync.emit(mapOf("kind" to "jobFinished", "jobId" to job.jobId,
            "regionId" to job.regionId, "state" to state, "reason" to reason))
    }

    companion object {
        const val KEY_JOB = "jobId"
    }
}

/** The "Sync this area" action on the phase 4 offer notification. */
class RegionOfferReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val baseUrl = intent.getStringExtra("baseUrl") ?: return
        if (!intent.hasExtra("lat") || !intent.hasExtra("lon")) return
        RegionSync.cancelOffer(context)
        RegionSync.enqueueBuild(context.applicationContext, baseUrl,
            intent.getDoubleExtra("lat", 0.0), intent.getDoubleExtra("lon", 0.0),
            intent.getStringExtra("name"))
        Log.i(RegionSync.TAG, "sync accepted from the offer")
    }
}

/**
 * `POST /v1/regions` for an offer the user accepted, then hands the job to
 * [RegionJobWorker]. A failed or lost POST is reported, not retried: the
 * contract says to check the region list before trying again.
 */
class RegionBuildWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val baseUrl = inputData.getString("baseUrl") ?: return Result.failure()
        val lat = inputData.getDouble("lat", Double.NaN)
        val lon = inputData.getDouble("lon", Double.NaN)
        if (lat.isNaN() || lon.isNaN()) return Result.failure()
        // The shared place name; the server caps names at 100 characters.
        val name = inputData.getString("name")?.trim()?.take(100)?.ifEmpty { null }
        val ctx = applicationContext
        val conn = (URL("${baseUrl.trimEnd('/')}/v1/regions").openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 30_000
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
        }
        try {
            conn.outputStream.use {
                val req = JSONObject().put("lat", lat).put("lon", lon).put("pinned", false)
                if (name != null) req.put("name", name)
                it.write(req.toString().toByteArray())
            }
            val code = conn.responseCode
            val body = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            val o = runCatching { JSONObject(body) }.getOrNull()
            if (code == 202 && o != null && o.has("job_id") && o.has("region_id")) {
                val regionId = o.getString("region_id")
                val label = name ?: regionId
                RegionSync.watch(ctx, baseUrl, o.getString("job_id"), regionId, label)
                RegionSync.emit(mapOf("kind" to "jobUpdate", "jobId" to o.getString("job_id")))
                RegionSync.post(ctx, OFFER_RESULT_ID, "Syncing area: $label",
                    "You will get a notification when it is ready. Share the walk again then.")
                return Result.success()
            }
            val error = o?.optString("error")?.ifEmpty { null } ?: "http_$code"
            Log.w(RegionSync.TAG, "offer build rejected: $code $error")
            RegionSync.post(ctx, OFFER_RESULT_ID, "Region sync not started", when (error) {
                "region_exists" -> "That spot is already inside a synced region. Share the walk again."
                "build_busy" -> "Another region is building. Share the walk again when it is done."
                else -> "Server error ($error)."
            })
        } catch (e: Exception) {
            Log.w(RegionSync.TAG, "offer build request failed: $e")
            RegionSync.post(ctx, OFFER_RESULT_ID, "Region sync: no reply",
                "Check the regions list before trying again; the build may have started.")
        } finally {
            conn.disconnect()
        }
        return Result.success()
    }

    companion object {
        private const val OFFER_RESULT_ID = 0x525A
    }
}
