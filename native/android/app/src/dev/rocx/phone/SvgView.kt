package dev.rocx.phone

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.Typeface
import android.view.View
import org.json.JSONArray
import org.json.JSONObject

/**
 * An `<svg>`: the shapes the native host made of it (native/core/src/svg.rs), drawn on a canvas.
 * Its `svg` property is `{"box":[x,y,w,h],"items":[…]}`: each item a plain path (`M`, `L`, `C`, `Q`,
 * `Z`, absolute) with its fill and stroke (`#AARRGGBB`), stroke width, cap, join, dashes (measured
 * in `length` units, a `pathLength`, when it has one) and matrix, or a text at a point. The viewBox
 * is fitted to the view and centred, as SVG's `xMidYMid meet`; with none, a user unit is a CSS px.
 * With no height of its own the view is as tall as the viewBox's shape at its width.
 */
class SvgView(context: Context) : View(context) {
    private class Item(
        val path: Path?,
        val text: String?,
        val x: Float,
        val y: Float,
        val fill: Paint?,
        val stroke: Paint?,
        val matrix: Matrix?,
    )

    private val density = context.resources.displayMetrics.density
    private var said = ""
    private var box: FloatArray? = null
    private var items: List<Item> = emptyList()

    fun drawing(json: String) {
        if (json == said) return
        said = json
        val drawing = try {
            JSONObject(json)
        } catch (failure: Exception) {
            Rocx.say(android.util.Log.ERROR, "svg: a drawing that isn't JSON: ${failure.message}")
            JSONObject()
        }
        val newBox = drawing.optJSONArray("box")?.let { box -> FloatArray(4) { box.optDouble(it).toFloat() } }
        if (!newBox.contentEquals(box)) {
            box = newBox
            requestLayout()
        }
        val list = drawing.optJSONArray("items") ?: JSONArray()
        items = (0 until list.length()).mapNotNull { item(list.optJSONObject(it) ?: return@mapNotNull null) }
        invalidate()
    }

