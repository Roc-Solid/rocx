package dev.rocx.phone

import android.util.Log
import android.view.Choreographer

/**
 * The display's frames for what moves (D-142): CSS transitions and animations, Roc's transitions,
 * glides and `on:frame`. While the host says something moves (`Rocx.frames()`), each frame's time
 * (Choreographer's, the display's vsync) goes to it (`Rocx.tick`), which sends each moving view's
 * look as ops (`Rocx.apply`) and runs `on:frame`'s handlers; once it answers that nothing moves,
 * frames stop. Nothing of Roc's runs for a frame but `on:frame`'s.
 */
object Frames : Choreographer.FrameCallback {
    private var running = false

    /** Frames are wanted: from the next one on, until the host says nothing moves. */
    fun want() {
        if (running) return
        running = true
        Choreographer.getInstance().postFrameCallback(this)
    }

    /** What the host's frames cost, said every 120 frames (logcat's `rocx`, at Debug). */
    private var counted = 0
    private var spent = 0L
    private var most = 0L

    override fun doFrame(frameTimeNanos: Long) {
        val started = System.nanoTime()
        val more = try {
            Rocx.tick(frameTimeNanos)
        } catch (failure: Exception) {
            Rocx.say(Log.ERROR, "a frame failed: ${failure.message}")
            false
        }
        val took = System.nanoTime() - started
        counted++
        spent += took
        most = maxOf(most, took)
        if (counted == 120) {
            Rocx.say(Log.DEBUG, "frames: 120 ticks, ${"%.3f".format(spent / 120 / 1e6)} ms each, at most ${"%.3f".format(most / 1e6)} ms")
            counted = 0
            spent = 0L
            most = 0L
        }
        if (more) Choreographer.getInstance().postFrameCallback(this) else running = false
    }
}
