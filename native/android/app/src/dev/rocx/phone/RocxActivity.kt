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
    /** The dev client's loop, when this is the dev client. */
    private var dev: DevClient? = null

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
        val meta = packageManager.getActivityInfo(componentName, PackageManager.GET_META_DATA).metaData
        val loading = SystemClock.uptimeMillis()
        // The first use of Rocx loads libapp.so (an app's) or libhost.so (the dev client's).
        Rocx.applier = Applier(this, screen)
        val loaded = SystemClock.uptimeMillis()
        if (Rocx.dev) {
            val client = DevClient(this, screen)
            dev = client
            val content = client.layout()
            content.setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                WindowInsets.CONSUMED
            }
            screen.setOnApplyWindowInsetsListener(null)
            setContentView(content)
            client.begin(given(intent))
            return
        }
        setContentView(screen)
        val origin = intent.getStringExtra("origin") ?: meta?.getString("rocx.origin") ?: "http://10.0.2.2:8080"
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

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        // rocx dev launching the client again, or its page's link, with its server.
        given(intent)?.let { dev?.begin(it) }
    }

    /** The server an intent names: rocx dev's `origin` extra, or its page's `rocx-dev://connect?origin=…`. */
    private fun given(intent: android.content.Intent): String? =
        intent.getStringExtra("origin") ?: intent.data?.takeIf { it.scheme == "rocx-dev" }?.getQueryParameter("origin")

    override fun onDestroy() {
        dev?.stop()
        if (Rocx.applier?.activity === this) Rocx.applier = null
        super.onDestroy()
    }
}
