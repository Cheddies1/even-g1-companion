package com.eddie.evencompanion.wear

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** The Stop action on the recording notification. */
class StopRecordingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val link = PhoneLink(context.applicationContext)
        link.start()
        CoroutineScope(Dispatchers.Main).launch {
            try {
                val ack = link.command("record.stop")
                Log.i("EvenRemote", "stop from notification: ok=${ack.ok} ${ack.message}")
            } finally {
                link.close()
                pending.finish()
            }
        }
    }
}
