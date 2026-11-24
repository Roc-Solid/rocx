package dev.rocx.phone

import android.content.Context
import android.widget.LinearLayout

/**
 * A box (a `div`, a `section`…): a LinearLayout whose children's sizes can be CSS's percentages
 * and have a minimum and maximum (`width: 50%`, `max-width: 30rem`). A percentage is of the box's
 * content (its size less its padding), as CSS's is of the containing block's, and is made a
 * size once the box is measured (`onMeasure`), as androidx's percent layouts did; with no size to be
 * a percentage of (a height in a scrolling column), it is the child's own size, as CSS's `auto`.
 */
class Box(context: Context) : LinearLayout(context) {
    /** A size as CSS gives it: dp, a percentage, or none (`auto`: filling a column, or as it is). */
    sealed class Size {
        data class Dp(val px: Int) : Size()
        data class Percent(val percent: Float) : Size()
        data class Auto(val fill: Boolean) : Size()
    }

    class Params(
        val cssWidth: Size,
        val cssHeight: Size,
        val minWidth: Size?,
        val maxWidth: Size?,
        val minHeight: Size?,
        val maxHeight: Size?,
    ) : LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT)

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        val width = if (MeasureSpec.getMode(widthSpec) == MeasureSpec.UNSPECIFIED) -1 else MeasureSpec.getSize(widthSpec) - paddingLeft - paddingRight
        val height = if (MeasureSpec.getMode(heightSpec) == MeasureSpec.EXACTLY) MeasureSpec.getSize(heightSpec) - paddingTop - paddingBottom else -1
        for (at in 0 until childCount) {
            val params = getChildAt(at).layoutParams as? Params ?: continue
            params.width = resolve(params.cssWidth, width, params.leftMargin + params.rightMargin, params.minWidth, params.maxWidth)
            params.height = resolve(params.cssHeight, height, params.topMargin + params.bottomMargin, params.minHeight, params.maxHeight)
        }
        super.onMeasure(widthSpec, heightSpec)
    }

    private fun px(size: Size?, of: Int): Int? = when (size) {
        is Size.Dp -> size.px
        is Size.Percent -> if (of >= 0) (of * size.percent / 100f).toInt() else null
        else -> null
    }

    /** A child's size in px, or MATCH_PARENT/WRAP_CONTENT; its minimum winning over its maximum, as CSS's. */
    private fun resolve(size: Size, of: Int, margins: Int, min: Size?, max: Size?): Int {
        val most = px(max, of)
        val least = px(min, of)
        val given = when (size) {
            is Size.Auto -> if (size.fill && most != null && of >= 0) (of - margins).coerceAtLeast(0) else null
            else -> px(size, of)
        }
        if (given == null) {
            return if (size is Size.Auto && size.fill) LayoutParams.MATCH_PARENT else LayoutParams.WRAP_CONTENT
        }
        var px = given
        if (most != null) px = px.coerceAtMost(most)
        if (least != null) px = px.coerceAtLeast(least)
        return px
    }
}
