package com.example.demo_ai_even.service

import android.content.Context
import android.content.ContentValues
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
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

        val captureDir = File(appContext.cacheDir, "capture-temp").apply { mkdirs() }
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

        val fileName = "capture_${
            SimpleDateFormat("yyyyMMdd_HHmmss", Locale.UK).format(Date())
        }.wav"

        val savedLocation = saveWaveToPublicRecordings(
            pcmFile = pcmTempFile ?: return mapOf("success" to false),
            fileName = fileName,
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
                writeWaveFile(pcmFile, output)
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
        pcmStream?.flush()
        pcmStream?.close()
        pcmStream = null
        pcmTempFile?.delete()
        pcmTempFile = null
        pcmBytesWritten = 0L
        recordingStartedAtMs = 0L
    }

    private fun saveWaveToPublicRecordings(pcmFile: File, fileName: String): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/wav")
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                "${Environment.DIRECTORY_RECORDINGS}/Even Companion",
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val resolver = appContext.contentResolver
        val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: return null

        return try {
            resolver.openOutputStream(uri)?.use { output ->
                writeWaveFile(pcmFile, output)
            } ?: throw IOException("Failed to open MediaStore output stream")

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            null
        }
    }

    private fun writeWaveFile(pcmFile: File, output: OutputStream) {
        val totalAudioLen = pcmFile.length()
        output.write(buildWaveHeader(totalAudioLen))
        FileInputStream(pcmFile).use { input ->
            input.copyTo(output)
        }

        if (output is FileOutputStream) {
            output.fd.sync()
        }
    }

    private fun buildWaveHeader(totalAudioLen: Long): ByteArray {
        val totalDataLen = totalAudioLen + 36
        val byteRate = SAMPLE_RATE * CHANNEL_COUNT * BITS_PER_SAMPLE / 8
        val blockAlign = CHANNEL_COUNT * BITS_PER_SAMPLE / 8

        return ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII))
            putInt(totalDataLen.toInt())
            put("WAVE".toByteArray(Charsets.US_ASCII))
            put("fmt ".toByteArray(Charsets.US_ASCII))
            putInt(16)
            putShort(1)
            putShort(CHANNEL_COUNT.toShort())
            putInt(SAMPLE_RATE)
            putInt(byteRate)
            putShort(blockAlign.toShort())
            putShort(BITS_PER_SAMPLE.toShort())
            put("data".toByteArray(Charsets.US_ASCII))
            putInt(totalAudioLen.toInt())
        }.array()
    }
}
