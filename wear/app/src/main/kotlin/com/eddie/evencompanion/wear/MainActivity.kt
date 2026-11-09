package com.eddie.evencompanion.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

class MainActivity : ComponentActivity() {
    private lateinit var link: PhoneLink

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        link = PhoneLink(applicationContext)
        setContent { RemoteScreen(link) }
    }

    override fun onStart() {
        super.onStart()
        link.start()
    }

    override fun onStop() {
        link.stop()
        super.onStop()
    }

    override fun onDestroy() {
        link.close()
        super.onDestroy()
    }
}
