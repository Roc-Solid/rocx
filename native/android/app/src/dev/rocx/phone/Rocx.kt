package dev.rocx.phone

import android.util.Log

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

    /** The screen's size in dp, less its system bars (D-137: media queries, viewport units, layout). */
    @JvmStatic external fun viewport(width: Float, height: Float)

    /**
     * The host's layout measuring a text view (D-137), on the main thread while it lays a flush out:
     * its size at a width (`mode` 0: at most `width` dp; 1: max-content; 2: min-content), in dp, as
     * two floats' bits in a long (width high).
     */
    @JvmStatic fun measure(id: Long, mode: Int, width: Float): Long {
        val (w, h) = applier?.measure(id, mode, width) ?: Pair(0f, 0f)
        return (java.lang.Float.floatToRawIntBits(w).toLong() shl 32) or (java.lang.Float.floatToRawIntBits(h).toLong() and 0xffffffffL)
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
