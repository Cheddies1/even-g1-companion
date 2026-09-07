package com.eddie.evencompanion.service

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Singleton recorder that captures audio from the phone's own microphone using
 * [AudioRecord], writes raw PCM to a temporary file, and frames it as a WAV
 * on stop. This is the phone-mic sibling of [GlassesCaptureRecorder] which
 * receives PCM pushed in over BLE instead of reading a mic.
 *
 * The audio format is fixed at 16 kHz mono 16-bit PCM, matching the glasses
 * mic and [WavRecordingStore] constants. Uses
 * [MediaRecorder.AudioSource.VOICE_RECOGNITION] as the source because it leaves
 * Android's own noise suppression and AGC in a predictable state for speech,
 * unlike MIC or VOICE_COMMUNICATION which may apply aggressive echo cancellation
 * tuned for calls.
 */
object PhoneCaptureRecorder {
    private lateinit var appContext: Context

    @Volatile
    var isRecording: Boolean = false
        private set

    @Volatile
    private var pcmBytesWritten: Long = 0L
    private var recordingStartedAtMs: Long = 0L
    private var tempPcmFile: File? = null
    private var pcmStream: FileOutputStream? = null
    private var readThread: Thread? = null
    private var audioRecord: AudioRecord? = null
    private val streamLock = Any()

    /**
     * How long teardown waits for the read thread to exit. Generous relative
     * to one read cycle at 16 kHz; if it ever expires the thread is abandoned
     * rather than blocking the caller, and the guarded writes mean an
     * abandoned thread cannot corrupt a closed stream.
     */
    private const val READ_THREAD_JOIN_TIMEOUT_MS = 2000L

    /** Read buffer as a multiple of the platform minimum. */
    private const val BUFFER_SIZE_MULTIPLIER = 4

    /**
     * Initialize the recorder with the application context. Must be called
     * before any other methods. The context is retained as the application
     * context to avoid holding a reference to an Activity.
     */
    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /**
     * Starts recording audio from the phone's microphone.
     *
     * Uses [MediaRecorder.AudioSource.VOICE_RECOGNITION] as the source because
     * it leaves Android's own noise suppression and AGC in a predictable state
     * for speech, unlike MIC or VOICE_COMMUNICATION which may apply aggressive
     * echo cancellation tuned for calls.
     *
     * The read buffer is set to four times the minimum reported by
     * [AudioRecord.getMinBufferSize] to avoid dropping samples when the read
     * thread is briefly descheduled.
     *
     * Fails (false) when the context is not initialized, when the device
     * rejects the audio config, or when AudioRecord does not reach
     * STATE_INITIALIZED - which is also what a missing RECORD_AUDIO grant
     * looks like, since AudioRecord reports that as a bad state rather than
     * a SecurityException. An already-running recording is a no-op returning
     * true, so a double tap cannot split one recording into two files.
     */
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

        val sampleRate = WavRecordingStore.SAMPLE_RATE
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT

        val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        if (minBufferSize == AudioRecord.ERROR || minBufferSize == AudioRecord.ERROR_BAD_VALUE) {
            android.util.Log.w("GlanceAssistant", "Recorder start failed: invalid buffer size")
            return false
        }

        // Use a read buffer several times the minimum to avoid dropping samples
        val readBufferSize = minBufferSize * BUFFER_SIZE_MULTIPLIER

        val audioSource = MediaRecorder.AudioSource.VOICE_RECOGNITION
        // The constructor throws IllegalArgumentException on a config the
        // device rejects, so it is caught here rather than propagating out of
        // start() - callers treat a false return as "could not record", and a
        // thrown exception would cross the method channel as a crash instead.
        val record = try {
            AudioRecord(audioSource, sampleRate, channelConfig, audioFormat, readBufferSize)
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder start failed: AudioRecord rejected config", e)
            return false
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            android.util.Log.w("GlanceAssistant", "Recorder start failed: audio record not initialized - likely permission issue")
            record.release()
            return false
        }

        val captureDir = File(appContext.cacheDir, "phone-capture-temp").apply { mkdirs() }
        tempPcmFile = File(captureDir, "phone_capture_tmp.pcm")

        try {
            pcmStream = FileOutputStream(tempPcmFile, false)
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder start failed: unable to create temp file", e)
            record.release()
            tempPcmFile = null
            return false
        }

        recordingStartedAtMs = System.currentTimeMillis()
        pcmBytesWritten = 0L
        isRecording = true
        audioRecord = record

        try {
            record.startRecording()
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder start failed: unable to start recording", e)
            record.release()
            audioRecord = null
            runCatching { pcmStream?.close() }
            pcmStream = null
            tempPcmFile?.delete()
            tempPcmFile = null
            isRecording = false
            return false
        }

