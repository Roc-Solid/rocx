package dev.rocx.phone

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.util.Log
import android.widget.Toast
import org.json.JSONArray
import java.io.File

/**
 * An app's phone half of one of its custom elements (D-139): what the element's script does in a
 * browser (`customElements.define` in one of the app's static scripts), for a phone, which has no page
 * scripts. The app writes it in Kotlin, in its own `android/` folder (`object ImageUpload :
 * ElementHalf("image-upload") { … }`), and `build.sh` builds it into the app's APK beside the shell
 * (the dev client has none). It is told of each event on its element and inside it, as the
 * script's listeners on the element are (`event`: its name, the element it happened on, and its
 * value: a file input's files, a field's text), and does what the script would with the [Element]
 * it is given: read its attributes, tell the page events with values (`tell`, which the page's
 * `on:<event>.value` handlers read, as the script's `this.value` and `dispatchEvent`), ask the app's
 * server (`fetch`, with the app's cookies and its origin, as the script's `fetch` does), and use
 * the phone (the clipboard, pictures' sizes, the activity).
 */
abstract class ElementHalf(val tag: String) {
    /** An event on the element, or on `target` inside it (`target.id == element.id` when on it). */
    open fun event(element: Element, name: String, target: Element, value: String) {}
}

/** An element of the page, as a phone half sees it (its view's id is the host's). */
class Element(val id: Long, val activity: Activity) {
    /** An attribute, as the page has it now; null when it hasn't one. */
    fun attr(name: String): String? = Rocx.ask("attr", "$id\n$name").takeIf { it.startsWith("=") }?.drop(1)

    /** Its tag (`button`, `input`, `image-upload`). */
    val tag: String get() = Rocx.ask("tag", id.toString())

    /** An event on the element with a value, as a script's `this.value = value; dispatchEvent(…)`. */
    fun tell(name: String, value: String) = Rocx.event(id, name, value)

    /**
     * A request to the app's server (a path is its), with the app's cookies, as the page's script
     * makes it; `done` on the main thread with the status (0: none came, `body` saying why) and the
     * answer's body.
     */
    fun fetch(method: String, url: String, headers: Map<String, String> = emptyMap(), body: ByteArray? = null, done: (Int, String) -> Unit) =
        Host.fetch(method, url, headers, body) { status, _, bytes -> done(status, String(bytes, Charsets.UTF_8)) }

    /** The page loaded again where it is (`location.reload()`). */
    fun reload() {
        Rocx.ask("reload", "")
    }

    /** It, or the nearest element above it, that a selector matches (`closest`); null for none (D-141). */
    fun closest(selector: String): Element? = Rocx.ask("closest", "$id\n$selector").toLongOrNull()?.let { Element(it, activity) }

    /** Whether a selector matches it (`matches`). */
    fun matches(selector: String): Boolean = Rocx.ask("matches", "$id\n$selector") == "1"

    /** Whether `other` is it or inside it (`contains`). */
    fun contains(other: Element): Boolean = Rocx.ask("contains", "$id\n${other.id}") == "1"

    /**
     * An attribute set (`setAttribute`), or taken away with null (`removeAttribute`), for what the
     * browser owns and a script changes (a `<details>`' `open`, whose `toggle` follows), not what the
     * page renders, which renders it again (D-141).
     */
    fun set(name: String, value: String?) {
        Rocx.ask("set", if (value == null) "$id\n$name" else "$id\n$name\n=$value")
    }

    override fun equals(other: Any?): Boolean = other is Element && other.id == id

    override fun hashCode(): Int = id.hashCode()
}

/** What the phone has for a half beyond the page: the clipboard, a short message. */
object Phone {
    /** Text put on the clipboard (`navigator.clipboard.writeText`); Android 13 and later say so. */
    fun copy(context: Context, text: String, label: String = "Copied text") {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
        if (Build.VERSION.SDK_INT < 33) Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
    }

    fun say(context: Context, text: String) = Toast.makeText(context, text, Toast.LENGTH_LONG).show()

    /**
     * A question with OK and Cancel, as `confirm()` asks it (D-141): `answered(true)` for OK; Cancel,
     * back or a tap beside it is false. Asynchronous: hold the event it is about ([PageEvent.hold]).
     */
    fun confirm(activity: Activity, question: String, answered: (Boolean) -> Unit) {
        var done = false
        val answer = { ok: Boolean ->
            if (!done) {
                done = true
                answered(ok)
            }
        }
        android.app.AlertDialog.Builder(activity, Dialogs.theme())
            .setMessage(question)
            .setPositiveButton(android.R.string.ok) { _, _ -> answer(true) }
            .setNegativeButton(android.R.string.cancel) { _, _ -> answer(false) }
            .setOnDismissListener { answer(false) }
            .show()
    }

    /** The files a file input's `change` gave (`Html.File`s' JSON): each one's name, type, size and file. */
    fun files(value: String): List<Picked> = try {
        val list = JSONArray(value)
        (0 until list.length()).mapNotNull { at ->
            val file = list.optJSONObject(at) ?: return@mapNotNull null
            val url = file.optString("url")
            val path = Uri.path(url) ?: return@mapNotNull null
            Picked(file.optString("name"), file.optString("type"), file.optLong("size"), File(path))
        }
    } catch (_: Exception) {
        emptyList()
    }

    data class Picked(val name: String, val type: String, val size: Long, val file: File)

    private object Uri {
        fun path(url: String): String? = if (url.startsWith("file://")) android.net.Uri.decode(url.removePrefix("file://")) else null
    }
}

/** The shell's requests (`Element.fetch`), by token, answered on the main thread (`Rocx.fetched`). */
object Host {
    private var tokens = 0L
    private val waiting = HashMap<Long, (Int, String, ByteArray) -> Unit>()

    fun fetch(method: String, url: String, headers: Map<String, String>, body: ByteArray?, done: (Int, String, ByteArray) -> Unit) {
        val token = ++tokens
        waiting[token] = done
        Rocx.fetch(token, method, url, headers.entries.joinToString("\n") { "${it.key}: ${it.value}" }, body)
    }

    fun answered(token: Long, status: Int, headers: String, body: ByteArray) {
        val done = waiting.remove(token) ?: return
        try {
            done(status, headers, body)
        } catch (failure: Exception) {
            Rocx.say(Log.ERROR, "a phone half's answer failed: ${failure.message}")
        }
    }
}

/** The app's halves, by tag (`appHalves`, which build.sh writes from the app's android/ folder). */
object Elements {
    private val halves: Map<String, ElementHalf> by lazy { appHalves.associateBy { it.tag } }

    /** An event for the half of `tag`, if the app has one. */
    fun event(activity: Activity, view: Long, tag: String, name: String, target: Long, value: String) {
        val half = halves[tag] ?: return
        try {
            half.event(Element(view, activity), name, Element(target, activity), value)
        } catch (failure: Exception) {
            Rocx.say(Log.ERROR, "the phone half of <$tag> failed on $name: ${failure.message}")
        }
    }
}
