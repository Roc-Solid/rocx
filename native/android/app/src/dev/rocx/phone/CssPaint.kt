package dev.rocx.phone

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.drawable.Drawable
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * A view's CSS paint (D-137), drawn as its background: its shadow (`box-shadow`'s first outer one,
 * which may spill outside the view), its background (a colour, or a linear, radial or conic
 * gradient), its borders (each side's width and colour, solid, dashed or dotted), its corners'
 * radii (each corner's, px or a percentage of the box) and its outline. The host sends each as a
 * `style.*` property (native/core/src/native.rs's `paint`), in dp.
 */
class CssPaint(private val density: Float) : Drawable() {
    var background: Int? = null
    var gradient: String? = null
    /** Each side's width in dp (top right bottom left) and colour. */
    var borderWidths = FloatArray(4)
    var borderColours = IntArray(4)
    var borderStyle: String? = null
    /** Each corner's radius (top-left, top-right, bottom-right, bottom-left): dp, or a percentage if [radiusPercent]. */
    var radii = FloatArray(4)
    var radiusPercent = BooleanArray(4)
    var shadow: FloatArray? = null
    var shadowColour = 0
    /** An inset shadow drawn as a ring inside the box (`inset 0 0 0 2px`): its width in dp. */
    var ring = 0f
    var ringColour = 0
    var outline: FloatArray? = null
    var outlineColour = 0

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val shade = Paint(Paint.ANTI_ALIAS_FLAG)
    private var shadersFor = ""
    private var shaders: List<Shader> = emptyList()

    val empty: Boolean
        get() = background == null && gradient == null && borderWidths.all { it == 0f } && shadow == null && outline == null && ring == 0f

    fun hasCorners(): Boolean = radii.any { it > 0f }

    /** The corners' radii in px for a box of `w` by `h`, as CSS scales them down when they don't fit. */
    private fun cornerRadii(w: Float, h: Float): FloatArray {
        val r = FloatArray(4) { i -> if (radiusPercent[i]) radii[i] / 100f * min(w, h) else radii[i] * density }
        var scale = 1f
        if (r[0] + r[1] > w) scale = min(scale, w / (r[0] + r[1]))
        if (r[3] + r[2] > w) scale = min(scale, w / (r[3] + r[2]))
        if (r[0] + r[3] > h) scale = min(scale, h / (r[0] + r[3]))
        if (r[1] + r[2] > h) scale = min(scale, h / (r[1] + r[2]))
        return if (scale < 1f) FloatArray(4) { r[it] * scale } else r
    }

    /** A rounded rectangle, its corners these radii (px), less `inset` on every side. */
    private fun rounded(rect: RectF, r: FloatArray, inset: Float = 0f): Path {
        val box = RectF(rect.left + inset, rect.top + inset, rect.right - inset, rect.bottom - inset)
        val a = FloatArray(8) { i -> max(0f, r[i / 2] - inset) }
        return Path().apply { addRoundRect(box, a, Path.Direction.CW) }
    }

    /** What a box with this paint clips its children to: its padding box's corners. */
    fun clipPath(w: Int, h: Int): Path {
        val rect = RectF(0f, 0f, w.toFloat(), h.toFloat())
        val r = cornerRadii(rect.width(), rect.height())
        val inset = (borderWidths.maxOrNull() ?: 0f) * density
        return if (r.any { it > 0f }) rounded(rect, r, inset) else Path().apply { addRect(RectF(rect.left + borderWidths[3] * density, rect.top + borderWidths[0] * density, rect.right - borderWidths[1] * density, rect.bottom - borderWidths[2] * density), Path.Direction.CW) }
    }

    override fun draw(canvas: Canvas) {
        val bounds = RectF(bounds)
        if (bounds.width() <= 0f || bounds.height() <= 0f) return
        val r = cornerRadii(bounds.width(), bounds.height())
        val outer = rounded(bounds, r)
        shadow?.let { s ->
            // x y blur spread: the shape grown by the spread, moved, blurred (Android's radius is
            // about half CSS's blur).
            val spread = s[3] * density
            val box = RectF(bounds.left - spread + s[0] * density, bounds.top - spread + s[1] * density, bounds.right + spread + s[0] * density, bounds.bottom + spread + s[1] * density)
            val radii = FloatArray(4) { max(0f, r[it] + spread) }
            shade.color = shadowColour
            val blur = s[2] * density / 2f
            if (blur > 0.5f) shade.setShadowLayer(blur, 0f, 0f, shadowColour) else shade.clearShadowLayer()
            canvas.save()
            // Only around the box, as CSS draws an outer shadow: never under it (a translucent
            // background doesn't show it).
            canvas.clipOutPath(outer)
            canvas.drawPath(rounded(box, radii), shade)
            canvas.restore()
        }
        background?.let {
            fill.shader = null
            fill.color = it
            canvas.drawPath(outer, fill)
        }
        gradient?.let { g ->
            // Each layer, the bottom one first.
            val key = "$g ${bounds.width()} ${bounds.height()}"
            if (key != shadersFor) {
                shaders = g.split(" | ").mapNotNull { shader(it, bounds) }
                shadersFor = key
            }
            fill.color = Color.BLACK
            for (layer in shaders) {
                fill.shader = layer
                canvas.drawPath(outer, fill)
            }
            fill.shader = null
        }
        if (ring > 0f) {
            stroke.pathEffect = null
            stroke.strokeWidth = ring * density
            stroke.color = ringColour
            canvas.drawPath(rounded(bounds, r, ring * density / 2f), stroke)
        }
        drawBorders(canvas, bounds, r)
        outline?.let { o ->
            val width = o[0] * density
            val offset = o[1] * density
            stroke.pathEffect = null
            stroke.strokeWidth = width
            stroke.color = outlineColour
            val grow = offset + width / 2f
            val box = RectF(bounds.left - grow, bounds.top - grow, bounds.right + grow, bounds.bottom + grow)
            canvas.drawPath(rounded(box, FloatArray(4) { if (r[it] > 0f) r[it] + grow else 0f }), stroke)
        }
    }

    private fun drawBorders(canvas: Canvas, bounds: RectF, r: FloatArray) {
        val w = FloatArray(4) { borderWidths[it] * density }
        if (w.all { it <= 0f }) return
        val sameWidth = w.all { abs(it - w[0]) < 0.01f }
        val sameColour = borderColours.all { it == borderColours[0] }
        stroke.pathEffect = when (borderStyle) {
            "dashed" -> DashPathEffect(floatArrayOf(w[0] * 3f, w[0] * 2f), 0f)
            "dotted" -> DashPathEffect(floatArrayOf(w[0], w[0]), 0f)
            else -> null
        }
        if (sameWidth && sameColour) {
            stroke.strokeWidth = w[0]
            stroke.color = borderColours[0]
            canvas.drawPath(rounded(bounds, r, w[0] / 2f), stroke)
            return
        }
        // Sides apart: each a band along its edge (corners rounded by the clip of the outer shape).
        fill.shader = null
        canvas.save()
        if (r.any { it > 0f }) canvas.clipPath(rounded(bounds, r))
        val sides = arrayOf(
            RectF(bounds.left, bounds.top, bounds.right, bounds.top + w[0]),
            RectF(bounds.right - w[1], bounds.top, bounds.right, bounds.bottom),
            RectF(bounds.left, bounds.bottom - w[2], bounds.right, bounds.bottom),
            RectF(bounds.left, bounds.top, bounds.left + w[3], bounds.bottom),
        )
        for (side in 0 until 4) {
            if (w[side] <= 0f || Color.alpha(borderColours[side]) == 0) continue
            fill.color = borderColours[side]
            canvas.drawRect(sides[side], fill)
        }
        canvas.restore()
    }

    /** A gradient's shader: `linear <deg>`, `radial` or `conic <deg>`, then `#AARRGGBB@<0..1>` stops. */
    private fun shader(spec: String, b: RectF): Shader? {
        val words = spec.split(" ")
        val kind = words.firstOrNull() ?: return null
        val hasAngle = kind == "linear" || kind == "conic"
        val angle = if (hasAngle) words.getOrNull(1)?.toFloatOrNull() ?: 180f else 0f
        val head = when (kind) {
            "radial" -> 5
            "linear", "conic" -> 2
            else -> 1
        }
        val stops = words.drop(head).mapNotNull { stop ->
            val (colour, at) = stop.split("@").let { if (it.size == 2) it[0] to it[1] else return@mapNotNull null }
            try {
                Color.parseColor(colour) to (at.toFloatOrNull() ?: 0f)
            } catch (_: IllegalArgumentException) {
                null
            }
        }
        if (stops.size < 2) return null
        val colours = stops.map { it.first }.toIntArray()
        val positions = stops.map { it.second.coerceIn(0f, 1f) }.toFloatArray()
        val cx = b.centerX()
        val cy = b.centerY()
        return when (kind) {
            "linear" -> {
                // CSS's angle: 0 is up, clockwise; the line's length reaches the corners.
                val rad = Math.toRadians(angle.toDouble())
                val dx = sin(rad).toFloat()
                val dy = -cos(rad).toFloat()
                val half = abs(b.width() / 2f * dx) + abs(b.height() / 2f * dy)
                LinearGradient(cx - dx * half, cy - dy * half, cx + dx * half, cy + dy * half, colours, positions, Shader.TileMode.CLAMP)
            }
            "radial" -> {
                // `radial cx cy rx ry`: the centre as shares of the box, each radius a share, px or
                // a keyword (fc farthest-corner, fs farthest-side, cc closest-corner, cs closest-side).
                val x = b.left + (words.getOrNull(1)?.toFloatOrNull() ?: 0.5f) * b.width()
                val y = b.top + (words.getOrNull(2)?.toFloatOrNull() ?: 0.5f) * b.height()
                val dx = max(x - b.left, b.right - x)
                val dy = max(y - b.top, b.bottom - y)
                val nx = min(x - b.left, b.right - x)
                val ny = min(y - b.top, b.bottom - y)
                fun radius(word: String?, side: Float, far: Float, near: Float, farCorner: Float, nearCorner: Float): Float = when {
                    word == null || word == "fc" -> farCorner
                    word == "fs" -> far
                    word == "cs" -> near
                    word == "cc" -> nearCorner
                    word.endsWith("%") -> (word.removeSuffix("%").toFloatOrNull() ?: 50f) / 100f * side
                    word.endsWith("px") -> (word.removeSuffix("px").toFloatOrNull() ?: 0f) * density
                    else -> farCorner
                }
                val circle = words.getOrNull(4) == "="
                val farCorner = kotlin.math.hypot(dx, dy)
                val nearCorner = kotlin.math.hypot(nx, ny)
                // An ellipse's farthest corner: its radii in the box's ratio, reaching that corner.
                val rx = max(1f, radius(words.getOrNull(3), b.width(), dx, nx, if (circle) farCorner else dx * kotlin.math.sqrt(2f), if (circle) nearCorner else nx * kotlin.math.sqrt(2f)))
                val ry = if (circle) rx else max(1f, radius(words.getOrNull(4), b.height(), dy, ny, dy * kotlin.math.sqrt(2f), ny * kotlin.math.sqrt(2f)))
                RadialGradient(x, y, rx, colours, positions, Shader.TileMode.CLAMP).also { radial ->
                    if (abs(rx - ry) > 0.5f) radial.setLocalMatrix(android.graphics.Matrix().apply { setScale(1f, ry / rx, x, y) })
                }
            }
            else -> SweepGradient(cx, cy, colours, positions).also { sweep ->
                sweep.setLocalMatrix(android.graphics.Matrix().apply { setRotate(angle - 90f, cx, cy) })
            }
        }
    }

    override fun setAlpha(alpha: Int) {}
    override fun setColorFilter(colorFilter: ColorFilter?) {}
    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

    /** Sets one of the host's paint properties; whether it was one. */
    fun set(name: String, value: String): Boolean {
        when (name) {
            "background" -> background = colour(value)
            "gradient" -> gradient = value.ifEmpty { null }
            "border" -> {
                val parts = value.split(" ")
                if (parts.size == 8) {
                    borderWidths = FloatArray(4) { parts[it].toFloatOrNull() ?: 0f }
                    borderColours = IntArray(4) { colour(parts[4 + it]) ?: Color.TRANSPARENT }
                } else {
                    borderWidths = FloatArray(4)
                }
            }
            "borderStyle" -> borderStyle = value.ifEmpty { null }
            "radius" -> {
                val parts = value.split(" ")
                if (parts.size == 4) {
                    radii = FloatArray(4) { parts[it].removeSuffix("%").toFloatOrNull() ?: 0f }
                    radiusPercent = BooleanArray(4) { parts[it].endsWith("%") }
                } else {
                    radii = FloatArray(4)
                }
            }
            "shadow" -> {
                val parts = value.split(" ")
                if (parts.size == 5) {
                    shadow = FloatArray(4) { parts[it].toFloatOrNull() ?: 0f }
                    shadowColour = colour(parts[4]) ?: Color.TRANSPARENT
                } else {
                    shadow = null
                }
            }
            "ring" -> {
                val parts = value.split(" ")
                ring = if (parts.size == 2) parts[0].toFloatOrNull() ?: 0f else 0f
                ringColour = if (parts.size == 2) colour(parts[1]) ?: Color.TRANSPARENT else 0
            }
            "outline" -> {
                val parts = value.split(" ")
                if (parts.size == 3) {
                    outline = floatArrayOf(parts[0].toFloatOrNull() ?: 0f, parts[1].toFloatOrNull() ?: 0f)
                    outlineColour = colour(parts[2]) ?: Color.TRANSPARENT
                } else {
                    outline = null
                }
            }
            else -> return false
        }
        invalidateSelf()
        return true
    }

    companion object {
        /** A colour the host sent (`#AARRGGBB`); none for none. */
        fun colour(value: String?): Int? {
            if (value.isNullOrEmpty()) return null
            return try {
                Color.parseColor(value)
            } catch (_: IllegalArgumentException) {
                null
            }
        }
    }
}
