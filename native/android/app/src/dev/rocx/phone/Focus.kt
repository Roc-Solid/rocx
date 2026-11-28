package dev.rocx.phone

import android.graphics.Rect
import android.widget.ScrollView

/**
 * The focused field kept in view above the keyboard (D-139), as a browser scrolls a focused input
 * into view when the keyboard comes up: the screen (a ScrollView whose bottom padding is the
 * keyboard's height, RocxActivity's insets) scrolled so the field shows whole, with a margin.
 */
object Focus {
    fun keepInView(screen: ScrollView?) {
        val scroller = screen ?: return
        val focused = scroller.findFocus() ?: return
        val rect = Rect()
        focused.getDrawingRect(rect)
        scroller.offsetDescendantRectToMyCoords(focused, rect)
        val margin = (16 * scroller.resources.displayMetrics.density).toInt()
        val top = scroller.scrollY + scroller.paddingTop
        val bottom = scroller.scrollY + scroller.height - scroller.paddingBottom
        when {
            rect.height() + 2 * margin > bottom - top -> scroller.smoothScrollBy(0, rect.top - margin - top)
            rect.bottom + margin > bottom -> scroller.smoothScrollBy(0, rect.bottom + margin - bottom)
            rect.top - margin < top -> scroller.smoothScrollBy(0, rect.top - margin - top)
        }
    }
}
