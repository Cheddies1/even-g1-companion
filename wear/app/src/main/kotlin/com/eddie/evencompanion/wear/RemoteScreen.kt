package com.eddie.evencompanion.wear

import android.view.HapticFeedbackConstants
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.PositionIndicator
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.TimeText
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val Accent = Color(0xFF6FC4B4)
private val RecordRed = Color(0xFFE5484D)
private val Muted = Color(0xFF9AA5AB)

private val MODES = listOf("glance", "capture", "navigate", "chat")

@Composable
fun RemoteScreen(link: PhoneLink) {
    val state by link.state.collectAsStateWithLifecycle()
    val reachable by link.phoneReachable.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val view = LocalView.current
    var feedback by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    // One tap-command in flight at a time, so a double tap cannot fire twice.
    // ask.start/stop bypass it: a quick release must still send the stop, and
    // the phone runs commands strictly in order.
    fun send(cmd: String, vararg args: Pair<String, String>) {
        val gated = !cmd.startsWith("ask.")
        if (gated && busy) return
        if (gated) busy = true
        scope.launch {
            val ack = link.command(cmd, *args)
            if (gated) busy = false
            feedback = if (ack.ok) ack.message else "! ${ack.message}"
            view.performHapticFeedback(
                if (ack.ok) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.REJECT
            )
        }
    }

    MaterialTheme {
        val listState = rememberScalingLazyListState()
        Scaffold(
            timeText = { TimeText() },
            positionIndicator = { PositionIndicator(scalingLazyListState = listState) },
        ) {
            ScalingLazyColumn(
                state = listState,
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                item { Header(state, reachable) }

                val s = state
                if (s != null) {
                    when (s.mode) {
                        "capture" -> item { CaptureControls(s) { send(it) } }
                        "glance" -> {
                            item { GlanceControls(s) { send(it) } }
                            item { HoldToAsk(s, onStart = { send("ask.start") }, onStop = { send("ask.stop") }) }
                        }
                        "chat" -> item {
                            HoldToAsk(s, onStart = { send("ask.start") }, onStop = { send("ask.stop") })
                        }
                        "navigate" -> item { NavigateControls(s) { send("nav.stop") } }
                    }
                }

                if (feedback.isNotEmpty()) {
                    item {
                        Text(
                            feedback,
                            fontSize = 11.sp,
                            color = if (feedback.startsWith("!")) RecordRed else Muted,
                            textAlign = TextAlign.Center,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }

                MODES.forEach { mode ->
                    item {
                        ModeChip(mode, selected = state?.mode == mode) {
                            send("mode.set", "mode" to mode)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Header(state: PhoneState?, reachable: Boolean?) {
    val (title, sub) = when {
        reachable == false -> "No phone" to "Is Bluetooth on?"
        state == null -> "Waiting..." to "Open Even Companion on the phone"
        !state.connected -> label(state.mode) to "Glasses not connected"
        else -> label(state.mode) to listOfNotNull(
            state.glassesBattery?.let { "Glasses $it%" },
            state.caseBattery?.let { "Case $it%" },
        ).joinToString("  ")
    }
    Box(Modifier.padding(top = 18.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Accent)
            if (sub.isNotEmpty()) {
                Text(sub, fontSize = 11.sp, color = Muted, textAlign = TextAlign.Center)
            }
        }
    }
}

@Composable
private fun CaptureControls(state: PhoneState, send: (String) -> Unit) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(state.recording) {
        while (state.recording) {
            now = System.currentTimeMillis()
            delay(1000)
        }
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Button(
            onClick = { send(if (state.recording) "capture.stop" else "capture.start") },
            colors = ButtonDefaults.buttonColors(
                backgroundColor = if (state.recording) Color.DarkGray else RecordRed,
            ),
            modifier = Modifier.size(ButtonDefaults.LargeButtonSize),
        ) {
            if (state.recording) {
                Box(Modifier.size(22.dp).background(RecordRed, RoundedCornerShape(3.dp)))
            } else {
                Box(Modifier.size(24.dp).background(Color.White, RoundedCornerShape(12.dp)))
            }
        }
        val started = state.recordingStartedAt
        Text(
            if (state.recording && started != null) elapsed(now - started) else "Tap to record",
            fontSize = 12.sp,
            color = if (state.recording) RecordRed else Muted,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

@Composable
private fun GlanceControls(state: PhoneState, send: (String) -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            when {
                !state.glanceVisible -> "${state.glanceCount} notifications"
                state.glanceTitle.isEmpty() -> "End of list"
                else -> "${state.glanceIndex + 1}/${state.glanceCount} ${state.glanceApp}"
            },
            fontSize = 12.sp,
            color = Muted,
        )
        if (state.glanceVisible && state.glanceTitle.isNotEmpty()) {
            Text(
                state.glanceTitle,
                fontSize = 13.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 12.dp),
            )
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(top = 4.dp),
        ) {
            Button(onClick = { send("glance.prev") }, modifier = Modifier.size(ButtonDefaults.SmallButtonSize)) {
                Text("<")
            }
            Button(
                onClick = { send("glance.close") },
                colors = ButtonDefaults.secondaryButtonColors(),
                modifier = Modifier.size(ButtonDefaults.SmallButtonSize),
            ) { Text("x") }
            Button(onClick = { send("glance.next") }, modifier = Modifier.size(ButtonDefaults.SmallButtonSize)) {
                Text(">")
            }
        }
    }
}

/** Press and hold = hold the glasses long-press: listen while held, submit on release. */
@Composable
private fun HoldToAsk(state: PhoneState, onStart: () -> Unit, onStop: () -> Unit) {
    var held by remember { mutableStateOf(false) }
    val label = when {
        held || state.assistantListening -> "Listening... release to ask"
        state.assistantThinking -> "Thinking..."
        else -> "Hold to ask"
    }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .padding(top = 6.dp)
            .fillMaxWidth(0.8f)
            .height(44.dp)
            .background(if (held) Accent else Color(0xFF2A3439), RoundedCornerShape(22.dp))
            .pointerInput(Unit) {
                // Consume every event so the scrolling list cannot steal the
                // touch: a slight drift used to cancel the hold, sending
                // ask.stop a few ms after ask.start with no audio.
                awaitEachGesture {
                    awaitFirstDown().consume()
                    held = true
                    onStart()
                    do {
                        val event = awaitPointerEvent()
                        event.changes.forEach { it.consume() }
                    } while (event.changes.any { it.pressed })
                    held = false
                    onStop()
                }
            },
    ) {
        Text(label, fontSize = 13.sp, color = if (held) Color.Black else Color.White)
    }
}

@Composable
private fun NavigateControls(state: PhoneState, onStop: () -> Unit) {
    if (state.walkActive) {
        Chip(
            label = { Text("Stop walk") },
            onClick = onStop,
            colors = ChipDefaults.chipColors(backgroundColor = RecordRed),
        )
    } else {
        Text(
            "Share a route from Google Maps on the phone",
            fontSize = 12.sp,
            color = Muted,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
}

@Composable
private fun ModeChip(mode: String, selected: Boolean, onClick: () -> Unit) {
    Chip(
        label = { Text(label(mode)) },
        onClick = onClick,
        colors = if (selected) {
            ChipDefaults.chipColors(backgroundColor = Accent, contentColor = Color.Black)
        } else {
            ChipDefaults.secondaryChipColors()
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

private fun label(mode: String) = mode.replaceFirstChar { it.uppercase() }

private fun elapsed(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    return "%d:%02d".format(total / 60, total % 60)
}
