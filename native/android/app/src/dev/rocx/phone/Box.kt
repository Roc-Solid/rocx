package dev.rocx.phone

import android.content.Context
import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout

/**
 * Where a view is in its parent and how big it is, in px, as the native host's layout (Taffy, in
 * native/core) put it: the FRAME op's. A FrameLayout's params, so scroll views (FrameLayouts) take
 * them too.
 */
class Frame(var x: Int, var y: Int, w: Int, h: Int) : FrameLayout.LayoutParams(w, h)

/** A view's frame, if the host gave it one. */
val View.frame: Frame? get() = layoutParams as? Frame

/**
 * A box (a `div`, a `section`…, D-137): it puts each child at the frame the host's layout gave it,
 * and is as big as its own frame. Its paint (background, borders, corners, shadow) is a [CssPaint];
 * with `overflow` other than visible it clips what it holds to its corners, otherwise what it holds
 * may draw outside it, as CSS's does.
 */
open class Box(context: Context) : ViewGroup(context) {
    /** The corners its children are clipped to, when it clips (`style.clip`). */
    var clip = false
        set(value) {
            field = value
            clipChildren = value
            invalidate()
        }

    init {
        clipChildren = false
        clipToPadding = false
        setWillNotDraw(false)
    }

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        for (at in 0 until childCount) {
            val child = getChildAt(at)
            val frame = child.frame
            if (frame == null) {
                child.measure(MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            } else {
                child.measure(MeasureSpec.makeMeasureSpec(frame.width.coerceAtLeast(0), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(frame.height.coerceAtLeast(0), MeasureSpec.EXACTLY))
            }
        }
        val own = frame
        if (own != null) {
            setMeasuredDimension(own.width.coerceAtLeast(0), own.height.coerceAtLeast(0))
        } else {
            setMeasuredDimension(MeasureSpec.getSize(widthSpec), MeasureSpec.getSize(heightSpec))
        }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        for (at in 0 until childCount) {
            val child = getChildAt(at)
            val frame = child.frame ?: continue
            val x = paddingLeft + frame.x
            val y = paddingTop + frame.y
            child.layout(x, y, x + child.measuredWidth, y + child.measuredHeight)
        }
    }

    override fun dispatchDraw(canvas: Canvas) {
        if (!clip) {
            super.dispatchDraw(canvas)
            return
        }
        val paint = background as? CssPaint
        canvas.save()
        canvas.clipPath(paint?.clipPath(width, height) ?: Path().apply { addRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), Path.Direction.CW) })
        super.dispatchDraw(canvas)
        canvas.restore()
    }

    override fun shouldDelayChildPressedState(): Boolean = false

    override fun generateDefaultLayoutParams(): LayoutParams = Frame(0, 0, 0, 0)
}
