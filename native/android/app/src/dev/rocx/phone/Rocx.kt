package dev.rocx.phone

import android.util.Log

/**
 * The native host (libapp.so: the app's Roc, native/core and native/android), as Kotlin sees it.
 * `start` and `event` go to it, on the main thread; it calls `apply` once a flush, with the
 * flush's ops, which the activity's applier walks.
 */
object Rocx {
    init {
        System.loadLibrary("app")
    }

    @JvmStatic external fun start(origin: String, path: String)

    @JvmStatic external fun send(id: Long, name: String, value: String)

    /**
     * An event on a view: the handlers run, the flush, and the screen's ops applied, all before
     * this returns. A tap's time is logged (logcat, tag `rocx`).
     */
    @JvmStatic fun event(id: Long, name: String, value: String) {
        val started = System.nanoTime()
        send(id, name, value)
        if (name == "click") Log.i("rocx", "tap on #$id: handled and the screen patched in ${"%.2f".format((System.nanoTime() - started) / 1e6)} ms")
    }

    /** The applier the screen's ops go to (the activity's, while there is one). */
    var applier: Applier? = null

    @JvmStatic fun apply(ops: ByteArray) {
        applier?.apply(ops)
    }
}
