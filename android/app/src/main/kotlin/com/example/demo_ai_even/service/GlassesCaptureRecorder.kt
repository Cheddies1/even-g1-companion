package com.example.demo_ai_even.service

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object GlassesCaptureRecorder {
    private const val SAMPLE_RATE = 16000
    private const val CHANNEL_COUNT = 1
    private const val BITS_PER_SAMPLE = 16

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
            return false
        }
        if (isRecording) {
            return true
        }

        val baseDir = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        val captureDir = File(
            baseDir,
            "captures",
        ).apply { mkdirs() }
        pcmTempFile = File(captureDir, "capture_tmp.pcm")
        pcmStream = FileOutputStream(pcmTempFile, false)
        recordingStartedAtMs = System.currentTimeMillis()
        pcmBytesWritten = 0L
        isRecording = true
        return true
    }

    @Synchronized
    fun appendPcmData(pcmData: ByteArray) {
        if (!isRecording) {
            return
        }
        pcmStream?.write(pcmData)
        pcmBytesWritten += pcmData.size.toLong()
    }

    @Synchronized
    fun stopAndSave(): Map<String, Any> {
        if (!isRecording) {
            return mapOf("success" to false)
        }

        isRecording = false
        pcmStream?.flush()
        pcmStream?.close()
        pcmStream = null

        val baseDir = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        val captureDir = File(baseDir, "captures").apply { mkdirs() }
        val fileName = "capture_${
            SimpleDateFormat("yyyyMMdd_HHmmss", Locale.UK).format(Date())
        }.wav"
        val wavFile = File(captureDir, fileName)
        writeWaveFile(pcmTempFile ?: return mapOf("success" to false), wavFile)
        pcmTempFile?.delete()
        pcmTempFile = null

        return mapOf(
            "success" to true,
            "path" to wavFile.absolutePath,
            "fileName" to wavFile.name,
            "pcmBytes" to pcmBytesWritten,
            "durationMs" to (System.currentTimeMillis() - recordingStartedAtMs),
        )
    }

    @Synchronized
    fun cancel() {
        isRecording = false
        pcmStream?.flush()
        pcmStream?.close()
        pcmStream = null
        pcmTempFile?.delete()
        pcmTempFile = null
        pcmBytesWritten = 0L
        recordingStartedAtMs = 0L
    }

    private fun writeWaveFile(pcmFile: File, wavFile: File) {
        val totalAudioLen = pcmFile.length()
        val totalDataLen = totalAudioLen + 36
        val byteRate = SAMPLE_RATE * CHANNEL_COUNT * BITS_PER_SAMPLE / 8

        FileOutputStream(wavFile).use { output ->
            output.write(ByteArray(44))
            FileInputStream(pcmFile).use { input ->
                input.copyTo(output)
            }
        }

        RandomAccessFile(wavFile, "rw").use { raf ->
            raf.seek(0)
            raf.writeBytes("RIFF")
            raf.writeInt(Integer.reverseBytes(totalDataLen.toInt()))
            raf.writeBytes("WAVE")
            raf.writeBytes("fmt ")
            raf.writeInt(Integer.reverseBytes(16))
            raf.writeShort(java.lang.Short.reverseBytes(1.toShort()).toInt())
            raf.writeShort(
                java.lang.Short.reverseBytes(CHANNEL_COUNT.toShort()).toInt()
            )
            raf.writeInt(Integer.reverseBytes(SAMPLE_RATE))
            raf.writeInt(Integer.reverseBytes(byteRate))
            raf.writeShort(
                java.lang.Short.reverseBytes(
                    (CHANNEL_COUNT * BITS_PER_SAMPLE / 8).toShort()
                ).toInt()
            )
            raf.writeShort(
                java.lang.Short.reverseBytes(BITS_PER_SAMPLE.toShort()).toInt()
            )
            raf.writeBytes("data")
            raf.writeInt(Integer.reverseBytes(totalAudioLen.toInt()))
        }
    }
}
