package dev.rocx.phone

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

    @JvmStatic external fun event(id: Long, name: String, value: String)

    /** The applier the screen's ops go to (the activity's, while there is one). */
    var applier: Applier? = null

    @JvmStatic fun apply(ops: ByteArray) {
        applier?.apply(ops)
    }
}
