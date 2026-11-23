package dev.rocx.phone

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.widget.ScrollView

/**
 * The app's one activity: a scrolling screen whose content is the app's root view, made by the
 * applier from the native host's ops. The server is the manifest's `rocx.origin`, or the intent's
 * `origin` extra (`adb shell am start … --es origin http://…`).
 */
class RocxActivity : Activity() {
    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        val created = SystemClock.uptimeMillis()
        val screen = ScrollView(this)
        screen.isFillViewport = true
        // The system bars: the app draws below them (edge to edge is the default from API 35).
        screen.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsets.CONSUMED
        }
        setContentView(screen)
        val meta = packageManager.getActivityInfo(componentName, PackageManager.GET_META_DATA).metaData
        val origin = intent.getStringExtra("origin") ?: meta?.getString("rocx.origin") ?: "http://10.0.2.2:8080"
        val loading = SystemClock.uptimeMillis()
        // The first use of Rocx loads libapp.so.
        Rocx.applier = Applier(this, screen)
        val loaded = SystemClock.uptimeMillis()
        Rocx.start(origin, "/")
        val started = SystemClock.uptimeMillis()
        screen.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                screen.viewTreeObserver.removeOnPreDrawListener(this)
                val drawn = SystemClock.uptimeMillis()
                Log.i("rocx", "first frame: ${drawn - created} ms after onCreate (libapp.so loaded in ${loaded - loading} ms; the app mounted and its first batch applied in ${started - loaded} ms)")
                return true
            }
        })
    }

    override fun onDestroy() {
        if (Rocx.applier?.activity === this) Rocx.applier = null
        super.onDestroy()
    }
}
