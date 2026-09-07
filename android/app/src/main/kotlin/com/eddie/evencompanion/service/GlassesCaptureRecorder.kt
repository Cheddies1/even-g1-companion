package com.eddie.evencompanion.service

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object GlassesCaptureRecorder {
    /**
     * The first 200 ms of the glasses LC3 stream carries a startup artefact,
     * so it is trimmed off before framing. Specific to this transport -
     * [PhoneCaptureRecorder] passes no trim because AudioRecord has no
     * equivalent and dropping 200 ms there would lose real audio.
     */
    private const val CAPTURE_STARTUP_TRIM_MS = 200
    private const val CAPTURE_STARTUP_TRIM_BYTES =
        WavRecordingStore.SAMPLE_RATE *
            WavRecordingStore.BYTES_PER_SAMPLE_FRAME *
            CAPTURE_STARTUP_TRIM_MS / 1000

    private lateinit var appContext: Context
    private var pcmTempFile: File? = null
    private var pcmStream: FileOutputStream? = null
    private var recordingStartedAtMs: Long = 0L
    private var pcmBytesWritten: Long = 0L

    @Volatile
    var isRecording: Boolean = false
        private set

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    @Synchronized
    fun start(): Boolean {
        if (::appContext.isInitialized.not()) {
            android.util.Log.i("GlanceAssistant", "Recorder start failed: appContext not initialized")
            return false
        }
        if (isRecording) {
            android.util.Log.i("GlanceAssistant", "Recorder start ignored: already recording")
            return true
        }

        val captureDir = File(appContext.cacheDir, "capture-temp").apply { mkdirs() }
        pcmTempFile = File(captureDir, "capture_tmp.pcm")
        pcmStream = FileOutputStream(pcmTempFile, false)
        recordingStartedAtMs = System.currentTimeMillis()
        pcmBytesWritten = 0L
        isRecording = true
        android.util.Log.i("GlanceAssistant", "Recorder started")
        return true
    }

    @Synchronized
    fun appendPcmData(pcmData: ByteArray) {
        if (!isRecording) {
            return
        }
        if (pcmBytesWritten == 0L) {
            android.util.Log.i("GlanceAssistant", "PCM stream started: first chunk bytes=${pcmData.size}")
        }
        pcmStream?.write(pcmData)
        pcmBytesWritten += pcmData.size.toLong()
    }

    @Synchronized
    fun stopAndSave(): Map<String, Any> {
        if (!isRecording) {
            android.util.Log.i("GlanceAssistant", "Recorder stopAndSave ignored: not recording")
            return mapOf("success" to false)
        }

        isRecording = false
        pcmStream?.flush()
        pcmStream?.close()
        pcmStream = null

        val fileName = "Capture-${
            SimpleDateFormat("yyyy-MM-dd-HH-mm", Locale.UK).format(Date())
        }.wav"

        val savedLocation = WavRecordingStore.saveWaveToPublicRecordings(
            context = appContext,
            pcmFile = pcmTempFile ?: return mapOf("success" to false),
            fileName = fileName,
            skipBytes = CAPTURE_STARTUP_TRIM_BYTES.toLong(),
        ) ?: run {
            pcmTempFile?.delete()
            pcmTempFile = null
            return mapOf("success" to false)
        }

        pcmTempFile?.delete()
        pcmTempFile = null

        return mapOf(
            "success" to true,
            "path" to savedLocation.toString(),
            "fileName" to fileName,
            "pcmBytes" to pcmBytesWritten,
            "durationMs" to (System.currentTimeMillis() - recordingStartedAtMs),
        )
    }

    @Synchronized
    fun stopToTemp(): Map<String, Any> {
        if (!isRecording) {
            android.util.Log.i("GlanceAssistant", "Recorder stopToTemp ignored: not recording")
            return mapOf("success" to false)
        }

        isRecording = false
        pcmStream?.flush()
        pcmStream?.close()
        pcmStream = null

        val pcmFile = pcmTempFile ?: return mapOf("success" to false)
        val tempDir = File(appContext.cacheDir, "chat-temp").apply { mkdirs() }
        val fileName = "chat_${
            SimpleDateFormat("yyyyMMdd_HHmmss", Locale.UK).format(Date())
        }.wav"
        val wavFile = File(tempDir, fileName)

        return try {
            FileOutputStream(wavFile, false).use { output ->
                WavRecordingStore.writeWaveFile(pcmFile, output)
            }
            pcmFile.delete()
            pcmTempFile = null

            mapOf(
                "success" to true,
                "localPath" to wavFile.absolutePath,
                "fileName" to fileName,
                "pcmBytes" to pcmBytesWritten,
                "durationMs" to (System.currentTimeMillis() - recordingStartedAtMs),
            )
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder stopToTemp failed", e)
            wavFile.delete()
            pcmFile.delete()
            pcmTempFile = null
            mapOf(
                "success" to false,
                "error" to (e.message ?: "temp capture failed"),
            )
        }
    }

    @Synchronized
    fun cancel() {
        isRecording = false
        android.util.Log.i("GlanceAssistant", "Recorder cancelled")
        pcmStream?.flush()
        pcmStream?.close()
        pcmStream = null
        pcmTempFile?.delete()
        pcmTempFile = null
        pcmBytesWritten = 0L
        recordingStartedAtMs = 0L
    }

    /**
     * Lists every recording this app has saved under
     * `Recordings/Even Companion/`. Reads MediaStore directly so the list
     * always reflects what is on disk — files deleted via the system Files
     * app vanish from the list on next refresh.
     *
     * Returned items are sorted most-recent first. Each entry contains:
     *  - `id` (Long): MediaStore row id (useful for follow-up operations).
     *  - `uri` (String): full content:// URI suitable for Share / Open.
     *  - `fileName` (String): the display name (`Capture-…-….wav` or a
     *    renamed prefix the user has set).
     *  - `dateAddedMs` (Long): epoch millis when the file was added to the
     *    MediaStore (matches the save time).
     *  - `durationMs` (Long): audio duration in milliseconds. 0 if the
     *    MediaStore has not yet indexed it.
     *  - `sizeBytes` (Long): WAV size on disk.
     */
    fun listRecordings(): List<Map<String, Any>> {
        if (::appContext.isInitialized.not()) {
            return emptyList()
        }
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.SIZE,
            MediaStore.Audio.Media.DURATION,
        )
        // Filter to files under our subfolder of the public Recordings
        // directory. Derived from WavRecordingStore rather than rebuilt here,
        // so the query can never look somewhere the save path does not write.
        val expectedPath = WavRecordingStore.relativePathForQuery
        val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val selection: String?
        val selectionArgs: Array<String>?
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
            selectionArgs = arrayOf(expectedPath)
        } else {
            selection = null
            selectionArgs = null
        }
        val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC"

        val out = mutableListOf<Map<String, Any>>()
        appContext.contentResolver.query(
            collection,
            projection,
            selection,
            selectionArgs,
            sortOrder,
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val dateCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val durationCol = cursor.getColumnIndex(MediaStore.Audio.Media.DURATION)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val uri = ContentUris.withAppendedId(collection, id)
                val fileName = cursor.getString(nameCol) ?: continue
                val dateAddedSeconds = cursor.getLong(dateCol)
                val sizeBytes = cursor.getLong(sizeCol)
                val durationMs = if (durationCol >= 0) cursor.getLong(durationCol) else 0L
                out.add(
                    mapOf(
                        "id" to id,
                        "uri" to uri.toString(),
                        "fileName" to fileName,
                        "dateAddedMs" to (dateAddedSeconds * 1000L),
                        "durationMs" to durationMs,
                        "sizeBytes" to sizeBytes,
                    )
                )
            }
        }
        return out
    }

    /**
     * Renames a recording's display name in MediaStore. Caller passes the
     * full target display name (typically a prefix-swap performed in Dart,
     * preserving the timestamp suffix). Returns `true` if MediaStore reports
     * a row update. The on-disk file is renamed by MediaStore atomically.
     */
    fun renameRecording(uriString: String, newDisplayName: String): Boolean {
        if (::appContext.isInitialized.not()) {
            return false
        }
        val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: return false
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, newDisplayName)
        }
        return try {
            appContext.contentResolver.update(uri, values, null, null) > 0
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "renameRecording failed: ${e.message}")
            false
        }
    }

    /**
     * Deletes a recording. Removes the MediaStore row and the underlying
     * file. Returns `true` if MediaStore confirms the delete.
     */
    fun deleteRecording(uriString: String): Boolean {
        if (::appContext.isInitialized.not()) {
            return false
        }
        val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: return false
        return try {
            appContext.contentResolver.delete(uri, null, null) > 0
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "deleteRecording failed: ${e.message}")
            false
        }
    }

    /**
     * Launches the system share chooser for a recording. Must be called with
     * an Activity context so the chooser intent can be started. The caller
     * (BleMethodChannel) supplies the MainActivity.
     */
    fun shareRecording(activityContext: Context, uriString: String, displayName: String?): Boolean {
        val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: return false
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "audio/wav"
            putExtra(Intent.EXTRA_STREAM, uri)
            if (!displayName.isNullOrBlank()) {
                putExtra(Intent.EXTRA_SUBJECT, displayName)
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            val chooser = Intent.createChooser(send, displayName ?: "Share recording")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activityContext.startActivity(chooser)
            true
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "shareRecording failed: ${e.message}")
            false
        }
    }
}
