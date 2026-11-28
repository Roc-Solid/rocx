package dev.rocx.phone

import android.app.AlertDialog
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Context
import android.graphics.Canvas
import android.graphics.Typeface
import android.text.format.DateFormat
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.TextView
import org.json.JSONArray
import java.util.Calendar

/**
 * A `<select>` (D-139): the chosen option's label, drawn as its CSS says (a [TextBox], centred
 * down its box as a browser's is), and, tapped, the phone's own list of its options: `<optgroup>`
 * labels as headings, disabled options shown but not chosen, the chosen one marked. A choice is the
 * select's `input` then `change`, its value the option's, as a browser fires them; the host shows
 * the new label once the app has it.
 */
class SelectBox(context: Context, private val density: Float, private val id: Long) : TextBox(context, density) {
    private var options = JSONArray()
    private var value = ""

    init {
        isClickable = true
        isFocusable = true
        setOnClickListener { choose() }
    }

    fun option(key: String, given: String) {
        when (key) {
            "options" -> options = try {
                JSONArray(given)
            } catch (_: Exception) {
                JSONArray()
            }
            "value" -> value = given
        }
    }

    /** A row of the list: a group's heading, or an option. */
    private data class Row(val label: String, val value: String?, val enabled: Boolean)

    private fun choose() {
        if (!isEnabled) return
        Rocx.event(id, "focus", value)
        val rows = ArrayList<Row>()
        var group = ""
        for (at in 0 until options.length()) {
            val option = options.optJSONObject(at) ?: continue
            val its = option.optString("group")
            if (its != group && its.isNotEmpty()) rows.add(Row(its, null, false))
            group = its
            rows.add(Row(option.optString("label"), option.optString("value"), !option.optBoolean("disabled")))
        }
        val chosen = rows.indexOfFirst { it.value == value }
        val adapter = object : ArrayAdapter<Row>(context, android.R.layout.simple_list_item_single_choice, rows) {
            override fun isEnabled(position: Int): Boolean = rows[position].enabled
            override fun areAllItemsEnabled(): Boolean = false
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val view = super.getView(position, convertView, parent) as TextView
                val row = rows[position]
                view.text = row.label
                view.isEnabled = row.enabled
                view.alpha = if (row.enabled || row.value == null) 1f else 0.4f
                view.setTypeface(null, if (row.value == null) Typeface.BOLD else Typeface.NORMAL)
                return view
            }
        }
        AlertDialog.Builder(context, Dialogs.theme())
            .setSingleChoiceItems(adapter, chosen) { dialog, which ->
                val row = rows[which]
                dialog.dismiss()
                val picked = row.value ?: return@setSingleChoiceItems
                if (!row.enabled) return@setSingleChoiceItems
                if (picked != value) {
                    value = picked
                    Rocx.event(id, "input", picked)
                    Rocx.event(id, "change", picked)
                }
            }
            .setOnDismissListener { Rocx.event(id, "blur", value) }
            .show()
    }

    override fun onDraw(canvas: Canvas) {
        // A select's label sits in the middle of its box, whatever its height.
        val inner = height - paddingTop - paddingBottom
        val (_, textHeight) = measureText(0, (width - paddingLeft - paddingRight) / density)
        val shift = ((inner - textHeight * density) / 2f).coerceAtLeast(0f)
        canvas.save()
        canvas.translate(0f, shift)
        super.onDraw(canvas)
        canvas.restore()
    }
}

/**
 * Date and time fields (D-139): `date`, `time`, `datetime-local` and `month` as a field that isn't
 * typed in but opens the system's pickers (a date, then a time), writing the value as HTML has it
 * (`2026-11-28`, `17:45`, `2026-11-28T17:45`, `2026-11`) and sending `input` and `change`; shown as
 * the phone's locale writes it. `min` and `max` bound the date picker.
 */
object DateFields {
    val types = setOf("date", "time", "datetime-local", "month")

    /** What the field shows for an HTML value: the locale's date and time. */
    fun shown(context: Context, type: String, value: String): String {
        val at = parse(type, value) ?: return value
        val date = DateFormat.getMediumDateFormat(context)
        val time = DateFormat.getTimeFormat(context)
        return when (type) {
            "time" -> time.format(at.time)
            "month" -> android.text.format.DateFormat.format("MMMM yyyy", at).toString()
            "datetime-local" -> "${date.format(at.time)}, ${time.format(at.time)}"
            else -> date.format(at.time)
        }
    }

    private fun parse(type: String, value: String): Calendar? {
        val numbers = Regex("\\d+").findAll(value).map { it.value.toInt() }.toList()
        val at = Calendar.getInstance()
        at.clear()
        return when (type) {
            "time" -> if (numbers.size >= 2) at.apply { set(1970, 0, 1, numbers[0], numbers[1]) } else null
            "month" -> if (numbers.size >= 2) at.apply { set(numbers[0], numbers[1] - 1, 1) } else null
            "datetime-local" -> if (numbers.size >= 5) at.apply { set(numbers[0], numbers[1] - 1, numbers[2], numbers[3], numbers[4]) } else null
            else -> if (numbers.size >= 3) at.apply { set(numbers[0], numbers[1] - 1, numbers[2]) } else null
        }
    }

    /** The pickers for a field of `type` holding `value` (HTML's), `min` and `max` its limits. */
    fun open(context: Context, id: Long, type: String, value: String, limits: Pair<String?, String?>) {
        val now = parse(type, value) ?: Calendar.getInstance()
        fun send(text: String) {
            Rocx.event(id, "input", text)
            Rocx.event(id, "change", text)
        }
        fun two(n: Int) = n.toString().padStart(2, '0')
        fun time(date: String?) {
            TimePickerDialog(context, Dialogs.theme(), { _, hour, minute ->
                val clock = "${two(hour)}:${two(minute)}"
                send(if (date == null) clock else "${date}T$clock")
            }, now.get(Calendar.HOUR_OF_DAY), now.get(Calendar.MINUTE), DateFormat.is24HourFormat(context)).show()
        }
        if (type == "time") return time(null)
        val dialog = DatePickerDialog(context, Dialogs.theme(), { _, year, month, day ->
            val date = "${year.toString().padStart(4, '0')}-${two(month + 1)}-${two(day)}"
            when (type) {
                "datetime-local" -> time(date)
                "month" -> send(date.substring(0, 7))
                else -> send(date)
            }
        }, now.get(Calendar.YEAR), now.get(Calendar.MONTH), now.get(Calendar.DAY_OF_MONTH))
        limits.first?.let { parse(if (type == "datetime-local") type else "date", it) }?.let { dialog.datePicker.minDate = it.timeInMillis }
        limits.second?.let { parse(if (type == "datetime-local") type else "date", it) }?.let { dialog.datePicker.maxDate = it.timeInMillis }
        dialog.show()
    }
}

/** The system's dialogs (a select's list, the date and time pickers) dark on a dark page (D-139). */
object Dialogs {
    /** Whether the page's canvas is dark (the applier's `canvas`). */
    var dark = false

    fun theme(): Int = if (dark) android.R.style.Theme_DeviceDefault_Dialog_Alert else android.R.style.Theme_DeviceDefault_Light_Dialog_Alert
}
