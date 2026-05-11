package com.eddie.evencompanion.bluetooth

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Accumulates the chunked `0x1e c8 ...` audio stream that the G1 firmware pushes
 * immediately after a right-side `0x21` QuickNote release.
 *
 * ## Protocol summary (from docs/FINDINGS-quicknote.md)
 *
 * - `0x21` RX (right side, 15 bytes) — opens the buffer and captures the 8-byte
 *   note-UID tail (bytes 7..14).
 * - `0x1e` RX while open — if byte 1 is in the audio-chunk range (`0x40..0xc8`)
 *   AND the frame is longer than 10 bytes, the payload after the 10-byte header is
 *   appended.  Any other `0x1e` (e.g. the post-stream `1e 06 ...`) flushes.
 * - Any non-`0x1e` opcode arriving while open — defensive flush.
 * - Timeout (500 ms of silence) — safety-net flush.
 *
 * ## Threading
 *
 * All methods must be called from the same coroutine scope (the `mainScope` already
 * used in `BleManager.onCharacteristicChanged`). No locking is needed.
 *
 * ## Flush callback
 *
 * [onFlush] is invoked exactly once per capture cycle, with:
 * - [noteUid] — the 8 bytes from the `0x21` payload (bytes 7..14), for future
 *   note management (delete / reorder on the glasses).
 * - [audioPayload] — the concatenated stripped payload bytes from all audio chunks.
 *   May be empty if no audio chunks arrived before the flush (e.g. a very short press
 *   or firmware error).  The receiver must not assume a minimum length.
 *
 * Task #3 (LC3 decode) will consume [audioPayload]. This class does not decode it.
 */
class QuickNoteAudioBuffer(
    private val scope: CoroutineScope,
    private val onFlush: (noteUid: ByteArray, audioPayload: ByteArray) -> Unit,
) {
    companion object {
        private const val LOG_TAG = "QuickNoteAudioBuffer"

        /** Bytes 7..14 of the `0x21` payload that carry the note UID. */
        private const val NOTE_UID_START = 7
        private const val NOTE_UID_END = 15   // exclusive

        /** Strip the first 10 bytes of every audio chunk (the fixed header). */
        private const val AUDIO_HEADER_LEN = 10

        /**
         * Inclusive byte-1 range that identifies an audio chunk.
         * Full chunks have byte 1 = `0xc8` (200). The trailing chunk is shorter
         * (e.g. `0x5a` = 90).  The lower bound `0x40` gives headroom for future
         * shorter trailing chunks while excluding the status sub-codes (e.g. `0x06`).
         */
        private const val AUDIO_CHUNK_BYTE1_MIN = 0x40
        private const val AUDIO_CHUNK_BYTE1_MAX = 0xc8

        /** Safety-net flush after this many ms of silence while the buffer is open. */
        private const val WATCHDOG_TIMEOUT_MS = 500L
    }

    var isOpen: Boolean = false
        private set

    private var noteUid: ByteArray = ByteArray(0)
    private val audioAccumulator = mutableListOf<ByteArray>()
    private var watchdogJob: Job? = null

    /**
     * Opens a new capture cycle triggered by a right-side `0x21` notification.
     *
     * If a prior cycle is still open (edge case — two rapid `0x21` notifications),
     * the previous buffer is flushed before the new one opens.
     *
     * @param frame The full 15-byte `0x21` notification value.
     */
    fun openOnCmd21(frame: ByteArray) {
        if (isOpen) {
            Log.w(LOG_TAG, "openOnCmd21: buffer was already open — flushing stale cycle")
            flush(reason = "stale-open-on-new-0x21")
        }

        if (frame.size < NOTE_UID_END) {
            Log.w(LOG_TAG, "openOnCmd21: frame too short to extract note UID (len=${frame.size}), discarding")
            return
        }

        noteUid = frame.copyOfRange(NOTE_UID_START, NOTE_UID_END)
        audioAccumulator.clear()
        isOpen = true

        Log.i(LOG_TAG, "Buffer opened — noteUid=${noteUid.toHexString()}")
        resetWatchdog()
    }

    /**
     * Processes a `0x1e` notification frame while the buffer is open.
     *
     * Audio chunks are stripped and appended. Any non-audio `0x1e` triggers a flush.
     * Call this only when [isOpen] is true.
     *
     * @param frame The full `0x1e` notification value.
     */
    fun onCmd1e(frame: ByteArray) {
        if (!isOpen) return

        val byte1 = frame[1].toInt() and 0xff
        val isAudioChunk = byte1 in AUDIO_CHUNK_BYTE1_MIN..AUDIO_CHUNK_BYTE1_MAX
                && frame.size > AUDIO_HEADER_LEN

        if (isAudioChunk) {
            val payload = frame.copyOfRange(AUDIO_HEADER_LEN, frame.size)
            audioAccumulator.add(payload)
            Log.v(LOG_TAG, "Audio chunk appended: byte1=0x${byte1.toString(16)} payloadBytes=${payload.size} totalChunks=${audioAccumulator.size}")
            resetWatchdog()
        } else {
            Log.i(LOG_TAG, "Non-audio 0x1e received (byte1=0x${byte1.toString(16)} len=${frame.size}) — flushing")
            flush(reason = "non-audio-0x1e")
        }
    }

    /**
     * Flushes the buffer defensively when a non-`0x1e` opcode arrives while open.
     *
     * This covers the unlikely case of an unexpected opcode mid-stream.
     */
    fun onNonCmd1eWhileOpen() {
        if (!isOpen) return
        Log.i(LOG_TAG, "Non-0x1e opcode arrived while buffer open — defensive flush")
        flush(reason = "non-0x1e-opcode")
    }

    // ----- Private -----

    private fun flush(reason: String) {
        cancelWatchdog()
        isOpen = false

        val combined = concatenate(audioAccumulator)
        val capturedUid = noteUid.copyOf()

        Log.i(LOG_TAG, "Flush($reason): noteUid=${capturedUid.toHexString()} chunks=${audioAccumulator.size} totalBytes=${combined.size}")

        audioAccumulator.clear()
        noteUid = ByteArray(0)

        onFlush(capturedUid, combined)
    }

    private fun resetWatchdog() {
        cancelWatchdog()
        watchdogJob = scope.launch {
            delay(WATCHDOG_TIMEOUT_MS)
            if (isOpen) {
                Log.w(LOG_TAG, "Watchdog triggered after ${WATCHDOG_TIMEOUT_MS}ms of silence")
                flush(reason = "watchdog-timeout")
            }
        }
    }

    private fun cancelWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = null
    }

    private fun concatenate(chunks: List<ByteArray>): ByteArray {
        val totalSize = chunks.sumOf { it.size }
        val result = ByteArray(totalSize)
        var offset = 0
        for (chunk in chunks) {
            chunk.copyInto(result, offset)
            offset += chunk.size
        }
        return result
    }

    private fun ByteArray.toHexString(): String =
        joinToString(" ") { it.toInt().and(0xff).toString(16).padStart(2, '0') }
}
