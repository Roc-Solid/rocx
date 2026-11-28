package dev.rocx.phone

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.net.Uri
import android.util.Log
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.widget.FrameLayout
import kotlin.math.min

/**
 * A `<video>` (D-139): a MediaPlayer drawing on a TextureView (an ordinary view: it scrolls, clips
 * and fades with the page), under its poster ([ImageBox]: the `poster` the host loaded, or else the
 * video's frame at its `#t=` moment, as a browser shows one with `preload="metadata"`), which goes
 * once the video draws. `controls`: a tap plays and pauses it, and a play button shows over it
 * while it is paused. `autoplay`, `muted` and `loop` as a browser has them. The source is asked for
 * with the app's cookies (the host's jar, `Rocx.ask("cookie", url)`), so a members' video plays.
 * It tells the page `play`, `pause`, `ended` and `loadedmetadata` (`<w>x<h> <ms>`: the host takes
 * the video's size as the element's natural size).
 */
class VideoBox(context: Context, private val density: Float, private val id: Long) : FrameLayout(context), TextureView.SurfaceTextureListener {
    private val texture = TextureView(context)
    private val poster = ImageBox(context, density)
    private var src: String? = null
    private var hasPoster = false
    private var controls = false
    private var muted = false
    private var looped = false
    private var autoplay = false
    private var fit = "contain"
    private var player: MediaPlayer? = null
    private var surface: Surface? = null
    private var wanted = false
    private var playing = false
    private var size = Pair(0, 0)
    private val button = Paint(Paint.ANTI_ALIAS_FLAG)

    init {
        texture.surfaceTextureListener = this
        addView(texture, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(poster, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setWillNotDraw(false)
        setOnClickListener { if (controls) (if (playing) pause() else play()) }
        isClickable = false
    }

    fun set(key: String, value: String) {
        when (key) {
            "src" -> if (value != src) {
                release()
                src = value.ifEmpty { null }
                poster.visibility = VISIBLE
                if (!hasPoster) frame()
                if (autoplay) play()
            }
            "poster" -> {
                hasPoster = value.isNotEmpty()
                poster.set("src", value)
                if (!hasPoster) frame()
            }
            "controls" -> {
                controls = value == "true"
                isClickable = controls
            }
            "muted" -> {
                muted = value == "true"
                player?.setVolume(if (muted) 0f else 1f, if (muted) 0f else 1f)
            }
            "loop" -> {
                looped = value == "true"
                player?.isLooping = looped
            }
            "autoplay" -> {
                autoplay = value == "true"
                if (autoplay) play()
            }
            "fit" -> {
                fit = value
                poster.set("fit", if (value == "fill") "fill" else value)
                fitVideo()
            }
        }
        invalidate()
    }

    /** The URL without its fragment, and the fragment's start (`#t=1.5`), in ms. */
    private fun parts(url: String): Pair<String, Long> {
        val at = url.indexOf('#')
        if (at < 0) return url to 0L
        val start = Regex("t=([0-9.]+)").find(url.substring(at))?.groupValues?.get(1)?.toDoubleOrNull() ?: 0.0
        return url.substring(0, at) to (start * 1000).toLong()
    }

    private fun headers(url: String): Map<String, String> {
        val cookie = Rocx.ask("cookie", url)
        return if (cookie.isEmpty()) emptyMap() else mapOf("Cookie" to cookie)
    }

    /** No poster: the video's frame at its start, as a preview. */
    private fun frame() {
        val url = src ?: return
        val (plain, ms) = parts(url)
        Images.frame(plain, headers(plain), ms) { bitmap -> if (src == url && !hasPoster && bitmap != null) poster.show(bitmap) }
    }

    fun play() {
        wanted = true
        val url = src ?: return
        val current = player
        if (current != null) {
            current.start()
            started()
            return
        }
        val target = surface ?: return
        val (plain, ms) = parts(url)
        val made = MediaPlayer()
        player = made
        try {
            made.setSurface(target)
            made.setDataSource(context, Uri.parse(plain), headers(plain))
            made.isLooping = looped
            if (muted) made.setVolume(0f, 0f)
            made.setOnPreparedListener { prepared ->
                if (player !== prepared) return@setOnPreparedListener
                size = Pair(prepared.videoWidth, prepared.videoHeight)
                fitVideo()
                Rocx.event(id, "loadedmetadata", "${prepared.videoWidth}x${prepared.videoHeight} ${prepared.duration}")
                if (ms > 0) prepared.seekTo(ms.toInt())
                if (wanted) {
                    prepared.start()
                    started()
                }
            }
            made.setOnInfoListener { _, what, _ ->
                if (what == MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START) poster.visibility = INVISIBLE
                false
            }
            made.setOnCompletionListener {
                playing = false
                invalidate()
                Rocx.event(id, "ended", "")
            }
            made.setOnErrorListener { _, what, extra ->
                Rocx.say(Log.ERROR, "video: $plain can't be played (MediaPlayer error $what/$extra)")
                release()
                true
            }
            made.prepareAsync()
        } catch (failure: Exception) {
            Rocx.say(Log.ERROR, "video: $plain can't be played: ${failure.message}")
            release()
        }
    }

    private fun started() {
        playing = true
        invalidate()
        Rocx.event(id, "play", "")
    }

    fun pause() {
        wanted = false
        val current = player ?: return
        if (current.isPlaying) current.pause()
        playing = false
        invalidate()
        Rocx.event(id, "pause", "")
    }

    private fun release() {
        player?.let {
            try {
                it.release()
            } catch (_: Throwable) {}
        }
        player = null
        playing = false
        wanted = false
    }

    /** The video's picture in the view, as `object-fit` says (contain unless set). */
    private fun fitVideo() {
        val (vw, vh) = size
        if (vw <= 0 || vh <= 0 || width <= 0 || height <= 0) return
        val (w, h) = width.toFloat() to height.toFloat()
        val scale = when (fit) {
            "cover" -> maxOf(w / vw, h / vh)
            "fill" -> 0f
            else -> min(w / vw, h / vh)
        }
        val matrix = Matrix()
        if (scale > 0f) {
            val (dw, dh) = vw * scale to vh * scale
            matrix.setScale(dw / w, dh / h)
            matrix.postTranslate((w - dw) / 2f, (h - dh) / 2f)
        }
        texture.setTransform(matrix)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        fitVideo()
    }

    override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
        surface = Surface(texture)
        if (wanted || autoplay) play()
    }

    override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) {}

    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
        release()
        surface?.release()
        surface = null
        poster.visibility = VISIBLE
        return true
    }

    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) {}

    override fun dispatchDraw(canvas: Canvas) {
        val clip = (background as? CssPaint)?.takeIf { it.hasCorners() }?.clipPath(width, height)
        if (clip != null) {
            canvas.save()
            canvas.clipPath(clip)
        }
        super.dispatchDraw(canvas)
        // A paused video with controls: a play button over it.
        if (controls && !playing && src != null) {
            val r = min(width, height) * 0.12f + 8f * density
            val (cx, cy) = width / 2f to height / 2f
            button.color = Color.argb(150, 0, 0, 0)
            canvas.drawCircle(cx, cy, r, button)
            button.color = Color.WHITE
            val side = r * 0.9f
            canvas.drawPath(Path().apply {
                moveTo(cx - side * 0.35f, cy - side * 0.5f)
                lineTo(cx + side * 0.55f, cy)
                lineTo(cx - side * 0.35f, cy + side * 0.5f)
                close()
            }, button)
        }
        if (clip != null) canvas.restore()
    }

    override fun onDetachedFromWindow() {
        release()
        super.onDetachedFromWindow()
    }
}
