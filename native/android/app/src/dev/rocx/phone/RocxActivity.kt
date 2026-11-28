package dev.rocx.phone

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.widget.ScrollView
import android.window.OnBackInvokedDispatcher

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
            // The keyboard up (D-139): the focused field kept in view above it.
            if (insets.isVisible(WindowInsets.Type.ime())) view.post { Focus.keepInView(screen) }
            WindowInsets.CONSUMED
        }
        val meta = packageManager.getActivityInfo(componentName, PackageManager.GET_META_DATA).metaData
        val loading = SystemClock.uptimeMillis()
        // The first use of Rocx loads libapp.so (an app's) or libhost.so (the dev client's).
        Rocx.applier = Applier(this, screen)
        Rocx.screen = screen
        val loaded = SystemClock.uptimeMillis()
        // Navigation (D-138): the cookie jar in the app's files, and back through the app's history
        // before the app closes (Android 13's back callback; onBackPressed before it).
        Rocx.files(filesDir.path)
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) {
                // An app's page half first (D-141: an open menu closed, as Escape closes it).
                if (!Pages.back() && !Rocx.back()) finish()
            }
        }
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
        // Where it opens: `/`, or the intent's `path` extra (`adb shell am start … --es path /login`).
        val path = intent.getStringExtra("path") ?: "/"
        // The app's page halves (D-141) start before its first page is asked for.
        Pages.start(this, origin, path)
        Rocx.start(origin, path)
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

    @Deprecated("Android 13's OnBackInvokedCallback takes it from there")
    override fun onBackPressed() {
        if (!Pages.back() && !Rocx.back()) super.onBackPressed()
    }

    /** A touch goes to what is drawn where it lands, even hanging out of its box; the app's page halves hear `pointerdown` (D-141). */
    override fun dispatchTouchEvent(event: android.view.MotionEvent): Boolean {
        if (Touches.dispatch(this, event)) return true
        return super.dispatchTouchEvent(event)
    }

    @Deprecated("the picker's result (D-139), as startActivityForResult gives it")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        if (!Picker.result(this, requestCode, resultCode, data)) super.onActivityResult(requestCode, resultCode, data)
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
        if (Rocx.applier?.activity === this) {
            Rocx.applier = null
            Rocx.screen = null
        }
        super.onDestroy()
    }
}
