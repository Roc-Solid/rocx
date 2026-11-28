package dev.rocx.phone

import android.app.Activity
import android.util.Log

/**
 * An app's page-wide phone half (D-141): what one of its page scripts that isn't an element's does
 * in a browser (a cookie set on every page, menus closed by a tap elsewhere, a question before a
 * form is sent), for a phone, which has no page scripts. The app writes it in Kotlin in its own
 * `android/` folder (`object Confirm : PageHalf() { … }`), and `build.sh` builds it into the app's
 * APK beside its element halves (D-139). It is told of what the script would have heard:
 *
 * - [start]: the app starting, before its first page is asked for (a cookie set here goes with
 *   that first request);
 * - [navigated]: after each navigation, the first page's too (`page.path` is where the app is);
 * - [before]: one of [events] on its way to its target, before the page's handlers, as a script's
 *   capturing listener on `window` hears it: true stops it (`preventDefault()` and
 *   `stopImmediatePropagation()`); [PageEvent.hold] stops it until the half sends it on
 *   ([Held.resume]: a dialog's answer), as if nothing had stopped it;
 * - [after]: one of [events] once the page's handlers had it, before what the browser does with it
 *   (a bubbling listener on `window`);
 * - [back]: Android's back, before the app's history goes back: true when the half took it (a menu
 *   closed, as Escape closes it in a browser);
 * - [call]: `Browser.call!(name, arg)`, the page functions the app's scripts register
 *   (`window.rocxEffects`).
 *
 * The events are the page's (`click`, `submit`, `input`, `change`, `toggle`…), and `pointerdown`: a
 * finger down anywhere on the screen, on the element under it.
 */
abstract class PageHalf {
    /** The events it hears in [before] and [after]; the page asks about no others. */
    open val events: Set<String> = emptySet()

    open fun start(page: Page) {}

    open fun navigated(page: Page) {}

    open fun before(page: Page, event: PageEvent): Boolean = false

    open fun after(page: Page, event: PageEvent) {}

    open fun back(page: Page): Boolean = false

    /**
     * `Browser.call!(name, arg)`, for the page functions the app's scripts register
     * (`window.rocxEffects`): true when the half did it. Asked before the shell's own (`Calls`) and
     * the engine's (focus, click, reveal, go, replace_query), so an app's own comes first, as its
     * script's does in a browser. `arg` is the call's JSON.
     */
    open fun call(page: Page, name: String, arg: org.json.JSONObject): Boolean = false
}

/** The page, as a page half sees it: where it is, its cookies and its elements. */
class Page internal constructor(val activity: Activity, private val origin: String, private val opening: String) {
    /** Where the app is: the path and query (`location.pathname + location.search`). */
    val path: String get() = Rocx.ask("path", "").ifEmpty { opening }

    /** Its whole address (`location.href`): the app's server's. */
    val url: String get() = origin.trimEnd('/') + path

    /**
     * Its cookies as a script sees them (`document.cookie`: `a=1; b=2`, not the `HttpOnly` ones);
     * setting it sets one (`document.cookie = "zone=60; Path=/; Max-Age=…"`), kept in the app's cookie
     * jar and sent with the requests after.
     */
    var cookie: String
        get() = Rocx.ask("cookie.read", url)
        set(line) {
            Rocx.ask("cookie.write", "$url\n$line")
        }

    /** Every element a selector finds, in the document's order (`querySelectorAll`). */
    fun all(selector: String): List<Element> = Rocx.ask("query", selector).lines().mapNotNull { it.toLongOrNull() }.map { Element(it, activity) }

    /** The first element a selector finds (`querySelector`). */
    fun first(selector: String): Element? = all(selector).firstOrNull()
}

/** An event as a page half hears it: its name, the element it is on, its value, and the button a submit was sent by. */
class PageEvent internal constructor(val name: String, val target: Element, val value: String, val submitter: Element?, private val token: Long) {
    internal var held = false

    /** Stops the event until [Held.resume] sends it on: the page's handlers and its default action then (a submit's fields aren't checked again). In [before] alone. */
    fun hold(): Held {
        held = token > 0
        return Held(token)
    }
}

/** A held event: sent on, or let go of. */
class Held internal constructor(private val token: Long) {
    fun resume() {
        if (token > 0) Rocx.ask("resume", token.toString())
    }

    fun drop() {
        if (token > 0) Rocx.ask("drop", token.toString())
    }
}

/** The app's page halves (`appPageHalves`, which build.sh writes from its android/ folder). */
object Pages {
    private val halves: List<PageHalf> by lazy { appPageHalves }
    private var page: Page? = null

    /** Before the app's first page is asked for (`Rocx.start`): the halves' events named, and each started once a process. */
    fun start(activity: Activity, origin: String, path: String) {
        if (halves.isEmpty()) return
        val first = page == null
        val page = Page(activity, origin, path)
        this.page = page
        if (!first) return
        Rocx.ask("page-events", halves.flatMap { it.events }.toSet().joinToString(" "))
        each("start") { it.start(page) }
    }

    /** The host's question (`Rocx.page`): 0 on, 1 stopped, 2 held. */
    fun hook(hook: String, event: String, target: Long, value: String, submitter: Long, token: Long): Int {
        val page = page ?: return 0
        when (hook) {
            "navigated" -> each("navigated") { it.navigated(page) }
            "before", "after" -> {
                val heard = PageEvent(event, Element(target, page.activity), value, if (submitter != 0L) Element(submitter, page.activity) else null, token)
                for (half in halves) {
                    if (event !in half.events) continue
                    if (hook == "after") {
                        call(half, event) { half.after(page, heard) }
                        continue
                    }
                    val stopped = call(half, event) { half.before(page, heard) } == true
                    if (heard.held) return 2
                    if (stopped) return 1
                }
            }
        }
        return 0
    }

    /** `Browser.call!`'s page functions: whether a half did it. */
    fun call(name: String, arg: String): Boolean {
        val page = page ?: return false
        if (halves.isEmpty()) return false
        val json = try {
            org.json.JSONObject(arg)
        } catch (_: Exception) {
            org.json.JSONObject()
        }
        return halves.any { half -> call(half, name) { half.call(page, name, json) } == true }
    }

    /** Android's back: whether a half took it. */
    fun back(): Boolean {
        val page = page ?: return false
        return halves.any { half -> call(half, "back") { half.back(page) } == true }
    }

    /** A finger down on the page's view `target` (0: none; [Touches]): `pointerdown` for the halves that hear it. */
    fun touched(activity: Activity, target: Long) {
        val page = page ?: return
        val heard = PageEvent("pointerdown", Element(target, activity), "", null, 0)
        for (half in halves) if ("pointerdown" in half.events && call(half, "pointerdown") { half.before(page, heard) } == true) return
        for (half in halves) if ("pointerdown" in half.events) call(half, "pointerdown") { half.after(page, heard) }
    }

    /** Whether a half hears `pointerdown` (the activity finds the element under a finger then). */
    val hearsTouches: Boolean get() = halves.any { "pointerdown" in it.events }

    private fun each(what: String, action: (PageHalf) -> Unit) {
        for (half in halves) call(half, what) { action(half) }
    }

    private fun <T> call(half: PageHalf, what: String, action: () -> T): T? = try {
        action()
    } catch (failure: Exception) {
        Rocx.say(Log.ERROR, "the page half ${half.javaClass.simpleName} failed on $what: ${failure.message}")
        null
    }
}