        readThread = Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            val buffer = ByteArray(readBufferSize)
            while (isRecording) {
                val readBytes = record.read(buffer, 0, buffer.size)
                if (readBytes < 0) {
                    // stopAndSave/cancel clear isRecording and then call stop(),
                    // which makes the pending read return ERROR_INVALID_OPERATION.
                    // That is the expected way this loop unblocks, so only a
                    // negative read while still recording is a real fault.
                    if (isRecording) {
                        android.util.Log.w("GlanceAssistant", "Recorder read error: $readBytes")
                    }
                    break
                }
                synchronized(streamLock) {
                    try {
                        pcmStream?.write(buffer, 0, readBytes)
                        pcmBytesWritten += readBytes.toLong()
                    } catch (e: Exception) {
                        // Count only what actually reached the file, so
                        // pcmBytes never overstates the saved audio.
                        android.util.Log.w("GlanceAssistant", "Recorder stream write failed", e)
                    }
                }
            }
        }, "phone-capture-read")

        readThread?.start()

        return true
    }

    /**
     * Stops the mic, drains the read thread and closes the PCM stream, in
     * that order. Both [stopAndSave] and [cancel] go through here so the
     * two teardown paths cannot drift apart.
     *
     * Order matters. `isRecording` is already false by the time this runs,
     * so `stop()` unblocks the pending `read()`; the join then guarantees no
     * sample is in flight before the stream closes, and the release happens
     * only after the thread that was reading from the AudioRecord is gone.
     * Every step is guarded so a failure part-way through still frees the
     * microphone - leaking it would block every later recording and every
     * glasses mic session too.
     */
    private fun teardownCapture() {
        val record = audioRecord

        try {
            record?.stop()
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder stop failed", e)
        }

        try {
            readThread?.join(READ_THREAD_JOIN_TIMEOUT_MS)
        } catch (e: InterruptedException) {
            android.util.Log.w("GlanceAssistant", "Recorder join interrupted", e)
            Thread.currentThread().interrupt()
        }
        readThread = null

        try {
            record?.release()
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder release failed", e)
        }
        audioRecord = null

        synchronized(streamLock) {
            try {
                pcmStream?.flush()
            } catch (e: Exception) {
                android.util.Log.w("GlanceAssistant", "Recorder flush failed", e)
            }
            try {
                pcmStream?.close()
            } catch (e: Exception) {
                android.util.Log.w("GlanceAssistant", "Recorder close failed", e)
            }
            pcmStream = null
        }
    }

    /**
     * Stops recording and saves the captured audio as a WAV file.
     *
     * The audio recording is stopped and the read thread joined before the PCM
     * stream is closed, to ensure no samples are in flight when the file is
     * processed. This prevents use-after-free issues with native AudioRecord
     * resources.
     *
     * The returned map contains keys that match those of
     * [GlassesCaptureRecorder.stopAndSave] for consistent Dart-side handling.
     * The temp file is deleted whether or not the save succeeded.
     */
    @Synchronized
    fun stopAndSave(): Map<String, Any> {
        if (!isRecording) {
            android.util.Log.i("GlanceAssistant", "Recorder stopAndSave ignored: not recording")
            return mapOf("success" to false)
        }

        isRecording = false

        teardownCapture()

        // Identical to GlassesCaptureRecorder's pattern on purpose: a
        // recording is a recording, and the source is not meant to be
        // visible in the list. Not an oversight.
        val fileName = "Capture-${SimpleDateFormat("yyyy-MM-dd-HH-mm", Locale.UK).format(Date())}.wav"

        // No skipBytes. The 200 ms startup trim GlassesCaptureRecorder
        // applies drops an artefact specific to the glasses LC3 stream;
        // AudioRecord has no equivalent, so trimming here would discard
        // 200 ms of real audio.
        val savedLocation = try {
            WavRecordingStore.saveWaveToPublicRecordings(
                context = appContext,
                pcmFile = tempPcmFile ?: return mapOf("success" to false),
                fileName = fileName,
            )
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder save failed", e)
            tempPcmFile?.delete()
            tempPcmFile = null
            return mapOf("success" to false)
        }

        // Handle the case where the helper returned null instead of throwing
        if (savedLocation == null) {
            android.util.Log.w("GlanceAssistant", "Recorder save failed: null Uri returned")
            try {
                tempPcmFile?.delete()
            } catch (e: Exception) {
                android.util.Log.w("GlanceAssistant", "Recorder temp file delete failed", e)
            }
            tempPcmFile = null
            return mapOf("success" to false)
        }

        try {
            tempPcmFile?.delete()
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder temp file delete failed", e)
        }
        tempPcmFile = null

        val durationMs = System.currentTimeMillis() - recordingStartedAtMs

        return mapOf(
            "success" to true,
            "path" to savedLocation.toString(),
            "fileName" to fileName,
            "pcmBytes" to pcmBytesWritten,
            "durationMs" to durationMs,
        )
    }

    /**
     * Cancels the current recording without saving.
     *
     * Safe to call when not recording. Releases the audio hardware and cleans
     * up temporary resources without publishing anything. Idempotent.
     */
    @Synchronized
    fun cancel() {
        isRecording = false

        teardownCapture()

        try {
            tempPcmFile?.delete()
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "Recorder temp file delete failed", e)
        }
        tempPcmFile = null
        pcmBytesWritten = 0L
        recordingStartedAtMs = 0L

        android.util.Log.i("GlanceAssistant", "Recorder cancelled")
    }

    /**
     * Returns the elapsed time in milliseconds since recording started.
     *
     * The value is derived from wall-clock time rather than audio sample counts,
     * so it is safe to poll for a UI timer while recording. Returns 0 if not
     * currently recording or if no start time is set.
     */
    val elapsedMs: Long
        get() = if (isRecording && recordingStartedAtMs != 0L) {
            System.currentTimeMillis() - recordingStartedAtMs
        } else {
            0L
        }
}
