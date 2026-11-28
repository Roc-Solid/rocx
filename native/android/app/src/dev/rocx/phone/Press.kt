package dev.rocx.phone

import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import android.graphics.drawable.RippleDrawable
import android.view.View

/**
 * A tappable view's feedback while a finger is on it (D-142): Android's ripple, as its apps' buttons,
 * links and rows give one, in the colour the host says (`press`: the element's own colour, faint, or
 * the page's `-webkit-tap-highlight-color`), shaped as the element's CSS box (its corners). The
 * host sends none for an element the page styles while pressed (`:active`), which is the page's own
 * feedback, or one whose highlight is transparent. The view's own pressed state shows it: Android's
 * tap timeout inside what scrolls, and none for a finger that scrolls away.
 */
object Press {
    fun on(view: View, value: String) {
        val colour = CssPaint.colour(value)
        val ripple = view.foreground as? RippleDrawable
        if (colour == null) {
            if (ripple != null) view.foreground = null
            return
        }
        if (ripple != null) {
            ripple.setColor(ColorStateList.valueOf(colour))
            return
        }
        view.foreground = RippleDrawable(ColorStateList.valueOf(colour), null, Mask(view))
    }

    /** Where the ripple shows: the view's border box, its corners rounded as its paint's. */
    private class Mask(private val view: View) : Drawable() {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }

        override fun draw(canvas: Canvas) {
            val paint = view.background as? CssPaint
            if (paint != null && paint.hasCorners()) {
                canvas.save()
                canvas.translate(bounds.left.toFloat(), bounds.top.toFloat())
                canvas.drawPath(paint.shape(bounds.width(), bounds.height()), fill)
                canvas.restore()
            } else {
                canvas.drawRect(bounds, fill)
            }
        }

        override fun setAlpha(alpha: Int) {}
        override fun setColorFilter(colorFilter: ColorFilter?) {}

        @Deprecated("Deprecated in Java")
        override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
    }
}
