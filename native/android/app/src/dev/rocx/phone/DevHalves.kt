package dev.rocx.phone

import android.util.Log
import dalvik.system.InMemoryDexClassLoader
import java.nio.ByteBuffer

/**
 * The dev client's phone halves of an app (D-141): the Kotlin in its android/ folder, which rocx dev
 * builds into a dex (`build.sh --halves`) and serves beside each build's library, loaded from memory
 * over the client's own classes (which keep Kotlin's library whole for them). The dex lists them in
 * `dev.rocx.devhalves.DevHalves` (`elements`, `pages`), as build.sh's AppHalves.kt does for an APK.
 */
object DevHalves {
    /** The dex loaded last, by its name (`halves-<hash>.dex`), so a build with the same halves keeps them. */
    private var loaded = ""

    /** The halves the dex `name` holds (its bytes), or none ("" or a dex that fails to load). */
    fun use(name: String, bytes: ByteArray?) {
        if (name == loaded) return
        loaded = name
        if (name.isEmpty() || bytes == null) {
            Halves.elements = emptyList()
            Halves.pages = emptyList()
            return
        }
        try {
            val loader = InMemoryDexClassLoader(ByteBuffer.wrap(bytes), DevHalves::class.java.classLoader)
            val list = loader.loadClass("dev.rocx.devhalves.DevHalves")
            @Suppress("UNCHECKED_CAST")
            Halves.elements = list.getField("elements").get(null) as List<ElementHalf>
            @Suppress("UNCHECKED_CAST")
            Halves.pages = list.getField("pages").get(null) as List<PageHalf>
            Rocx.say(Log.INFO, "dev: the app's phone halves: ${(Halves.elements + Halves.pages).joinToString { it.javaClass.simpleName }}")
        } catch (failure: Throwable) {
            Halves.elements = emptyList()
            Halves.pages = emptyList()
            Rocx.say(Log.ERROR, "dev: the app's phone halves didn't load: ${failure.message}")
        }
    }
}
