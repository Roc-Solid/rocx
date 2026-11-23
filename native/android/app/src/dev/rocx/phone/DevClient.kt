package dev.rocx.phone

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * The dev client (D-063's dev mode, `rocx dev --android`): an app's Roc isn't in this APK, but in a
 * library the computer's `rocx dev` builds on each save and serves beside the app's server
 * (`/rocx/android/latest.json` names the latest build, `/rocx/android/<file>` is its library). A
 * thread asks for the latest build every 150 ms; a new one is downloaded into the app's
 * files and loaded in place of the last (`Rocx.reload`): the screen is mounted again, what was
 * typed in its fields typed in again, and its scroll kept. A build that failed shows its error on
 * a red screen until the next one; so does one built for another platform (the fingerprints differ:
 * rebuild the dev client).
 *
 * The server is the intent's `origin` (rocx dev launches the client with it), else the last one,
 * else what the connect screen is given.
 */
class DevClient(private val activity: Activity, private val screen: ScrollView) {
    private val main = Handler(Looper.getMainLooper())
    private val prefs = activity.getSharedPreferences("rocx-dev", Context.MODE_PRIVATE)
    private val density = activity.resources.displayMetrics.density
    private val fingerprint = Rocx.fingerprint()
    /** The red screen: a build's error, over the app. */
    private val error = TextView(activity)
    private val errorBox = ScrollView(activity)
    /** A line at the bottom: what the dev client is doing. */
    private val status = TextView(activity)
    @Volatile private var origin = ""
    @Volatile private var polling = false
    /** The build shown (or failed), as latest.json names it. */
    @Volatile private var seen = ""

    /** The activity's content: the app's screen, with the red screen and the status line over it. */
    fun layout(): View {
        val frame = FrameLayout(activity)
        frame.addView(screen, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        error.setTextColor(Color.WHITE)
        error.typeface = Typeface.MONOSPACE
        error.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        error.setPadding(px(16), px(16), px(16), px(16))
        errorBox.setBackgroundColor(Color.parseColor("#ffb3261e"))
        errorBox.addView(error)
        errorBox.visibility = View.GONE
        errorBox.setOnClickListener { errorBox.visibility = View.GONE }
        frame.addView(errorBox, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        status.setTextColor(Color.WHITE)
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        status.setBackgroundColor(Color.parseColor("#cc1b1b1f"))
        status.setPadding(px(12), px(6), px(12), px(6))
        status.visibility = View.GONE
        frame.addView(status, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        return frame
    }

    /**
     * Starts: the intent's server, the last one, or the connect screen. If the last run ended while
     * a build was loading or mounting (its code stopped the process: a native crash), that build
     * is shown on the red screen instead of being loaded again, until the next.
     */
    fun begin(given: String?) {
        val crashed = prefs.getString("loading", null)
        if (crashed != null) {
            prefs.edit().remove("loading").commit()
            seen = crashed
            showError("The build stopped the dev client", "Build $crashed ended the app while it loaded or mounted (a crash in its native code: see `adb logcat`). The next build is loaded as usual.")
        }
        val server = given?.takeIf { it.isNotBlank() } ?: prefs.getString("origin", null)
        if (server == null) connectScreen() else connect(server)
    }

    private fun px(dp: Int): Int = (dp * density + 0.5f).toInt()

    private fun connectScreen() {
        val form = LinearLayout(activity)
        form.orientation = LinearLayout.VERTICAL
        form.setPadding(px(24), px(48), px(24), px(24))
        val title = TextView(activity)
        title.text = "rocx dev"
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
        title.typeface = Typeface.DEFAULT_BOLD
        val said = TextView(activity)
        said.text = "Run `rocx dev --android <app>` on your computer. On the emulator or a phone on USB it opens this client itself; on Wi-Fi, give the computer's address (and run its server with `-- --host 0.0.0.0`)."
        said.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        said.setPadding(0, px(12), 0, px(12))
        val field = EditText(activity)
        field.isSingleLine = true
        field.setText(prefs.getString("origin", "http://127.0.0.1:8080"))
        val button = Button(activity)
        button.text = "Connect"
        button.isAllCaps = false
        button.setOnClickListener { connect(field.text.toString()) }
        for (view in listOf(title, said, field, button)) form.addView(view)
        screen.removeAllViews()
        screen.addView(form)
    }

    private fun connect(server: String) {
        val given = server.trim().trimEnd('/')
        if (origin.isNotEmpty() && given != origin) seen = ""
        origin = given
        prefs.edit().putString("origin", origin).apply()
        show("Waiting for $origin…")
        if (polling) return
        polling = true
        Thread({ poll() }, "rocx-dev").start()
    }

    private fun show(text: String) = main.post {
        status.text = text
        status.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun get(url: String): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 2000
        connection.readTimeout = 10000
        connection.useCaches = false
        try {
            if (connection.responseCode != 200) throw IllegalStateException("$url: ${connection.responseCode}")
            return connection.inputStream.use { it.readBytes() }
        } finally {
            connection.disconnect()
        }
    }

    /** Asks for the latest build until the activity goes; a new one is fetched and loaded. */
    private fun poll() {
        // False until the server first answers: then the "Waiting for…" line goes.
        var reachable = false
        // Since when the server hasn't answered: said once that is 1.5 s (a restart is quicker).
        var unanswered = 0L
        while (polling) {
            try {
                val latest = JSONObject(String(get("$origin/rocx/android/latest.json"), Charsets.UTF_8))
                if (!reachable) show("")
                reachable = true
                unanswered = 0L
                val build = latest.optString("build")
                if (build.isNotEmpty() && build != seen) {
                    val failed = latest.optString("error")
                    val built = latest.optLong("built")
                    when {
                        failed.isNotEmpty() -> {
                            seen = build
                            main.post { showError("The build failed", failed) }
                        }
                        latest.optString("fingerprint") != fingerprint -> {
                            seen = build
                            main.post {
                                showError("This dev client is for another platform", "The build is for ${latest.optString("fingerprint")}; this client runs $fingerprint.\nRebuild and reinstall it: native/android/build.sh --dev-client")
                            }
                        }
                        else -> {
                            show("Loading the new build…")
                            val fetched = SystemClock.uptimeMillis()
                            val bytes = get("$origin/rocx/android/${latest.getString("file")}")
                            val file = File(activity.filesDir, "app-$build.so")
                            val partial = File(activity.filesDir, "app-$build.so.part")
                            partial.writeBytes(bytes)
                            partial.renameTo(file)
                            val took = SystemClock.uptimeMillis() - fetched
                            seen = build
                            main.post { load(file, built, took, bytes.size) }
                        }
                    }
                }
            } catch (e: Exception) {
                if (unanswered == 0L) unanswered = SystemClock.uptimeMillis()
                if (SystemClock.uptimeMillis() - unanswered > 1500) {
                    if (reachable || status.text.startsWith("Waiting")) show("Can't reach $origin (${e.message}): is rocx dev running?")
                    reachable = false
                }
            }
            Thread.sleep(150)
        }
    }

    /** Loads a build in place of the last, on the main thread. */
    private fun load(file: File, built: Long, fetched: Long, size: Int) {
        val y = screen.scrollY
        val started = SystemClock.uptimeMillis()
        // A new applier: the new build's views replace the last one's (its ROOT op).
        Rocx.applier = Applier(activity, screen)
        // Noted until it is mounted: if its code ends the process, the next run says so (`begin`).
        prefs.edit().putString("loading", file.name.removePrefix("app-").removeSuffix(".so")).commit()
        val said = Rocx.reload(file.absolutePath, origin, "/")
        prefs.edit().remove("loading").commit()
        if (said.isNotEmpty()) {
            showError("The app didn't load", said)
            return
        }
        errorBox.visibility = View.GONE
        screen.post { screen.scrollTo(0, y) }
        val loaded = SystemClock.uptimeMillis() - started
        val age = if (built > 0) " ${System.currentTimeMillis() - built} ms after rocx dev built it;" else ""
        Log.i("rocx", "dev: build ${file.name} shown:$age fetched (${size / 1024} KB) in $fetched ms, loaded and mounted in $loaded ms")
        show("Reloaded in ${fetched + loaded} ms")
        main.postDelayed({ if (status.text.startsWith("Reloaded")) show("") }, 1500)
        // The builds before: their libraries stay mapped while loaded, so their files can go.
        activity.filesDir.listFiles()?.filter { it.name.startsWith("app-") && it.name != file.name }?.forEach { it.delete() }
    }

    private fun showError(title: String, text: String) {
        Log.e("rocx", "dev: $title: $text")
        error.text = "$title\n\n$text\n\n(Tap to hide. The next build replaces it.)"
        errorBox.visibility = View.VISIBLE
        show("")
    }

    fun stop() {
        polling = false
    }
}
