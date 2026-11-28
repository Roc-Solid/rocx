package dev.rocx.phone

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Process
import android.os.SystemClock
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.ScrollView
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max

/**
 * Applies a batch of the native host's ops (native/core/src/native.rs) to Android views: one call
 * a batch. Views are kept by the host's ids. The host lays the views out (D-137: Taffy) and sends
 * each one's frame (FRAME): a box is a [Box], which puts its children where their frames say; text
 * is a [TextBox] (styled runs, measured here for the host's layout: [measure]); a box that scrolls
 * is a ScrollView or a HorizontalScrollView around a [Box] as big as what it holds (EXTENT); an
 * `<svg>` is a [SvgView]; fields and checkboxes are the platform's own. Every view's CSS paint is a
 * [CssPaint]. Fixed views are on the screen's layer, over the page, which scrolls (`screen`).
 */
class Applier(val activity: Activity, private val screen: ViewGroup) {
    private val views = HashMap<Long, View>()
    private val kinds = HashMap<Long, String>()
    /** A scrolling view's content: where its children go. */
    private val contents = HashMap<Long, Box>()
    private val density = activity.resources.displayMetrics.density
    /** While a batch is applied: what the applier does to a field isn't the user's typing. */
    private var applying = false
    private var batches = 0
    private var rootId = 0L
    private var lastViewport = Pair(0f, 0f)

    init {
        // The screen's size in dp (less its system bars): at once from the window, then from each
        // layout of the screen (insets known, a rotation).
        val metrics = activity.resources.displayMetrics
        viewport(metrics.widthPixels / density, metrics.heightPixels / density - 80f)
        screen.addOnLayoutChangeListener { view, left, top, right, bottom, _, _, _, _ ->
            val w = (right - left - view.paddingLeft - view.paddingRight) / density
            val h = (bottom - top - view.paddingTop - view.paddingBottom) / density
            if (w > 0f && h > 0f) view.post { viewport(w, h) }
        }
        // Sticky views keep to their edge as the page (or their scroll view) scrolls.
        screen.viewTreeObserver.addOnScrollChangedListener { stick() }
        // A new applier (the dev client's next build): the last one's layer goes.
        (screen.parent as? ViewGroup)?.let { parent ->
            for (at in parent.childCount - 1 downTo 0) if (parent.getChildAt(at).tag == "rocx:layer") parent.removeViewAt(at)
        }
    }

    private fun viewport(w: Float, h: Float) {
        if (Pair(w, h) == lastViewport) return
        lastViewport = Pair(w, h)
        Rocx.viewport(w, h)
    }

    fun apply(ops: ByteArray) {
        val started = SystemClock.uptimeMillis()
        applying = true
        try {
            walk(ByteBuffer.wrap(ops).order(ByteOrder.LITTLE_ENDIAN))
        } finally {
            applying = false
        }
        if (stickies.isNotEmpty()) screen.post { stick() }
        batches++
        if (batches <= 2) {
            Rocx.say(Log.INFO, "batch $batches: ${ops.size} bytes, ${views.size} views, applied in ${SystemClock.uptimeMillis() - started} ms, ${SystemClock.uptimeMillis() - Process.getStartUptimeMillis()} ms after the process started")
        }
    }

    /** The view the host's id names, if there is one (`Rocx.focus`, `Rocx.reveal`). */
    fun view(id: Long): View? = views[id]

    private fun text(buffer: ByteBuffer): String {
        val bytes = ByteArray(buffer.int)
        buffer.get(bytes)
        return String(bytes, Charsets.UTF_8)
    }

    private fun walk(buffer: ByteBuffer) {
        while (buffer.hasRemaining()) {
            when (val op = buffer.get().toInt()) {
                1 -> {
                    val id = buffer.long
                    val kind = text(buffer)
                    val tag = text(buffer)
                    create(id, kind, tag)
                }
                2 -> {
                    val id = buffer.long
                    val key = text(buffer)
                    set(id, key, text(buffer))
                }
                3 -> {
                    val id = buffer.long
                    val ids = LongArray(buffer.int) { buffer.long }
                    children(id, ids)
                }
                4 -> destroy(buffer.long)
                5 -> root(buffer.long)
                6 -> activity.title = text(buffer)
                7 -> {
                    val id = buffer.long
                    frame(id, buffer.float, buffer.float, buffer.float, buffer.float)
                }
                8 -> {
                    val id = buffer.long
                    extent(id, buffer.float, buffer.float)
                }
                else -> throw IllegalStateException("rocx: unknown op $op")
            }
        }
    }

