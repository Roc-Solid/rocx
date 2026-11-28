package dev.rocx.phone

import android.app.Activity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import java.util.IdentityHashMap

/**
 * A touch goes to what is drawn where it lands, as a tap in a browser hits what is painted there
 * (D-141). Android hands a touch to a view only within its parent's bounds, so a view hanging out
 * of the box it is in (a menu's items below its summary, an absolutely positioned badge) could never
 * be tapped: here the activity finds the page's topmost view at the finger ([hit]), and when one of
 * the boxes above it doesn't hold the point, the gesture goes to the deepest such box itself, in its
 * own coordinates, which hands it down as usual. The same look tells the app's page halves which
 * element a finger came down on (`pointerdown`, [Pages.touched]).
 */
object Touches {
    /** The view the gesture under way goes to, past the boxes that don't hold it. */
    private var forwarding: View? = null
    private val at = IntArray(2)

    /** True when the activity's own dispatch is to be passed over: the gesture went where it is drawn. */
    fun dispatch(activity: Activity, event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            forwarding = null
            val applier = Rocx.applier
            if (applier != null) {
                val ids = IdentityHashMap<View, Long>()
                applier.each { id, view -> ids[view] = id }
                val x = event.x.toInt()
                val y = event.y.toInt()
                val found = hit(activity.window.decorView, x, y, ids)
                if (Pages.hearsTouches) Pages.touched(activity, found?.let { ids[it] } ?: 0L)
                if (found != null) forwarding = outside(found, x, y)
                // A finger down off the focused field blurs it and the keyboard goes, as in a phone's
                // browser (a tap on another field moves the focus there instead).
                val focused = activity.currentFocus
                if (focused is android.widget.EditText && found !is android.widget.EditText && found !== focused) {
                    // The window itself takes the focus (a cleared field would hand it to the page's first field).
                    val root = activity.window.decorView as ViewGroup
                    root.descendantFocusability = ViewGroup.FOCUS_BEFORE_DESCENDANTS
                    root.isFocusableInTouchMode = true
                    root.requestFocus()
                    activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java)?.hideSoftInputFromWindow(focused.windowToken, 0)
                }
                Rocx.say(android.util.Log.DEBUG, "touch at $x,$y: #${found?.let { ids[it] }} ${found?.javaClass?.simpleName}, forwarded to ${forwarding?.let { ids[it] ?: it.javaClass.simpleName }}")
            }
        }
        val view = forwarding ?: return false
        view.getLocationInWindow(at)
        val local = MotionEvent.obtain(event)
        local.offsetLocation(-at[0].toFloat(), -at[1].toFloat())
        view.dispatchTouchEvent(local)
        local.recycle()
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) forwarding = null
        return true
    }

    /**
     * The topmost of the page's views at a point (window px): children before their parent, the last
     * drawn first; a view that isn't the page's (the layer, a scroll view's content) only passes
     * through. Every child is looked in, as a box doesn't clip what it holds unless it says so.
     */
    fun hit(view: View, x: Int, y: Int, ids: IdentityHashMap<View, Long>): View? {
        if (view.visibility != View.VISIBLE) return null
        if (view is ViewGroup) {
            for (index in view.childCount - 1 downTo 0) hit(view.getChildAt(index), x, y, ids)?.let { return it }
        }
        // The layer (fixed views' place over the page) is as big as the screen: only what is on it counts.
        if (ids[view] == null || view.tag == "rocx:layer" || !inside(view, x, y)) return null
        // Cut off by a box above it that clips (a scroll view, `overflow: hidden`).
        var parent = view.parent
        while (parent is ViewGroup) {
            if (parent.clipChildren && !inside(parent, x, y)) return null
            parent = parent.parent
        }
        return view
    }

    /** The deepest box above `view` that doesn't hold the point (Android's dispatch would stop above it); null when all do. */
    private fun outside(view: View, x: Int, y: Int): View? {
        var parent = view.parent
        while (parent is ViewGroup) {
            if (!inside(parent, x, y)) return parent
            parent = parent.parent
        }
        return null
    }

    private fun inside(view: View, x: Int, y: Int): Boolean {
        view.getLocationInWindow(at)
        return x >= at[0] && y >= at[1] && x < at[0] + view.width && y < at[1] + view.height
    }
}
