package dev.rocx.phone

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.widget.CompoundButton

/**
 * A checkbox's or radio's look as a browser draws one (D-141): as big as its box (13 px by CSS's
 * default, or what the page sets), a ring or a rounded square, filled with `accent-color` once
 * checked (a radio's dot, a checkbox's tick), light or dark as the page's canvas is. The platform's
 * own buttons are some 32 dp whatever their box, so they spilled over what followed them.
 */
class ControlDrawable(private val radio: Boolean, private val view: CompoundButton) : Drawable() {
    var checked = false
    var enabled = true
    /** `accent-color` (#AARRGGBB), or none: the browser's blue. */
    var accent: Int? = null
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val box = RectF()
    private val tick = Path()

    override fun onStateChange(state: IntArray): Boolean {
        val now = state.contains(android.R.attr.state_checked)
        val on = state.contains(android.R.attr.state_enabled)
        if (now == checked && on == enabled) return false
        checked = now
        enabled = on
        invalidateSelf()
        return true
    }

    override fun isStateful(): Boolean = true

    // As big as the view (CompoundButton draws its button at the button's own size).
    override fun getIntrinsicWidth(): Int = view.width

    override fun getIntrinsicHeight(): Int = view.height

    override fun draw(canvas: Canvas) {
        val bounds = bounds
        val size = minOf(bounds.width(), bounds.height()).toFloat()
        if (size <= 0f) return
        val dark = Dialogs.dark
        val colour = accent ?: if (dark) Color.parseColor("#99C8FF") else Color.parseColor("#0075FF")
        val stroke = maxOf(1f, size / 13f)
        box.set(bounds.exactCenterX() - size / 2 + stroke / 2, bounds.exactCenterY() - size / 2 + stroke / 2, bounds.exactCenterX() + size / 2 - stroke / 2, bounds.exactCenterY() + size / 2 - stroke / 2)
        val corner = if (radio) size / 2 else size * 2 / 13
        paint.alpha = 255
        if (!checked || radio) {
            // The unchecked face: a light field with a grey edge, or a dark one.
            paint.style = Paint.Style.FILL
            paint.color = if (dark) Color.parseColor("#3B3B3B") else Color.WHITE
            canvas.drawRoundRect(box, corner, corner, paint)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = stroke
            paint.color = if (checked) colour else if (dark) Color.parseColor("#858585") else Color.parseColor("#767676")
            canvas.drawRoundRect(box, corner, corner, paint)
        }
        if (checked && radio) {
            paint.style = Paint.Style.FILL
            paint.color = colour
            canvas.drawCircle(box.centerX(), box.centerY(), size * 0.27f, paint)
        } else if (checked) {
            paint.style = Paint.Style.FILL
            paint.color = colour
            canvas.drawRoundRect(box, corner, corner, paint)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = size * 0.14f
            paint.strokeCap = Paint.Cap.ROUND
            paint.strokeJoin = Paint.Join.ROUND
            paint.color = if (luminance(colour) > 0.6) Color.BLACK else Color.WHITE
            tick.reset()
            tick.moveTo(box.left + size * 0.24f, box.top + size * 0.52f)
            tick.lineTo(box.left + size * 0.42f, box.top + size * 0.70f)
            tick.lineTo(box.left + size * 0.76f, box.top + size * 0.32f)
            canvas.drawPath(tick, paint)
        }
        if (!enabled) {
            paint.style = Paint.Style.FILL
            paint.color = if (dark) Color.argb(110, 0, 0, 0) else Color.argb(110, 255, 255, 255)
            canvas.drawRoundRect(box, corner, corner, paint)
        }
    }

    private fun luminance(colour: Int): Double = (Color.red(colour) * 0.299 + Color.green(colour) * 0.587 + Color.blue(colour) * 0.114) / 255

    override fun setAlpha(alpha: Int) {}

    override fun setColorFilter(filter: ColorFilter?) {}

    @Deprecated("Drawable's")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

    companion object {
        /** A checkbox or radio given the browser's look, sized by its box. */
        fun on(button: CompoundButton, radio: Boolean) {
            button.buttonDrawable = ControlDrawable(radio, button)
            button.background = null
            button.setPadding(0, 0, 0, 0)
            button.minWidth = 0
            button.minHeight = 0
        }
    }
}