    /** A colour the host sent (`#AARRGGBB`); none for none (`""`, or one Android can't read). */
    private fun colour(value: String?): Int? {
        if (value.isNullOrEmpty()) return null
        return try {
            Color.parseColor(value)
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun item(json: JSONObject): Item? {
        val matrix = json.optJSONArray("m")?.let { m ->
            Matrix().apply {
                val v = FloatArray(6) { m.optDouble(it).toFloat() }
                // SVG's matrix(a b c d e f) is Android's [a c e; b d f; 0 0 1].
                setValues(floatArrayOf(v[0], v[2], v[4], v[1], v[3], v[5], 0f, 0f, 1f))
            }
        }
        if (json.has("text")) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = colour(json.optString("fill")) ?: Color.BLACK
                textSize = json.optDouble("size", 16.0).toFloat()
                val weight = json.optString("weight", "400").toIntOrNull() ?: 400
                typeface = Typeface.create(Typeface.DEFAULT, weight.coerceIn(1, 1000), false)
                if (json.optBoolean("tabular")) fontFeatureSettings = "tnum"
                textAlign = when (json.optString("anchor")) {
                    "middle" -> Paint.Align.CENTER
                    "end" -> Paint.Align.RIGHT
                    else -> Paint.Align.LEFT
                }
            }
            return Item(null, json.optString("text"), json.optDouble("x").toFloat(), json.optDouble("y").toFloat(), paint, null, matrix)
        }
        val path = path(json.optString("d"))
        val fill = colour(json.optString("fill", ""))?.let { fill ->
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.FILL
                color = fill
            }
        }
        val stroke = colour(json.optString("stroke", ""))?.let { stroke ->
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                color = stroke
                strokeWidth = json.optDouble("width", 1.0).toFloat()
                strokeCap = when (json.optString("cap")) {
                    "round" -> Paint.Cap.ROUND
                    "square" -> Paint.Cap.SQUARE
                    else -> Paint.Cap.BUTT
                }
                strokeJoin = when (json.optString("join")) {
                    "round" -> Paint.Join.ROUND
                    "bevel" -> Paint.Join.BEVEL
                    else -> Paint.Join.MITER
                }
                json.optJSONArray("dash")?.let { given ->
                    var dash = FloatArray(given.length()) { given.optDouble(it).toFloat() }
                    var offset = json.optDouble("offset", 0.0).toFloat()
                    // A pathLength: the dashes are in its units, the path's own length is what it says.
                    val length = json.optDouble("length", 0.0).toFloat()
                    if (length > 0f) {
                        val measure = PathMeasure(path, false)
                        var real = 0f
                        do {
                            real += measure.length
                        } while (measure.nextContour())
                        val scale = real / length
                        dash = FloatArray(dash.size) { dash[it] * scale }
                        offset *= scale
                    }
                    val total = dash.sum()
                    if (dash.size >= 2 && total > 0f) {
                        // Android's phase is the same as SVG's offset, but only from 0 up.
                        pathEffect = DashPathEffect(dash, ((offset % total) + total) % total)
                    }
                }
            }
        }
        if (fill == null && stroke == null) return null
        return Item(path, null, 0f, 0f, fill, stroke, matrix)
    }

    /** A plain path's text, as svg.rs writes it. */
    private fun path(d: String): Path {
        val path = Path()
        val tokens = d.split(' ').filter { it.isNotEmpty() }
        var at = 0
        fun n(): Float = tokens.getOrNull(at++)?.toFloatOrNull() ?: 0f
        while (at < tokens.size) {
            when (tokens[at++]) {
                "M" -> path.moveTo(n(), n())
                "L" -> path.lineTo(n(), n())
                "C" -> path.cubicTo(n(), n(), n(), n(), n(), n())
                "Q" -> path.quadTo(n(), n(), n(), n())
                "Z" -> path.close()
            }
        }
        return path
    }

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        val box = box
        val width = when (MeasureSpec.getMode(widthSpec)) {
            MeasureSpec.UNSPECIFIED -> ((box?.get(2) ?: 300f) * density).toInt()
            else -> MeasureSpec.getSize(widthSpec)
        }
        val natural = if (box != null && box[2] > 0f) (width * box[3] / box[2]).toInt() else (150 * density).toInt()
        val height = when (MeasureSpec.getMode(heightSpec)) {
            MeasureSpec.EXACTLY -> MeasureSpec.getSize(heightSpec)
            MeasureSpec.AT_MOST -> minOf(natural, MeasureSpec.getSize(heightSpec))
            else -> natural
        }
        setMeasuredDimension(width, height)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = (width - paddingLeft - paddingRight).toFloat()
        val h = (height - paddingTop - paddingBottom).toFloat()
        if (w <= 0f || h <= 0f) return
        canvas.save()
        canvas.clipRect(paddingLeft.toFloat(), paddingTop.toFloat(), paddingLeft + w, paddingTop + h)
        canvas.translate(paddingLeft.toFloat(), paddingTop.toFloat())
        val box = box
        if (box != null && box[2] > 0f && box[3] > 0f) {
            val scale = minOf(w / box[2], h / box[3])
            canvas.translate((w - box[2] * scale) / 2f, (h - box[3] * scale) / 2f)
            canvas.scale(scale, scale)
            canvas.translate(-box[0], -box[1])
        } else {
            canvas.scale(density, density)
        }
        for (item in items) {
            canvas.save()
            item.matrix?.let { canvas.concat(it) }
            val path = item.path
            if (path != null) {
                item.fill?.let { canvas.drawPath(path, it) }
                item.stroke?.let { canvas.drawPath(path, it) }
            } else if (item.text != null && item.fill != null) {
                canvas.drawText(item.text, item.x, item.y, item.fill)
            }
            canvas.restore()
        }
        canvas.restore()
    }
}
