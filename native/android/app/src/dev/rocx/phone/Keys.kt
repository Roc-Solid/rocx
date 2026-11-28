package dev.rocx.phone

import android.app.Activity
import android.text.InputType
import android.view.KeyEvent
import android.widget.EditText

/**
 * A hardware keyboard's keys (D-142), as a browser gives them to the page: `keydown` and `keyup` on
 * the focused element (a field), or else the page's body, with the key as `KeyboardEvent.key` names
 * it (`k`, `K`, `/`, `Enter`, `ArrowDown`, `Escape`), its place (`KeyK`) and the modifier keys held,
 * to the page's handlers (`on:keydown.Mod+K`, `.keys`), its `<Document>` handlers, and the app's page
 * and element halves (`PageEvent.value`, read with [KeyPress]). A key a handler takes (`preventDefault`)
 * goes no further: a field doesn't type it. Back stays Android's.
 */
object Keys {
    fun dispatch(activity: Activity, event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return false
        if (event.keyCode == KeyEvent.KEYCODE_BACK || event.keyCode == KeyEvent.KEYCODE_HOME || event.keyCode == KeyEvent.KEYCODE_VOLUME_UP || event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || event.keyCode == KeyEvent.KEYCODE_POWER) return false
        val (key, code) = name(event) ?: return false
        val flags = listOf(event.isShiftPressed, event.isCtrlPressed, event.isAltPressed, event.isMetaPressed, event.isCtrlPressed).joinToString("") { if (it) "1" else "0" }
        val focused = activity.currentFocus
        val id = Rocx.applier?.idOf(focused) ?: 0L
        val down = event.action == KeyEvent.ACTION_DOWN
        val taken = Rocx.key(id, if (down) "keydown" else "keyup", "$flags$key\t$code")
        if (down) Rocx.say(android.util.Log.DEBUG, "key ${if (event.isMetaPressed) "Meta+" else ""}${if (event.isCtrlPressed) "Ctrl+" else ""}${if (event.isAltPressed) "Alt+" else ""}${if (event.isShiftPressed) "Shift+" else ""}$key ($code) on #$id${if (taken) ": taken" else ""}")
        if (taken) return true
        // Enter in a one-line field: the host did what a browser's does (a form's implicit submission);
        // the field's own action (which tells the host Enter too) isn't wanted as well.
        return key == "Enter" && focused is EditText && (focused.inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE) == 0
    }

    /** The key's `KeyboardEvent.key` and `code`, or none for one a page never sees. */
    private fun name(event: KeyEvent): Pair<String, String>? {
        val named = when (event.keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "Enter" to "Enter"
            KeyEvent.KEYCODE_ESCAPE -> "Escape" to "Escape"
            KeyEvent.KEYCODE_TAB -> "Tab" to "Tab"
            KeyEvent.KEYCODE_DEL -> "Backspace" to "Backspace"
            KeyEvent.KEYCODE_FORWARD_DEL -> "Delete" to "Delete"
            KeyEvent.KEYCODE_DPAD_UP -> "ArrowUp" to "ArrowUp"
            KeyEvent.KEYCODE_DPAD_DOWN -> "ArrowDown" to "ArrowDown"
            KeyEvent.KEYCODE_DPAD_LEFT -> "ArrowLeft" to "ArrowLeft"
            KeyEvent.KEYCODE_DPAD_RIGHT -> "ArrowRight" to "ArrowRight"
            KeyEvent.KEYCODE_MOVE_HOME -> "Home" to "Home"
            KeyEvent.KEYCODE_MOVE_END -> "End" to "End"
            KeyEvent.KEYCODE_PAGE_UP -> "PageUp" to "PageUp"
            KeyEvent.KEYCODE_PAGE_DOWN -> "PageDown" to "PageDown"
            KeyEvent.KEYCODE_SPACE -> " " to "Space"
            KeyEvent.KEYCODE_SHIFT_LEFT -> "Shift" to "ShiftLeft"
            KeyEvent.KEYCODE_SHIFT_RIGHT -> "Shift" to "ShiftRight"
            KeyEvent.KEYCODE_CTRL_LEFT -> "Control" to "ControlLeft"
            KeyEvent.KEYCODE_CTRL_RIGHT -> "Control" to "ControlRight"
            KeyEvent.KEYCODE_ALT_LEFT -> "Alt" to "AltLeft"
            KeyEvent.KEYCODE_ALT_RIGHT -> "Alt" to "AltRight"
            KeyEvent.KEYCODE_META_LEFT -> "Meta" to "MetaLeft"
            KeyEvent.KEYCODE_META_RIGHT -> "Meta" to "MetaRight"
            KeyEvent.KEYCODE_CAPS_LOCK -> "CapsLock" to "CapsLock"
            in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> "F${event.keyCode - KeyEvent.KEYCODE_F1 + 1}".let { it to it }
            else -> null
        }
        if (named != null) return named
        // What the key types with Shift alone held (Ctrl+K and ⌘K are `k`, as in a browser).
        val typed = event.getUnicodeChar(event.metaState and (KeyEvent.META_SHIFT_MASK or KeyEvent.META_CAPS_LOCK_ON))
        if (typed == 0) return null
        val key = String(Character.toChars(typed))
        val code = when (event.keyCode) {
            in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> "Key${'A' + (event.keyCode - KeyEvent.KEYCODE_A)}"
            in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> "Digit${event.keyCode - KeyEvent.KEYCODE_0}"
            KeyEvent.KEYCODE_SLASH -> "Slash"
            KeyEvent.KEYCODE_BACKSLASH -> "Backslash"
            KeyEvent.KEYCODE_PERIOD -> "Period"
            KeyEvent.KEYCODE_COMMA -> "Comma"
            KeyEvent.KEYCODE_MINUS -> "Minus"
            KeyEvent.KEYCODE_EQUALS -> "Equal"
            KeyEvent.KEYCODE_SEMICOLON -> "Semicolon"
            KeyEvent.KEYCODE_APOSTROPHE -> "Quote"
            KeyEvent.KEYCODE_GRAVE -> "Backquote"
            KeyEvent.KEYCODE_LEFT_BRACKET -> "BracketLeft"
            KeyEvent.KEYCODE_RIGHT_BRACKET -> "BracketRight"
            else -> ""
        }
        return key to code
    }
}

/**
 * A key's event as a page or element half hears it (`PageEvent.value` of `keydown` and `keyup`,
 * D-142): the key as `KeyboardEvent.key` names it, its place (`code`), and the modifier keys held.
 * `mod` is Ctrl, as on Linux and Windows (⌘ is [meta]).
 */
class KeyPress(val key: String, val code: String, val shift: Boolean, val ctrl: Boolean, val alt: Boolean, val meta: Boolean) {
    val mod: Boolean get() = ctrl

    companion object {
        /** A key event's value (`<shift><ctrl><alt><meta><mod><key>\t<code>`, or a key alone). */
        fun of(value: String): KeyPress {
            val head = value.substringBefore('\t')
            val code = if ('\t' in value) value.substringAfter('\t') else ""
            if (head.length > 5 && head.take(5).all { it == '0' || it == '1' }) {
                val on = { at: Int -> head[at] == '1' }
                return KeyPress(head.drop(5), code, on(0), on(1), on(2), on(3))
            }
            return KeyPress(head, code, false, false, false, false)
        }
    }
}
