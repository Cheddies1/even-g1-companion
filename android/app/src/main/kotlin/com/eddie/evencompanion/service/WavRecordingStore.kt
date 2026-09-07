package com.eddie.evencompanion.service

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * WAV framing and MediaStore publishing, shared by every recorder that
 * produces a saved recording.
 *
 * Extracted from [GlassesCaptureRecorder] when phone-mic capture was added
 * so both sources emit byte-identical WAVs into the same folder. Recorders
 * own the PCM source and the temp file; this object owns the header, the
 * copy, and the MediaStore row.
 *
 * The format is fixed at 16 kHz mono 16-bit LE. That is what the glasses mic
 * delivers over LC3, and [PhoneCaptureRecorder] matches it deliberately:
 * `Recording.duration` in Dart computes a fallback duration from file size
 * at 32 000 bytes/second, so a second sample rate would silently mis-report
 * durations for any file MediaStore has not yet indexed.
 */
internal object WavRecordingStore {
    const val SAMPLE_RATE = 16000
    const val CHANNEL_COUNT = 1
    const val BITS_PER_SAMPLE = 16
    const val BYTES_PER_SAMPLE_FRAME = CHANNEL_COUNT * BITS_PER_SAMPLE / 8

    /**
     * Subfolder of the public Recordings directory that holds every file this
     * app saves, from either microphone. Single source of truth: the save
     * path and the MediaStore list query both derive from it, so the two
     * cannot drift and silently stop finding each other's files.
     */
    const val SUBFOLDER = "Even Companion"

    /** `RELATIVE_PATH` value MediaStore stores on insert. */
    val relativePath: String
        get() = "${Environment.DIRECTORY_RECORDINGS}/$SUBFOLDER"

    /** Same path with the trailing slash MediaStore uses when querying. */
    val relativePathForQuery: String
        get() = "$relativePath/"

    /**
     * Frames [pcmFile] as a WAV and publishes it to
     * `Recordings/Even Companion/[fileName]` via MediaStore. Writes with
     * `IS_PENDING` set so no other app sees a half-written file, and deletes
     * the row if the copy throws. Returns the content URI, or null on
     * failure.
     *
     * [skipBytes] drops that many bytes off the front of the PCM before
     * framing, for recorders that need to trim a startup artefact. Rounded
     * down to a whole sample frame.
     */
    fun saveWaveToPublicRecordings(
        context: Context,
        pcmFile: File,
        fileName: String,
        skipBytes: Long = 0L,
    ): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val resolver = context.contentResolver
        val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: return null

        return try {
            resolver.openOutputStream(uri)?.use { output ->
                writeWaveFile(pcmFile = pcmFile, output = output, skipBytes = skipBytes)
            } ?: throw IOException("Failed to open MediaStore output stream")

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            uri
        } catch (e: Exception) {
            android.util.Log.w("GlanceAssistant", "saveWaveToPublicRecordings failed", e)
            resolver.delete(uri, null, null)
            null
        }
    }

    /**
     * Writes a 44-byte WAV header followed by the body of [pcmFile] to
     * [output], skipping [skipBytes] from the front of the PCM.
     */
    fun writeWaveFile(
        pcmFile: File,
        output: OutputStream,
        skipBytes: Long = 0L,
    ) {
        val availableAudioLen = pcmFile.length()
        val safeSkipBytes = skipBytes
            .coerceAtLeast(0L)
            .coerceAtMost(availableAudioLen)
            .let { it - (it % BYTES_PER_SAMPLE_FRAME) }
        val totalAudioLen = availableAudioLen - safeSkipBytes

        output.write(buildWaveHeader(totalAudioLen))
        FileInputStream(pcmFile).use { input ->
            if (safeSkipBytes > 0L) {
                input.skipNBytes(safeSkipBytes)
            }
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
