package dev.rocx.phone

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
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
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Applies a batch of the native host's ops (native/core/src/native.rs) to Android views: one call
 * a flush. Views are kept by the host's ids. A box is a LinearLayout (a column, or a row for
 * `display: flex`), text is a TextView, and buttons, fields and checkboxes are the platform's own.
 * Margins between a column's children collapse, as CSS's do.
 */
class Applier(val activity: Activity, private val screen: ViewGroup) {
    private val views = HashMap<Long, View>()
    private val kinds = HashMap<Long, String>()
    /** Each view's style properties (`style.margin`…), as the host last set them. */
    private val styles = HashMap<Long, HashMap<String, String>>()
    private val density = activity.resources.displayMetrics.density
    /** While a batch is applied: what the applier does to a field isn't the user's typing. */
    private var applying = false
    private var batches = 0

    fun apply(ops: ByteArray) {
        val started = SystemClock.uptimeMillis()
        applying = true
        try {
            walk(ByteBuffer.wrap(ops).order(ByteOrder.LITTLE_ENDIAN))
        } finally {
            applying = false
        }
        batches++
        if (batches == 1) {
            Log.i("rocx", "first batch: ${ops.size} bytes, ${views.size} views, applied in ${SystemClock.uptimeMillis() - started} ms, ${SystemClock.uptimeMillis() - Process.getStartUptimeMillis()} ms after the process started")
        }
    }

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
                else -> throw IllegalStateException("rocx: unknown op $op")
            }
        }
    }

    private fun create(id: Long, kind: String, tag: String) {
        val context = activity
        val view: View = when (kind) {
            "box" -> LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
            "text" -> TextView(context).apply {
                setTextColor(Color.parseColor("#1b1b1f"))
                setTextIsSelectable(false)
            }
            "button" -> Button(context).apply {
                isAllCaps = false
                setOnClickListener { if (!applying) Rocx.event(id, "click", "") }
            }
            "input", "textarea" -> EditText(context).apply {
                if (kind == "input") {
                    isSingleLine = true
                    imeOptions = EditorInfo.IME_ACTION_DONE
                } else {
                    inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
                    minLines = 3
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
            "image" -> ImageView(context)
            else -> View(context)
        }
        view.tag = "rocx:$id:<$tag>"
        views[id] = view
        kinds[id] = kind
        defaults(view, tag)
    }

    /** What a view looks like before the app's CSS: the phone's user-agent sheet's, for a field. */
    private fun defaults(view: View, tag: String) {
        if (view is TextView && view !is Button && view !is EditText) {
            view.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        }
        if (view is EditText) view.minWidth = px(200f)
    }

    private fun px(dp: Float): Int = (dp * density + 0.5f).toInt()

    private fun set(id: Long, key: String, value: String) {
        val view = views[id] ?: return
        if (key.startsWith("style.")) {
            val name = key.removePrefix("style.")
            val all = styles.getOrPut(id) { HashMap() }
            if (value.isEmpty()) all.remove(name) else all[name] = value
            style(id, view, name, value)
            return
        }
        when (key) {
            "text" -> if (view is TextView && view.text.toString() != value) view.text = value
            "value" -> if (view is EditText && view.text.toString() != value) {
                view.setText(value)
                view.setSelection(value.length)
            }
            "placeholder" -> if (view is TextView) view.hint = value
            "disabled" -> view.isEnabled = value != "true"
            "checked" -> if (view is CheckBox) view.isChecked = value == "true"
            "alt" -> view.contentDescription = value
            "type" -> if (view is EditText) view.inputType = when (value) {
                "password" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                "email" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                "number" -> InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
                "tel" -> InputType.TYPE_CLASS_PHONE
                "url" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
                else -> InputType.TYPE_CLASS_TEXT
            }
        }
    }

    private fun sides(value: String?): IntArray {
        val parts = value?.split(" ")?.mapNotNull { it.toFloatOrNull() } ?: emptyList()
        return if (parts.size == 4) IntArray(4) { px(parts[it]) } else IntArray(4)
    }

    private fun style(id: Long, view: View, name: String, value: String) {
        val all = styles[id] ?: HashMap()
        when (name) {
            "padding" -> sides(value).let { view.setPadding(it[3], it[0], it[1], it[2]) }
            "background", "radius", "border" -> view.background = GradientDrawable().apply {
                all["background"]?.let { setColor(Color.parseColor(it)) }
                all["radius"]?.toFloatOrNull()?.let { cornerRadius = it * density }
                all["border"]?.split(" ")?.let { parts ->
                    if (parts.size == 2) setStroke(px(parts[0].toFloat()), Color.parseColor(parts[1]))
                }
            }
            "color" -> if (view is TextView && value.isNotEmpty()) view.setTextColor(Color.parseColor(value))
            "fontSize" -> if (view is TextView) value.toFloatOrNull()?.let { view.setTextSize(TypedValue.COMPLEX_UNIT_SP, it) }
            "fontWeight", "italic" -> if (view is TextView) {
                val weight = all["fontWeight"]?.toIntOrNull() ?: 400
                view.typeface = Typeface.create(Typeface.DEFAULT, weight.coerceIn(1, 1000), all["italic"] == "true")
            }
            "textAlign" -> if (view is TextView) view.gravity = when (value) {
                "center" -> Gravity.CENTER_HORIZONTAL
                "right", "end" -> Gravity.END
                else -> Gravity.START
            }
            "textTransform" -> if (view is TextView) view.isAllCaps = value == "uppercase"
            "direction" -> if (view is LinearLayout) {
                view.orientation = if (value == "row") LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
                layoutChildren(view, id)
            }
            "gap", "alignItems", "justify" -> if (view is LinearLayout) layoutChildren(view, id)
            "opacity" -> view.alpha = value.toFloatOrNull() ?: 1f
            "margin", "width", "height" -> (view.parent as? LinearLayout)?.let { parent ->
                parentId(parent)?.let { layoutChildren(parent, it) }
            }
        }
    }

    private fun parentId(view: View): Long? = views.entries.firstOrNull { it.value === view }?.key

    private fun children(id: Long, ids: LongArray) {
        val parent = views[id] as? ViewGroup ?: return
        ids.forEachIndexed { at, childId ->
            val child = views[childId] ?: return@forEachIndexed
            if (parent.getChildAt(at) !== child) {
                (child.parent as? ViewGroup)?.removeView(child)
                parent.addView(child, at)
            }
        }
        while (parent.childCount > ids.size) parent.removeViewAt(parent.childCount - 1)
        if (parent is LinearLayout) layoutChildren(parent, id)
    }

    /**
     * A box's children's layout: a column's blocks as wide as it, its buttons and checkboxes as
     * wide as what they say; a row's children as wide as they are. Margins (collapsed between a
     * column's children, as CSS's are), the box's `gap`, and its alignment.
     */
    private fun layoutChildren(parent: LinearLayout, parentId: Long) {
        val column = parent.orientation == LinearLayout.VERTICAL
        val own = styles[parentId] ?: emptyMap<String, String>()
        val gap = own["gap"]?.toFloatOrNull()?.let { px(it) } ?: 0
        parent.gravity = when (own[if (column) "alignItems" else "justify"]) {
            "center" -> if (column) Gravity.CENTER_HORIZONTAL else Gravity.CENTER_HORIZONTAL or Gravity.CENTER_VERTICAL
            "flex-end", "end", "right" -> Gravity.END
            else -> Gravity.START
        } or if (!column && own["alignItems"] == "center") Gravity.CENTER_VERTICAL else 0
        var below = 0
        for (at in 0 until parent.childCount) {
            val child = parent.getChildAt(at)
            val childId = views.entries.firstOrNull { it.value === child }?.key
            val kind = childId?.let { kinds[it] }
            val style = childId?.let { styles[it] } ?: emptyMap<String, String>()
            val margin = sides(style["margin"])
            val shrinks = kind == "button" || kind == "checkbox" || kind == "image"
            val width = style["width"]?.toFloatOrNull()?.let { px(it) }
                ?: if (column && !shrinks) ViewGroup.LayoutParams.MATCH_PARENT else ViewGroup.LayoutParams.WRAP_CONTENT
            val height = style["height"]?.toFloatOrNull()?.let { px(it) } ?: ViewGroup.LayoutParams.WRAP_CONTENT
            val params = LinearLayout.LayoutParams(width, height)
            if (column) {
                // Collapsed with the margin below the child before it.
                val top = if (at == 0) margin[0] else maxOf(margin[0], below) - below + gap
                params.setMargins(margin[3], top, margin[1], margin[2])
                below = margin[2]
            } else {
                params.setMargins(margin[3] + if (at == 0) 0 else gap, margin[0], margin[1], margin[2])
            }
            child.layoutParams = params
        }
    }

    private fun destroy(id: Long) {
        val view = views.remove(id) ?: return
        kinds.remove(id)
        styles.remove(id)
        (view.parent as? ViewGroup)?.removeView(view)
    }

    private fun root(id: Long) {
        val view = views[id] ?: return
        (view.parent as? ViewGroup)?.removeView(view)
        screen.removeAllViews()
        screen.addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
}
