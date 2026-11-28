package dev.rocx.phone

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.util.Log
import android.view.View
import android.view.ViewTreeObserver

/**
 * The native host (libapp.so: the app's Roc, native/core and native/android), as Kotlin sees it.
 * `start` and `event` go to it, on the main thread; it calls `apply` once a flush, with the
 * flush's ops, which the activity's applier walks.
 */
object Rocx {
    /**
     * Whether this is the dev client (`rocx dev --android`): its library is libhost.so, and the app's
     * Roc comes later, a library loaded at run time (`reload`). An app's APK has libapp.so.
     */
    val dev: Boolean = try {
        System.loadLibrary("app")
        false
    } catch (_: UnsatisfiedLinkError) {
        System.loadLibrary("host")
        true
    }

    /** An app's: starts the app linked into libapp.so. */
    @JvmStatic external fun start(origin: String, path: String)

    /** The dev client's: loads a build's library in place of the last; "" once it runs, else why not. */
    @JvmStatic external fun reload(library: String, origin: String, path: String): String

    /** The dev client's: the platform it runs apps for, and its Roc compiler. */
    @JvmStatic external fun fingerprint(): String

    /** The dev client's: a line of the log, to logcat and to the dev server (`rocx dev`'s terminal). */
    @JvmStatic external fun log(priority: Int, text: String)

    /** A line of the log (tag `rocx`): the dev client's goes to the dev server too. */
    @JvmStatic fun say(priority: Int, text: String) {
        if (dev) log(priority, text) else Log.println(priority, "rocx", text)
    }

    @JvmStatic external fun send(id: Long, name: String, value: String)

    /** Where what outlives the process is kept (the app's files: the cookie jar), before `start`. */
    @JvmStatic external fun files(dir: String)

    /** Android's back: the app's history's entry before (D-138); false at the first. */
    @JvmStatic external fun back(): Boolean

    /** The scrolling screen (the activity's): kept on the history entry a navigation leaves, and
     * scrolled to the top, or back to where an entry was, after one. */
    var screen: View? = null

    @JvmStatic fun scrollX(): Float = screen?.scrollX?.toFloat() ?: 0f

    @JvmStatic fun scrollY(): Float = screen?.scrollY?.toFloat() ?: 0f

    /** After the batch that made the page: once it is laid out (its height known), so the scroll
     * isn't cut short. */
    @JvmStatic fun scrollTo(x: Float, y: Float) {
        val view = screen ?: return
        view.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                view.viewTreeObserver.removeOnPreDrawListener(this)
                view.scrollTo(x.toInt(), y.toInt())
                return true
            }
        })
        view.invalidate()
    }

    /** What is elsewhere (another site's page, `mailto:`, `tel:`), opened by the system. */
    @JvmStatic fun open(url: String): Boolean {
        val activity = applier?.activity ?: return false
        return try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
            true
        } catch (_: ActivityNotFoundException) {
            say(Log.WARN, "nothing on this phone opens $url")
            false
        }
    }

    /**
     * An event on a view: the handlers run, the flush, and the screen's ops applied, all before
     * this returns. A tap's time is logged (logcat, tag `rocx`).
     */
    @JvmStatic fun event(id: Long, name: String, value: String) {
        val started = System.nanoTime()
        send(id, name, value)
        if (name == "click") say(Log.INFO, "tap on #$id: handled and the screen patched in ${"%.2f".format((System.nanoTime() - started) / 1e6)} ms")
    }

    /**
     * `Browser.call!(name, arg)`'s native half, once a handler is done (`Calls`): whether there is
     * a handler by that name. `arg` is its JSON; `origin` the app's server, a path's.
     */
    @JvmStatic fun call(name: String, arg: String, origin: String): Boolean {
        val activity = applier?.activity ?: return false
        return Calls.call(activity, name, arg, origin)
    }

    /** The applier the screen's ops go to (the activity's, while there is one). */
    var applier: Applier? = null

    @JvmStatic fun apply(ops: ByteArray) {
        applier?.apply(ops)
    }
}
