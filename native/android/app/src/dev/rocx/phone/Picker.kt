package dev.rocx.phone

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * A file input's picker (D-139): the system's photo picker when the input takes only images or
 * videos (Android 13's `ACTION_PICK_IMAGES`, no permission needed), else its documents
 * (`ACTION_OPEN_DOCUMENT`), filtered by the input's `accept` (types, a kind of type such as images, extensions) and
 * taking several when it has `multiple`. Each file picked is copied into the app's cache
 * (`rocx-picked/<n>/<its name>`), off the main thread, so the host can read it as a file (a form
 * with files, an action's `fileOf`, an `<img src>` of it, an element's phone half), and the input
 * is told: `files` with `[{"name","type","size","path"}]`, or `cancel` when nothing was picked.
 */
object Picker {
    private const val REQUEST = 0x7f0c
    private var waiting = 0L
    private var count = 0
    private val copier = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun open(activity: Activity, view: Long, accept: String, multiple: Boolean): Boolean {
        val wanted = accept.split(',').map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        val types = wanted.mapNotNull { each ->
            if (each.startsWith(".")) MimeTypeMap.getSingleton().getMimeTypeFromExtension(each.drop(1)) else each
        }.distinct()
        val media = types.isNotEmpty() && types.all { it.startsWith("image/") || it.startsWith("video/") }
        val intent = if (media && Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                val images = types.all { it.startsWith("image/") }
                val videos = types.all { it.startsWith("video/") }
                if (images) type = "image/*" else if (videos) type = "video/*"
                if (multiple) putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit())
            }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = if (types.size == 1) types[0] else "*/*"
                if (types.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            }
        }
        return try {
            waiting = view
            activity.startActivityForResult(intent, REQUEST)
            true
        } catch (failure: Exception) {
            Rocx.say(Log.ERROR, "files: the picker didn't open: ${failure.message}")
            false
        }
    }

    /** The activity's result: the files copied, then the input told. Whether it was the picker's. */
    fun result(activity: Activity, request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        val view = waiting
        waiting = 0L
        val uris = ArrayList<Uri>()
        data?.clipData?.let { clip -> for (at in 0 until clip.itemCount) uris.add(clip.getItemAt(at).uri) }
        if (uris.isEmpty()) data?.data?.let { uris.add(it) }
        if (code != Activity.RESULT_OK || uris.isEmpty()) {
            Rocx.event(view, "cancel", "")
            return true
        }
        val resolver = activity.contentResolver
        val dir = File(activity.cacheDir, "rocx-picked/${++count}")
        copier.execute {
            val files = JSONArray()
            for (uri in uris) {
                try {
                    var name = "file"
                    var size = -1L
                    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            cursor.getString(0)?.let { name = it }
                            if (!cursor.isNull(1)) size = cursor.getLong(1)
                        }
                    }
                    val kind = resolver.getType(uri) ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: ""
                    dir.mkdirs()
                    val file = File(dir, name.replace('/', '_'))
                    resolver.openInputStream(uri)?.use { input -> file.outputStream().use { output -> input.copyTo(output) } }
                    files.put(JSONObject().put("name", name).put("type", kind).put("size", if (size >= 0) size else file.length()).put("path", file.path))
                } catch (failure: Exception) {
                    Rocx.say(Log.ERROR, "files: $uri couldn't be read: ${failure.message}")
                }
            }
            main.post { Rocx.event(view, "files", files.toString()) }
        }
        return true
    }
}