    private fun create(id: Long, kind: String, tag: String) {
        val context = activity
        val view: View = when (kind) {
            "box" -> Box(context)
            "text" -> TextBox(context, density)
            "scrolly", "scrollxy" -> ScrollView(context).apply {
                isNestedScrollingEnabled = true
                isVerticalScrollBarEnabled = false
                overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
                val content = Box(context)
                if (kind == "scrollxy") {
                    addView(HorizontalScrollView(context).apply {
                        isHorizontalScrollBarEnabled = false
                        addView(content)
                    }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                } else {
                    addView(content)
                }
                contents[id] = content
            }
            "scrollx" -> HorizontalScrollView(context).apply {
                isHorizontalScrollBarEnabled = false
                overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
                val content = Box(context)
                addView(content)
                contents[id] = content
            }
            "input", "textarea" -> EditText(context).apply {
                background = null
                setPadding(0, 0, 0, 0)
                includeFontPadding = false
                if (kind == "input") {
                    isSingleLine = true
                    imeOptions = EditorInfo.IME_ACTION_DONE
                    gravity = Gravity.CENTER_VERTICAL or Gravity.START
                } else {
                    inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
                    gravity = Gravity.TOP or Gravity.START
                }
                addTextChangedListener(object : TextWatcher {
                    override fun beforeTextChanged(text: CharSequence?, start: Int, count: Int, after: Int) {}
                    override fun onTextChanged(text: CharSequence?, start: Int, before: Int, count: Int) {}
                    override fun afterTextChanged(text: Editable?) {
                        if (!applying) Rocx.event(id, "input", text?.toString() ?: "")
                    }
                })
                setOnEditorActionListener { _, _, _ ->
                    Rocx.event(id, "keydown", "Enter")
                    false
                }
                setOnFocusChangeListener { _, focused ->
                    if (!applying) Rocx.event(id, if (focused) "focus" else "blur", text?.toString() ?: "")
                }
            }
            "checkbox" -> CheckBox(context).apply {
                setOnCheckedChangeListener { _, checked ->
                    if (!applying) {
                        Rocx.event(id, "click", checked.toString())
                        Rocx.event(id, "change", checked.toString())
                    }
                }
            }
            "image" -> ImageView(context).apply { scaleType = ImageView.ScaleType.FIT_XY }
            "svg" -> SvgView(context)
            "layer" -> Box(context).also { layer ->
                layer.tag = "rocx:layer"
                attachLayer(layer)
            }
            else -> Box(context)
        }
        if (kind != "layer") view.tag = "rocx:$id:<$tag>"
        views[id] = view
        kinds[id] = kind
    }

    /** The screen's layer, over the page and as big as the screen (its system bars' insets kept). */
    private fun attachLayer(layer: Box) {
        val parent = screen.parent as? ViewGroup
        if (parent == null) {
            screen.post { if (layer.parent == null) attachLayer(layer) }
            return
        }
        parent.addView(layer, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        layer.setPadding(screen.paddingLeft, screen.paddingTop, screen.paddingRight, screen.paddingBottom)
        screen.addOnLayoutChangeListener { view, _, _, _, _, _, _, _, _ ->
            if (layer.paddingTop != view.paddingTop || layer.paddingLeft != view.paddingLeft) layer.setPadding(view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom)
        }
    }

    private fun px(dp: Float): Int = (dp * density + 0.5f).toInt()

    /** The view's CSS paint, made when it first needs one. */
    private fun paintOf(view: View): CssPaint {
        (view.background as? CssPaint)?.let { return it }
        val paint = CssPaint(density)
        view.background = paint
        return paint
    }

    private fun set(id: Long, key: String, value: String) {
        val view = views[id] ?: return
        if (key.startsWith("style.")) {
            style(id, view, key.removePrefix("style."), value)
            if (view is TextBox) view.set(key, value)
            return
        }
        when (key) {
            "text", "runs" -> if (view is TextBox) view.set(key, value)
            "value" -> if (view is EditText && view.text.toString() != value) {
                view.setText(value)
                view.setSelection(value.length)
            }
            "svg" -> if (view is SvgView) view.drawing(value)
            "placeholder" -> if (view is EditText) view.hint = value
            "disabled" -> view.isEnabled = value != "true"
            "checked" -> if (view is CheckBox) view.isChecked = value == "true"
            "alt" -> view.contentDescription = value
            "click" -> if (view !is EditText && view !is CheckBox) {
                if (value == "true") {
                    view.setOnClickListener { if (!applying) Rocx.event(id, "click", "") }
                } else {
                    view.setOnClickListener(null)
                    view.isClickable = false
                }
            }
            "canvas" -> CssPaint.colour(value)?.let { colour ->
                screen.setBackgroundColor(colour)
                activity.window.decorView.setBackgroundColor(colour)
            }
            "type" -> if (view is EditText) view.inputType = when (value) {
                "password" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                "email" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                "number" -> InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
                "tel" -> InputType.TYPE_CLASS_PHONE
                "url" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
                "search" -> InputType.TYPE_CLASS_TEXT
                else -> InputType.TYPE_CLASS_TEXT
            }
        }
    }

    private fun style(id: Long, view: View, name: String, value: String) {
        when (name) {
            "background", "gradient", "border", "borderStyle", "radius", "shadow", "outline" -> {
                val paint = paintOf(view)
                paint.set(name, value)
                if (paint.empty && view !is EditText) view.background = null
            }
            "clip" -> if (view is Box) view.clip = value == "true" else (contents[id]?.let { view.clipToOutline = value == "true" })
            "opacity" -> view.alpha = value.toFloatOrNull() ?: 1f
            "visibility" -> view.visibility = if (value == "hidden") View.INVISIBLE else View.VISIBLE
            "transform" -> {
                val parts = value.split(" ").mapNotNull { it.toFloatOrNull() }
                if (parts.size == 7) {
                    view.translationX = parts[0] * density
                    view.translationY = parts[1] * density
                    cssTranslationY[id] = view.translationY
                    view.scaleX = parts[2]
                    view.scaleY = parts[3]
                    view.rotation = parts[4]
                    view.pivotX = parts[5] * density
                    view.pivotY = parts[6] * density
                } else {
                    cssTranslationY.remove(id)
                    view.translationX = 0f
                    view.translationY = 0f
                    view.scaleX = 1f
                    view.scaleY = 1f
                    view.rotation = 0f
                }
            }
            "inset" -> {
                val parts = value.split(" ").mapNotNull { it.toFloatOrNull() }
                if (parts.size == 4) view.setPadding(px(parts[3]), px(parts[0]), px(parts[1]), px(parts[2])) else view.setPadding(0, 0, 0, 0)
            }
            "untouchable" -> if (value == "true") view.setOnTouchListener { _, _ -> false }
            "sticky" -> {
                val parts = value.split(" ")
                if (parts.size == 2) stickies[id] = Pair(parts[0] == "top", parts[1].toFloatOrNull() ?: 0f) else {
                    stickies.remove(id)
                    view.translationY = cssTranslationY[id] ?: 0f
                }
            }
        }
        if (view is EditText) field(view, name, value)
    }

    /** A field's text look: its size, colour, weight, family, hint colour. */
    private fun field(view: EditText, name: String, value: String) {
        when (name) {
            "fontSize" -> value.toFloatOrNull()?.let { view.setTextSize(TypedValue.COMPLEX_UNIT_DIP, it) }
            "color" -> CssPaint.colour(value)?.let { view.setTextColor(it) }
            "hint" -> CssPaint.colour(value)?.let { view.setHintTextColor(it) }
            "fontWeight", "italic", "fontFamily" -> {
                val look = fieldLooks.getOrPut(view) { HashMap() }
                look[name] = value
                val base = when (look["fontFamily"]) {
                    "mono" -> Typeface.MONOSPACE
                    "serif" -> Typeface.SERIF
                    else -> Typeface.SANS_SERIF
                }
                view.typeface = Typeface.create(base, (look["fontWeight"]?.toIntOrNull() ?: 400).coerceIn(1, 1000), look["italic"] == "true")
            }
            "letterSpacing" -> value.toFloatOrNull()?.let { if (view.textSize > 0f) view.letterSpacing = it * density / view.textSize }
            "textAlign" -> view.gravity = (view.gravity and Gravity.VERTICAL_GRAVITY_MASK) or when (value) {
                "center" -> Gravity.CENTER_HORIZONTAL
                "right", "end" -> Gravity.END
                else -> Gravity.START
            }
        }
    }

    /** `position: sticky` views: their edge (top or not) and its offset in dp. */
    private val stickies = HashMap<Long, Pair<Boolean, Float>>()
    /** A view's CSS translation, which a sticky one's shift adds to. */
    private val cssTranslationY = HashMap<Long, Float>()

    /**
     * Each sticky view moved to keep `top` (or `bottom`) from its scroll view's edge, within its
     * parent: CSS's sticky positioning, done as the scroll goes.
     */
    private fun stick() {
        for ((id, edge) in stickies) {
            val view = views[id] ?: continue
            // Its place in the content of the nearest scroll view, and its parent's bottom there.
            var y = view.top.toFloat()
            var at: View = view
            var scroller: View? = null
            val parentBottom = ((view.parent as? View)?.height ?: 0).toFloat()
            while (true) {
                val parent = at.parent as? View ?: break
                if (parent is ScrollView) {
                    scroller = parent
                    break
                }
                y += parent.top
                at = parent
            }
            val scrolled = scroller ?: continue
            val top = view.top.toFloat()
            val parentTop = y - top
            val base = cssTranslationY[id] ?: 0f
            val shift = if (edge.first) {
                val want = scrolled.scrollY + edge.second * density - y
                want.coerceIn(0f, max(0f, parentTop + parentBottom - y - view.height))
            } else 0f
            view.translationY = base + shift
        }
    }

    /** Where a view's children go: a scrolling view's content, or the view. */
    private fun holder(id: Long): ViewGroup? = contents[id] ?: views[id] as? ViewGroup

    private fun children(id: Long, ids: LongArray) {
        val parent = holder(id) ?: return
        var at = 0
        for (childId in ids) {
            val child = views[childId] ?: continue
            if (parent.getChildAt(at) !== child) {
                (child.parent as? ViewGroup)?.removeView(child)
                parent.addView(child, at)
            }
            at++
        }
        while (parent.childCount > at) parent.removeViewAt(parent.childCount - 1)
    }

    private fun frame(id: Long, x: Float, y: Float, w: Float, h: Float) {
        val view = views[id] ?: return
        val frame = view.frame ?: Frame(0, 0, 0, 0)
        // Edges rounded on the screen's pixels, so neighbours meet.
        val left = px(x)
        val top = px(y)
        frame.x = left
        frame.y = top
        frame.width = (px(x + w) - left).coerceAtLeast(0)
        frame.height = (px(y + h) - top).coerceAtLeast(0)
        if (id == rootId) extentOf(view, frame)
        view.layoutParams = frame
        if (kinds[id] == "layer") view.layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }

    private var rootExtent = Pair(0, 0)

    private fun extentOf(view: View, frame: Frame) {
        frame.width = maxOf(frame.width, rootExtent.first)
        frame.height = maxOf(frame.height, rootExtent.second)
    }

    private fun extent(id: Long, w: Float, h: Float) {
        if (id == rootId) {
            rootExtent = Pair(px(w), px(h))
            views[id]?.let { view -> view.frame?.let { frame -> extentOf(view, frame); view.layoutParams = frame } }
            return
        }
        val content = contents[id] ?: return
        content.layoutParams = Frame(0, 0, px(w), px(h))
    }

    /** A text view's size for the host's layout (`Rocx.measure`). */
    fun measure(id: Long, mode: Int, width: Float): Pair<Float, Float> {
        val view = views[id] as? TextBox ?: return Pair(0f, 0f)
        return view.measureText(mode, width)
    }

    private fun destroy(id: Long) {
        val view = views.remove(id) ?: return
        kinds.remove(id)
        contents.remove(id)
        (view.parent as? ViewGroup)?.removeView(view)
    }

    private fun root(id: Long) {
        val view = views[id] ?: return
        rootId = id
        (view.parent as? ViewGroup)?.removeView(view)
        screen.removeAllViews()
        screen.addView(view)
    }

    /** A field's font properties, as the host last set them. */
    private val fieldLooks = java.util.WeakHashMap<EditText, HashMap<String, String>>()
}
