package dev.rocx.phone

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.text.style.BackgroundColorSpan
import android.text.style.LineHeightSpan
import android.text.style.MetricAffectingSpan
import android.text.style.StrikethroughSpan
import android.text.style.UnderlineSpan
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * A block's inline content (D-137): its text as styled runs (each run's colour, weight, italic,
 * size, family, letter spacing, decoration, background), drawn with a StaticLayout at its frame's
 * width, inside its padding and border (`style.inset`). The host lays it out with what [measure]
 * says, so what is drawn is what was measured. A run that is a link (or a tappable element's) is
 * tapped on its own: the tap goes to that element (`k`), as a click on it in a browser.
 */
open class TextBox(context: Context, private val density: Float) : View(context) {
    /** Each property the host set (`text`, `runs`, `style.fontSize`…). */
    val props = HashMap<String, String>()
    private var spanned: CharSequence? = null
    private val paint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private var laid: StaticLayout? = null
    private var laidWidth = -1
    private var pressedLink = -1L

    /** The host changed a property: the text is styled again on its next use. */
    fun set(key: String, value: String) {
        if (value.isEmpty()) props.remove(key) else props[key] = value
        spanned = null
        laid = null
        if (key == "text") contentDescription = value
        invalidate()
    }

    private fun px(dp: Float): Float = dp * density

    private fun typeface(family: String?, weight: Int, italic: Boolean): Typeface {
        val base = when (family) {
            "mono" -> Typeface.MONOSPACE
            "serif" -> Typeface.SERIF
            else -> Typeface.SANS_SERIF
        }
        return Typeface.create(base, weight.coerceIn(1, 1000), italic)
    }

    /** The paint for the view's own look (what runs differ from). */
    private fun basePaint() {
        paint.reset()
        paint.isAntiAlias = true
        paint.textSize = px(props["style.fontSize"]?.toFloatOrNull() ?: 16f)
        paint.color = CssPaint.colour(props["style.color"]) ?: Color.BLACK
        paint.typeface = typeface(props["style.fontFamily"], props["style.fontWeight"]?.toIntOrNull() ?: 400, props["style.italic"] == "true")
        val spacing = props["style.letterSpacing"]?.toFloatOrNull()
        paint.letterSpacing = if (spacing != null && paint.textSize > 0f) px(spacing) / paint.textSize else 0f
        paint.fontFeatureSettings = if (props["style.tabular"] == "true") "tnum" else null
        val decoration = props["style.decoration"] ?: ""
        paint.isUnderlineText = decoration.contains("underline")
        paint.isStrikeThruText = decoration.contains("line-through")
    }

    /** A run's look: what differs from the view's. */
    private inner class RunSpan(val size: Float?, val weight: Int?, val italic: Boolean?, val family: String?, val spacing: Float?, val color: Int?, val tabular: Boolean) : MetricAffectingSpan() {
        override fun updateMeasureState(p: TextPaint) = apply(p)
        override fun updateDrawState(p: TextPaint) {
            apply(p)
            color?.let { p.color = it }
        }
        private fun apply(p: TextPaint) {
            size?.let { p.textSize = px(it) }
            if (weight != null || italic != null || family != null) {
                p.typeface = typeface(family ?: props["style.fontFamily"], weight ?: props["style.fontWeight"]?.toIntOrNull() ?: 400, italic ?: (props["style.italic"] == "true"))
            }
            spacing?.let { if (p.textSize > 0f) p.letterSpacing = px(it) / p.textSize }
            if (tabular) p.fontFeatureSettings = "tnum"
        }
    }

    /** The element a run's tap goes to. */
    private class LinkSpan(val target: Long)

    /**
     * CSS's line-height: each line this tall (`height` px), or (`scale`, a unitless line-height)
     * its biggest run's size times it; the extra split above and below.
     */
    private class LineHeight(val height: Int, val scale: Float = 0f) : LineHeightSpan {
        override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int, lineHeight: Int, fm: Paint.FontMetricsInt) {
            // The line's own metrics come again for each line, as this left them on the last: the
            // font's top and bottom, which this leaves alone, say its size (Roboto's span 1.327 of it).
            val want = if (scale > 0f) Math.round((fm.bottom - fm.top) / 1.327f * scale) else height
            val have = fm.descent - fm.ascent
            if (have <= 0 || want <= 0) return
            val extra = want - have
            val above = Math.floorDiv(extra, 2)
            fm.ascent -= above
            fm.descent += extra - above
        }
    }

    private fun text(): CharSequence {
        spanned?.let { return it }
        basePaint()
        val raw = props["text"] ?: ""
        val out = SpannableStringBuilder(raw)
        props["runs"]?.let { json ->
            try {
                val runs = JSONArray(json)
                for (i in 0 until runs.length()) {
                    val run = runs.getJSONObject(i)
                    val start = run.optInt("s").coerceIn(0, raw.length)
                    val end = run.optInt("e").coerceIn(start, raw.length)
                    if (start == end) continue
                    val span = RunSpan(
                        run.optString("size").toFloatOrNull(),
                        run.optString("weight").toIntOrNull(),
                        if (run.has("italic")) true else null,
                        run.optString("family").ifEmpty { null },
                        run.optString("spacing").toFloatOrNull(),
                        CssPaint.colour(run.optString("color")),
                        run.optString("tabular") == "true",
                    )
                    out.setSpan(span, start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    CssPaint.colour(run.optString("bg"))?.let { out.setSpan(BackgroundColorSpan(it), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
                    val deco = run.optString("deco")
                    if (deco.contains("underline")) out.setSpan(UnderlineSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (deco.contains("line-through")) out.setSpan(StrikethroughSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (run.has("k")) out.setSpan(LinkSpan(run.optLong("k")), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            } catch (failure: Exception) {
                Rocx.say(android.util.Log.ERROR, "text: runs that aren't JSON: ${failure.message}")
            }
        }
        val scale = props["style.lineScale"]?.toFloatOrNull()
        if (scale != null) {
            out.setSpan(LineHeight(0, scale), 0, out.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        } else props["style.lineHeight"]?.toFloatOrNull()?.let { line ->
            out.setSpan(LineHeight(px(line).roundToInt()), 0, out.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        }
        spanned = out
        return out
    }

    private fun alignment(): Layout.Alignment = when (props["style.textAlign"]) {
        "center", "-webkit-center" -> Layout.Alignment.ALIGN_CENTER
        "right", "end", "-webkit-right" -> Layout.Alignment.ALIGN_OPPOSITE
        else -> Layout.Alignment.ALIGN_NORMAL
    }

    private val nowrap: Boolean get() = props["style.nowrap"] == "true"

    private fun layout(width: Int): StaticLayout {
        val text = text()
        val ellipsis = props["style.ellipsis"] == "true"
        val maxLines = props["style.maxLines"]?.toIntOrNull() ?: if (nowrap && ellipsis) 1 else Int.MAX_VALUE
        val builder = StaticLayout.Builder.obtain(text, 0, text.length, paint, max(1, width))
            .setAlignment(alignment())
            .setIncludePad(false)
            .setLineSpacing(0f, 1f)
            .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
            .setMaxLines(maxLines)
        if (ellipsis) builder.setEllipsize(TextUtils.TruncateAt.END)
        if (props["style.textAlign"] == "justify") builder.setJustificationMode(Layout.JUSTIFICATION_MODE_INTER_WORD)
        return builder.build()
    }

    /** The widest a text gets on one line (each line its own, for one with breaks). */
    private fun maxContent(): Float {
        val text = text()
        var widest = 0f
        var start = 0
        while (start <= text.length) {
            var end = text.indexOf('\n', start)
            if (end < 0) end = text.length
            widest = max(widest, Layout.getDesiredWidth(text, start, end, paint))
            start = end + 1
        }
        return widest
    }

    /** The widest word. */
    private fun minContent(): Float {
        val text = text()
        var widest = 0f
        var start = 0
        val s = text.toString()
        while (start < s.length) {
            while (start < s.length && s[start].isWhitespace()) start++
            var end = start
            while (end < s.length && !s[end].isWhitespace()) end++
            if (end > start) widest = max(widest, Layout.getDesiredWidth(text, start, end, paint))
            start = end
        }
        return widest
    }

    /**
     * The text's size at a width (`mode` 0: at most `widthDp`; 1: on as few lines as it can; 2:
     * as narrow as its words let it), in dp, its padding left out.
     */
    fun measureText(mode: Int, widthDp: Float): Pair<Float, Float> {
        text()
        val width = when (mode) {
            1 -> ceil(maxContent()).toInt() + 1
            2 -> if (nowrap) ceil(maxContent()).toInt() + 1 else ceil(minContent()).toInt() + 1
            else -> if (nowrap && props["style.ellipsis"] != "true") ceil(maxContent()).toInt() + 1 else max(1, (widthDp * density).toInt())
        }
        val layout = layout(width)
        var widest = 0f
        for (line in 0 until layout.lineCount) widest = max(widest, layout.getLineWidth(line))
        val w = if (mode == 0 && !nowrap) widest else width.toFloat()
        return Pair(ceil(w) / density, ceil(layout.height.toFloat()) / density)
    }

    override fun onDraw(canvas: Canvas) {
        val width = this.width - paddingLeft - paddingRight
        if (laid == null || laidWidth != width) {
            laid = layout(if (nowrap && props["style.ellipsis"] != "true") max(width, ceil(maxContent()).toInt() + 1) else width)
            laidWidth = width
        }
        val layout = laid ?: return
        canvas.save()
        // `overflow` other than visible: what doesn't fit is cut at the view's edges.
        if (props["style.clip"] == "true") canvas.clipRect(0, 0, this.width, this.height)
        val dx = if (nowrap && layout.width > width) when (alignment()) {
            Layout.Alignment.ALIGN_CENTER -> (width - layout.width) / 2f
            Layout.Alignment.ALIGN_OPPOSITE -> (width - layout.width).toFloat()
            else -> 0f
        } else 0f
        canvas.translate(paddingLeft + dx, paddingTop.toFloat())
        layout.draw(canvas)
        canvas.restore()
    }

    /** The link run at a point of the view, if any. */
    private fun linkAt(x: Float, y: Float): Long {
        val text = spanned as? Spanned ?: return -1
        val layout = laid ?: return -1
        val line = layout.getLineForVertical((y - paddingTop).toInt())
        val offset = layout.getOffsetForHorizontal(line, x - paddingLeft)
        val spans = text.getSpans(offset, offset, LinkSpan::class.java)
        if (spans.isEmpty()) {
            // The character before the point's (the run it ends).
            val before = text.getSpans(max(0, offset - 1), offset, LinkSpan::class.java)
            return before.firstOrNull()?.target ?: -1
        }
        return spans.first().target
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val hasLinks = props["runs"]?.contains("\"k\"") == true
        if (hasLinks) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    pressedLink = linkAt(event.x, event.y)
                    if (pressedLink >= 0) return true
                }
                MotionEvent.ACTION_UP -> if (pressedLink >= 0) {
                    val target = pressedLink
                    pressedLink = -1
                    if (linkAt(event.x, event.y) == target) Rocx.event(target, "click", "")
                    return true
                }
                MotionEvent.ACTION_CANCEL -> pressedLink = -1
            }
            if (pressedLink >= 0) return true
        }
        return super.onTouchEvent(event)
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.text = props["text"]
        info.className = "android.widget.TextView"
    }
}
