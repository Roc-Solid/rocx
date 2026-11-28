package dev.rocx.phone

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.view.View
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * An `<img>` (D-139): the file the host loaded (`src`, a path in the app's cache, or a picked file),
 * decoded off the main thread at about the size it is drawn ([Images]), and drawn in its content
 * box as `object-fit` and `object-position` say (`fit`, `position`), clipped to its corners as a
 * browser clips a replaced element's content. No file (still loading, or failed) draws nothing but
 * its CSS paint, as a browser's broken image without its icon. A `<video>`'s poster is one too.
 */
open class ImageBox(context: Context, private val density: Float) : View(context) {
    private var path: String? = null
    private var fit = "fill"
    private var position = "50% 50%"
    /** Its natural size in CSS px (`natural`: the file's pixels over its `srcset` density). */
    private var natural: Pair<Float, Float>? = null
    private var bitmap: Bitmap? = null
    private var asked: String? = null
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    fun set(key: String, value: String) {
        when (key) {
            "src" -> {
                val now = value.ifEmpty { null }
                if (now != path) {
                    path = now
                    bitmap = null
                    asked = null
                    load()
                }
            }
            "fit" -> fit = value
            "position" -> position = value
            "natural" -> natural = value.split(" ").mapNotNull { it.toFloatOrNull() }.takeIf { it.size == 2 }?.let { it[0] to it[1] }
        }
        invalidate()
    }

    /** A bitmap made elsewhere (a video's frame), shown as the file's would be. */
    fun show(shown: Bitmap?) {
        bitmap = shown
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        load()
    }

    private fun load() {
        val file = path ?: return
        val w = width - paddingLeft - paddingRight
        val h = height - paddingTop - paddingBottom
        if (w <= 0 || h <= 0) return
        val key = "$file@$w"
        if (key == asked) return
        asked = key
        Images.decode(file, w, h) { decoded -> if (path == file) show(decoded) }
    }

    override fun onDraw(canvas: Canvas) {
        val shown = bitmap ?: return
        val box = RectF(paddingLeft.toFloat(), paddingTop.toFloat(), (width - paddingRight).toFloat(), (height - paddingBottom).toFloat())
        if (box.width() <= 0f || box.height() <= 0f) return
        val (bw, bh) = shown.width.toFloat() to shown.height.toFloat()
        // Its own size on the screen, from its natural size (else the bitmap's, a frame's).
        val (nw, nh) = natural?.let { it.first * density to it.second * density } ?: (bw to bh)
        // The drawn size, as object-fit says.
        val (dw, dh) = when (fit) {
            "contain" -> min(box.width() / nw, box.height() / nh).let { nw * it to nh * it }
            "cover" -> max(box.width() / nw, box.height() / nh).let { nw * it to nh * it }
            "none" -> nw to nh
            "scale-down" -> min(1f, min(box.width() / nw, box.height() / nh)).let { nw * it to nh * it }
            else -> box.width() to box.height()
        }
        val parts = position.split(" ")
        fun place(word: String?, room: Float): Float = when {
            word == null -> room / 2f
            word.endsWith("%") -> (word.dropLast(1).toFloatOrNull() ?: 50f) / 100f * room
            word.endsWith("px") -> (word.dropLast(2).toFloatOrNull() ?: 0f) * density
            else -> room / 2f
        }
        val x = box.left + place(parts.getOrNull(0), box.width() - dw)
        val y = box.top + place(parts.getOrNull(1), box.height() - dh)
        canvas.save()
        val clip = (background as? CssPaint)?.takeIf { it.hasCorners() }?.clipPath(width, height)
        if (clip != null) canvas.clipPath(clip) else canvas.clipRect(box)
        canvas.drawBitmap(shown, null, RectF(x, y, x + dw, y + dh), paint)
        canvas.restore()
    }
}

/**
 * Images decoded off the main thread, kept in memory (an LRU of an eighth of the app's heap) by
 * file and sample size: a file decoded at the largest power-of-two step down that is still at
 * least the size it is drawn, turned upright by its EXIF orientation.
 */
object Images {
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newFixedThreadPool(2)
    private val cache = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 8 / 1024).toInt()) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount / 1024
    }
    private val waiting = HashMap<String, MutableList<(Bitmap?) -> Unit>>()

    /** The file at `path` drawn `w` by `h` px: `done` on the main thread (null if it can't be read). */
    fun decode(path: String, w: Int, h: Int, done: (Bitmap?) -> Unit) {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        workers.execute {
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            if (bounds.outWidth > 0 && bounds.outHeight > 0) {
                while (bounds.outWidth / (sample * 2) >= w && bounds.outHeight / (sample * 2) >= h) sample *= 2
            }
            val key = "$path#$sample"
            cache.get(key)?.let { kept ->
                main.post { done(kept) }
                return@execute
            }
            val first = synchronized(waiting) {
                val list = waiting.getOrPut(key) { mutableListOf() }
                list.add(done)
                list.size == 1
            }
            if (!first) return@execute
            val made = try {
                val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
                decoded?.let { upright(path, it) }
            } catch (_: Throwable) {
                null
            }
            if (made != null) cache.put(key, made)
            val callers = synchronized(waiting) { waiting.remove(key) ?: mutableListOf() }
            main.post { for (caller in callers) caller(made) }
        }
    }

    /** A video's frame at `ms` (a preview with no poster, `#t=` its moment), off the main thread. */
    fun frame(url: String, headers: Map<String, String>, ms: Long, done: (Bitmap?) -> Unit) {
        val key = "frame:$url#$ms"
        cache.get(key)?.let { done(it); return }
        workers.execute {
            val retriever = MediaMetadataRetriever()
            val made = try {
                if (url.startsWith("/")) retriever.setDataSource(url) else retriever.setDataSource(url, headers)
                retriever.getFrameAtTime(ms * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } catch (_: Throwable) {
                null
            } finally {
                try {
                    retriever.release()
                } catch (_: Throwable) {}
            }
            if (made != null) cache.put(key, made)
            main.post { done(made) }
        }
    }

    private fun upright(path: String, bitmap: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }
}
