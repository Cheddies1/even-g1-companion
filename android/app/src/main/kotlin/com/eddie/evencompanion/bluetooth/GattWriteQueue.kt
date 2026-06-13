package com.eddie.evencompanion.bluetooth

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Serialises GATT characteristic writes for one leg.
 *
 * Android allows a single in-flight write per [android.bluetooth.BluetoothGatt].
 * Before this queue existed, writes were fired directly; a busy stack returned an
 * error code that every caller discarded, so bursts (nav bootstrap, text
 * multi-packs, heartbeats landing mid-burst) silently lost packets and surfaced
 * as request timeouts in Dart — feeding false leg-degradation. All writes for a
 * leg now flow through here, one at a time.
 *
 * ## Threading
 *
 * All queue state is confined to [scope] (the main dispatcher). Public methods
 * may be called from any thread; they hop onto [scope].
 *
 * ## Completion model
 *
 * The next write is submitted when `onCharacteristicWrite` reports the previous
 * one done. Some stacks do not reliably deliver that callback for
 * `WRITE_TYPE_NO_RESPONSE`, so a [WRITE_COMPLETE_TIMEOUT_MS] watchdog advances
 * the queue rather than stalling it — degrading to the old fire-and-forget
 * pacing in the worst case. A late callback after a watchdog advance can
 * complete the *next* entry early; the busy-retry path absorbs the resulting
 * premature submit, so the failure mode is one extra retry, not packet loss.
 */
class GattWriteQueue(
    private val lr: String,
    private val scope: CoroutineScope,
    private val isReady: () -> Boolean,
    private val submit: (ByteArray) -> Int,
) {
    companion object {
        private const val LOG_TAG = "GattWriteQueue"

        /** Submit result codes — aligned with BluetoothStatusCodes where one exists. */
        const val SUBMIT_OK = 0
        const val SUBMIT_BUSY = 201 // BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY
        const val SUBMIT_FAILED = -1

        /** Bound queue depth so a burst against a dead leg cannot grow unbounded. */
        private const val MAX_DEPTH = 256
        private const val BUSY_RETRY_DELAY_MS = 20L
        private const val MAX_BUSY_RETRIES = 25
        private const val WRITE_COMPLETE_TIMEOUT_MS = 500L
    }

    private class Entry(val data: ByteArray, val onComplete: ((Boolean) -> Unit)?)

    private val queue = ArrayDeque<Entry>()
    private var inFlight: Entry? = null
    private var busyRetries = 0
    private var watchdog: Job? = null

    /**
     * Queues [data] for writing. [onComplete] is invoked exactly once, on the
     * main dispatcher, with true when the write completed (or was accepted and
     * the completion callback timed out) and false when it was rejected,
     * dropped, or flushed.
     */
    fun enqueue(data: ByteArray, onComplete: ((Boolean) -> Unit)? = null) {
        scope.launch {
            if (!isReady()) {
                Log.w(LOG_TAG, "[$lr] enqueue rejected — leg not ready (cmd=0x${cmdHex(data)})")
                onComplete?.invoke(false)
                return@launch
            }
            if (queue.size >= MAX_DEPTH) {
                val dropped = queue.removeFirst()
                Log.e(LOG_TAG, "[$lr] queue overflow — dropping oldest (cmd=0x${cmdHex(dropped.data)})")
                dropped.onComplete?.invoke(false)
            }
            queue.addLast(Entry(data, onComplete))
            if (inFlight == null) {
                submitNext()
            }
        }
    }

    /** Routes an `onCharacteristicWrite` result for this leg into the queue. */
    fun onWriteComplete(success: Boolean) {
        scope.launch {
            val entry = inFlight ?: return@launch
            watchdog?.cancel()
            watchdog = null
            inFlight = null
            if (!success) {
                Log.e(LOG_TAG, "[$lr] write failed (cmd=0x${cmdHex(entry.data)})")
            }
            entry.onComplete?.invoke(success)
            submitNext()
        }
    }

    /** Fails the in-flight entry and everything queued. Call on disconnect / reconnect. */
    fun flush(reason: String) {
        scope.launch {
            watchdog?.cancel()
            watchdog = null
            val pending = queue.size + (if (inFlight != null) 1 else 0)
            if (pending > 0) {
                Log.w(LOG_TAG, "[$lr] flush($reason) — failing $pending pending write(s)")
            }
            inFlight?.onComplete?.invoke(false)
            inFlight = null
            while (queue.isNotEmpty()) {
                queue.removeFirst().onComplete?.invoke(false)
            }
            busyRetries = 0
        }
    }

    private fun submitNext() {
        if (inFlight != null) return
        val entry = queue.removeFirstOrNull() ?: return
        inFlight = entry
        busyRetries = 0
        trySubmit(entry)
    }

    private fun trySubmit(entry: Entry) {
        if (!isReady()) {
            Log.w(LOG_TAG, "[$lr] leg lost readiness mid-queue — failing write (cmd=0x${cmdHex(entry.data)})")
            inFlight = null
            entry.onComplete?.invoke(false)
            submitNext()
            return
        }
        when (val status = submit(entry.data)) {
            SUBMIT_OK -> startWatchdog()
            SUBMIT_BUSY -> {
                if (busyRetries >= MAX_BUSY_RETRIES) {
                    Log.e(LOG_TAG, "[$lr] write busy after $MAX_BUSY_RETRIES retries — dropping (cmd=0x${cmdHex(entry.data)})")
                    inFlight = null
                    entry.onComplete?.invoke(false)
                    submitNext()
                } else {
                    busyRetries++
                    scope.launch {
                        delay(BUSY_RETRY_DELAY_MS)
                        if (inFlight === entry) trySubmit(entry)
                    }
                }
            }
            else -> {
                Log.e(LOG_TAG, "[$lr] write submit failed status=$status (cmd=0x${cmdHex(entry.data)})")
                inFlight = null
                entry.onComplete?.invoke(false)
                submitNext()
            }
        }
    }

    private fun startWatchdog() {
        watchdog?.cancel()
        watchdog = scope.launch {
            delay(WRITE_COMPLETE_TIMEOUT_MS)
            val entry = inFlight ?: return@launch
            Log.w(LOG_TAG, "[$lr] write-complete callback missing after ${WRITE_COMPLETE_TIMEOUT_MS}ms — advancing (cmd=0x${cmdHex(entry.data)})")
            inFlight = null
            // The stack accepted the write; only the completion signal is lost.
            entry.onComplete?.invoke(true)
            submitNext()
        }
    }

    private fun cmdHex(data: ByteArray): String =
        if (data.isEmpty()) "??" else (data[0].toInt() and 0xff).toString(16).padStart(2, '0')
}
