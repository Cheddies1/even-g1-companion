package com.eddie.evencompanion.wear

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

class MainActivity : ComponentActivity() {
    private lateinit var link: PhoneLink

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        link = PhoneLink(applicationContext)
        setContent { RemoteScreen(link) }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
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
