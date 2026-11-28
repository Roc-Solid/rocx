package dev.rocx.phone

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import org.json.JSONObject

/**
 * The phone's native handlers: what a plugin's `Browser.call!(name, arg)` does on Android, where
 * the browser runs the plugin's script. `arg` is the call's JSON, as the script's argument is.
 *
 * - `audio.play` (packages/audio, `Audio.play!`): `{ url, volume, rate }`, the sound file played,
 *   fetched from the app's server when its URL is a path, as the browser fetches it.
 * - `vibrate.pattern` (packages/vibrate, `Vibrate.once!`, `Vibrate.pattern!`): `{ pattern }`,
 *   milliseconds on, off, on…, as `navigator.vibrate`'s.
 * - `clipboard.write` (D-139): `{ text }` put on the clipboard, as `navigator.clipboard.writeText`.
 */
object Calls {
    fun call(context: Context, name: String, arg: String, origin: String): Boolean {
        val json = try {
            JSONObject(arg)
        } catch (_: Exception) {
            JSONObject()
        }
        when (name) {
            "audio.play" -> play(context, json, origin)
            "vibrate.pattern" -> vibrate(context, json)
            // D-139: `{ text }` put on the clipboard, as `navigator.clipboard.writeText`.
            "clipboard.write" -> Phone.copy(context, json.optString("text"))
            else -> return false
        }
        return true
    }

    /** A path is the app's server's, as the browser's `under` makes it. */
    private fun under(url: String, origin: String): String =
        if (url.startsWith("/") && !url.startsWith("//")) origin.trimEnd('/') + url else url

    private fun play(context: Context, arg: JSONObject, origin: String) {
        val url = under(arg.optString("url"), origin)
        val volume = arg.optDouble("volume", 1.0).toFloat().coerceIn(0f, 1f)
        val rate = arg.optDouble("rate", 1.0).toFloat().coerceIn(0.0625f, 16f)
        val player = MediaPlayer()
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            // A URL over HTTP straight to the player (a Uri would be tried as a content provider's first).
            if (url.startsWith("http://") || url.startsWith("https://")) player.setDataSource(url) else player.setDataSource(context, android.net.Uri.parse(url))
            player.setOnPreparedListener { prepared ->
                prepared.setVolume(volume, volume)
                // Its pitch moves with its speed, as the browser's (preservesPitch = false).
                if (rate != 1f) prepared.playbackParams = prepared.playbackParams.setSpeed(rate).setPitch(rate)
                prepared.start()
            }
            player.setOnCompletionListener { it.release() }
            player.setOnErrorListener { failed, what, extra ->
                Rocx.say(Log.ERROR, "audio: the sound $url can't be played (MediaPlayer error $what/$extra)")
                failed.release()
                true
            }
            player.prepareAsync()
        } catch (failure: Exception) {
            Rocx.say(Log.ERROR, "audio: the sound $url can't be played: ${failure.message}")
            player.release()
        }
    }

    private fun vibrate(context: Context, arg: JSONObject) {
        val given = arg.optJSONArray("pattern") ?: return
        val pattern = LongArray(given.length()) { given.optLong(it).coerceIn(0, 10_000) }
        if (pattern.isEmpty() || pattern.all { it == 0L }) return
        val vibrator = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }
        if (vibrator == null || !vibrator.hasVibrator()) return
        // navigator.vibrate's pattern starts on; Android's waveform starts off.
        vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0L) + pattern, -1))
    }
}
