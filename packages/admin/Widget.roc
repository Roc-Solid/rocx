import Catalog
import Look
import Sql

## How a column is shown and edited, chosen from its type: a number's input for a number, a
## checkbox for a boolean, a select for an enum, a check's few values or a foreign key, a date's or
## a moment's picker, a text area for JSON. The app may choose another for a column (`widgets` in
## its table's options).
Widget := [].{

	## How a column is edited:
	##
	## - `Text` (an input; a text area for a value of several lines), `LongText` (a text area),
	##   `Json` (a text area, in a monospace font), `Uuid`;
	## - `Integer`, `Decimal`;
	## - `Checkbox` (a boolean that can't be null), `MaybeBool` (one that can: a select);
	## - `Day` (a date), `Moment` (a timestamp), `MomentUtc` (a timestamp with time zone, in UTC),
	##   `TimeOfDay`;
	## - `Choice(values)` (a select), `Reference(table, column)` (a foreign key: a select of the
	##   other table's rows, or an input and a link when it has too many);
	## - `ReadOnly`: shown, never written.
	Kind : [Text, LongText, Json, Uuid, Integer, Decimal, Checkbox, MaybeBool, Day, Moment, MomentUtc, TimeOfDay, Choice(List(Str)), Reference({ table : Str, column : Str }), ReadOnly]

	## A column's widget, from its type.
	of : Catalog.Column -> Kind
	of = |column|
		if column.generated or column.base == "bytea" {
			ReadOnly
		} else {
			match column.refers {
				To(other) => Reference(other)
				Nothing =>
					if !column.labels.is_empty() {
						Choice(column.labels)
					} else if !column.choices.is_empty() {
						Choice(column.choices)
					} else {
						match column.base {
							"bool" => if (column.nullable) MaybeBool else Checkbox
							"int2" | "int4" | "int8" | "oid" => Integer
							"numeric" | "float4" | "float8" => Decimal
							"date" => Day
							"timestamp" => Moment
							"timestamptz" => MomentUtc
							"time" => TimeOfDay
							"json" | "jsonb" => Json
							"uuid" => Uuid
							_ => Text
						}
					}
			}
		}

	## An input for a column: its form field's `name` and the element's `id`; its `value` (as
	## text) and whether it is `null`; whether the row is being `creating` (a column with a default
	## may be left empty then); and a reference's `options` (each row's key and title; `[]`: an
	## input instead).
	input : { name : Str, id : Str, column : Catalog.Column, kind : Kind, value : Str, null : Bool, creating : Bool, options : List((Str, Str)) } -> Str
	input = |field| {
		named = "id=\"${Look.escape(field.id)}\" name=\"${Look.escape(field.name)}\""
		value = if (field.null) "" else field.value
		valued = "value=\"${Look.escape(value)}\""
		may_be_empty = field.column.nullable or (field.creating and field.column.defaulted)
		required = if (may_be_empty) "" else " required"
		empty_choice = if (field.column.nullable) "—" else "(its default)"
		select = |choices| {
			# The value it has, if no choice is it (a choice taken away since).
			kept = if (field.null or choices.any(|(key, _)| key == value)) choices else choices.prepend((value, value))
			listed = kept.map(|(key, title)| "<option value=\"${Look.escape(key)}\"${if (key == value and !field.null) " selected" else ""}>${Look.escape(title)}</option>")
			empty = if (may_be_empty) "<option value=\"\"${if (field.null or value.is_empty()) " selected" else ""}>${empty_choice}</option>" else ""
			"<select ${named}${required}>${empty}${Str.join_with(listed, "")}</select>"
		}
		area = |class| "<textarea ${named}${class} rows=\"${(U64.max(3, U64.min(16, value.split_on("\n").len() + 1))).to_str()}\">${Look.escape(value)}</textarea>"
		match field.kind {
			Text =>
				if value.contains("\n") or value.count_utf8_bytes() > 160 {
					area("")
				} else {
					"<input type=\"text\" ${named} ${valued}${max_length(field.column)}>"
				}
			LongText => area("")
			Json => area(" class=\"code\" spellcheck=\"false\"")
			Uuid => "<input type=\"text\" ${named} ${valued} maxlength=\"36\" spellcheck=\"false\"${required}>"
			Integer => "<input type=\"number\" step=\"1\" ${named} ${valued}${required}>"
			Decimal => "<input type=\"text\" inputmode=\"decimal\" ${named} ${valued}${required}>"
			Checkbox => "<input type=\"hidden\" name=\"${Look.escape(field.name)}\" value=\"false\"><input type=\"checkbox\" ${named} value=\"true\"${if (value == "true") " checked" else ""}>"
			MaybeBool => select([("true", "yes"), ("false", "no")])
			Day => "<input type=\"date\" ${named} ${valued}${required}>"
			Moment => "<input type=\"datetime-local\" step=\"1\" ${named} ${valued}${required}>"
			MomentUtc => "<input type=\"datetime-local\" step=\"1\" ${named} ${valued}${required}> <span class=\"muted\">UTC</span>"
			TimeOfDay => "<input type=\"time\" step=\"1\" ${named} ${valued}${required}>"
			Choice(values) => select(values.map(|each| (each, each)))
			Reference(_) => if (field.options.is_empty()) "<input type=\"text\" ${named} ${valued}${required}>" else select(field.options)
			ReadOnly => "<span class=\"value${if (field.null) " null" else ""}\">${if (field.null) "null" else Look.escape(value)}</span>"
		}
	}

	## What a form's text for a column writes: its `Default` (a new row's column with a default,
	## left empty), or a value. Empty is null for a column that may be null, an empty text for text,
	## and null (which Postgres refuses, saying why) for anything else.
	param : Kind, Catalog.Column, Str, [Creating, Editing] -> [Default, Value(Sql.Param)]
	param = |kind, column, submitted, doing|
		if submitted.is_empty() {
			if doing == Creating and column.defaulted {
				Default
			} else if column.nullable {
				Value(Null)
			} else {
				match kind {
					Text | LongText => Value(Text(""))
					_ => Value(Null)
				}
			}
		} else {
			match kind {
				MomentUtc => Value(Text("${submitted}+00"))
				_ => Value(Text(submitted))
			}
		}

	## Whether a form's text for a column is what the row has (`value`, `null`): only what changed is
	## written. A moment sent without its seconds (`14:05`) is the one with none (`14:05:00`).
	same : Kind, { value : Str, null : Bool }, Str -> Bool
	same = |kind, current, submitted|
		if current.null {
			submitted.is_empty()
		} else {
			match kind {
				Moment | MomentUtc | TimeOfDay => seconds(current.value) == seconds(submitted)
				_ => current.value == submitted
			}
		}

	## What a new row's form starts with for a column: its default, if that is a constant
	## (`true`, `'draft'::text`, `0`); "" if it is anything else (`now()`, a sequence's next).
	initial : Catalog.Column -> Str
	initial = |column| {
		default = column.default.trim()
		if default == "true" or default == "false" {
			default
		} else if default.starts_with("'") {
			quoted(default.to_utf8())
		} else {
			bare = Str.from_utf8_lossy(default.to_utf8().keep_if(|byte| byte != '(' and byte != ')'))
			number =
				match bare.split_first("::") {
					Ok({ before, .. }) => before
					Err(_) => bare
				}
			if (!number.is_empty() and number.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or byte == '.' or byte == '-')) number else ""
		}
	}

	## A value in a list of rows, as HTML: a boolean as yes or no, a moment with a space and its zone,
	## one line of text at most `longest` characters.
	shown : Kind, Str, U64 -> Str
	shown = |kind, value, longest|
		match kind {
			Checkbox | MaybeBool => if (value == "true") "yes" else if (value == "false") "no" else Look.escape(value)
			Moment => Look.escape(value.replace_first("T", " "))
			MomentUtc => "${Look.escape(value.replace_first("T", " "))} <span class=\"muted\">UTC</span>"
			Json => "<code>${Look.escape(Widget.cut(value, longest))}</code>"
			_ => Look.escape(Widget.cut(value.replace_each("\r\n", " ").replace_each("\n", " "), longest))
		}

	## At most `longest` characters of a text (0: all of it), and `…` if it had more.
	cut : Str, U64 -> Str
	cut = |text, longest| {
		bytes = text.to_utf8()
		# Where each character starts: a byte that isn't 0b10xxxxxx.
		var $count = 0
		var $at = 0
		var $end = bytes.len()
		for byte in bytes {
			if byte < 0x80 or byte >= 0xC0 {
				if $count == longest and longest > 0 and $end == bytes.len() {
					$end = $at
				} else {
					{}
				}
				$count = $count + 1
			} else {
				{}
			}
			$at = $at + 1
		}
		if ($end == bytes.len()) text else "${Str.from_utf8_lossy(bytes.take_first($end))}…"
	}
}

## ` maxlength="80"` for a `character varying(80)` or a `character(80)`.
max_length : Catalog.Column -> Str
max_length = |column|
	if column.base == "varchar" or column.base == "bpchar" {
		match column.type.split_first("(") {
			Ok({ after, .. }) =>
				match U64.from_str(after.drop_suffix(")")) {
					Ok(n) => " maxlength=\"${n.to_str()}\""
					Err(_) => ""
				}
			Err(_) => ""
		}
	} else {
		""
	}

## `14:05` as `14:05:00`, and a moment likewise; anything else as it is.
seconds : Str -> Str
seconds = |text| {
	clock =
		match text.split_last("T") {
			Ok({ after, .. }) => after
			Err(_) => text
		}
	if (clock.count_utf8_bytes() == 5) "${text}:00" else text
}

## The text of a quoted literal (`'it''s'::text`), its quotes and cast gone.
quoted : List(U8) -> Str
quoted = |bytes| {
	var $out = []
	var $at = 1
	var $inside = Bool.True
	while $inside and $at < bytes.len() {
		byte = bytes.get($at) ?? '\''
		if byte == '\'' and (bytes.get($at + 1) ?? ' ') == '\'' {
			$out = $out.append('\'')
			$at = $at + 2
		} else if byte == '\'' {
			$inside = Bool.False
		} else {
			$out = $out.append(byte)
			$at = $at + 1
		}
	}
	Str.from_utf8_lossy($out)
}

column_of : Str, Str -> Catalog.Column
column_of = |name, base| { name, type: base, base, category: "", nullable: Bool.False, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }

expect Widget.of(column_of("n", "int8")) == Integer
expect Widget.of({ ..column_of("n", "bool"), nullable: Bool.True }) == MaybeBool
expect Widget.of(column_of("n", "bool")) == Checkbox
expect Widget.of(column_of("at", "timestamptz")) == MomentUtc
expect Widget.of({ ..column_of("state", "text"), choices: ["a", "b"] }) == Choice(["a", "b"])
expect Widget.of({ ..column_of("mood", "mood"), labels: ["happy"] }) == Choice(["happy"])
expect Widget.of({ ..column_of("author_id", "int8"), refers: To({ table: "authors", column: "id" }) }) == Reference({ table: "authors", column: "id" })
expect Widget.of({ ..column_of("len", "int4"), generated: Bool.True }) == ReadOnly
expect Widget.of(column_of("data", "bytea")) == ReadOnly
expect Widget.of(column_of("data", "jsonb")) == Json
expect Widget.of(column_of("ip", "inet")) == Text

expect {
	field = { name: "v.email", id: "f3", column: { ..column_of("email", "varchar"), type: "character varying(120)" }, kind: Text, value: "a\"b", null: Bool.False, creating: Bool.False, options: [] }
	Widget.input(field) == "<input type=\"text\" id=\"f3\" name=\"v.email\" value=\"a&quot;b\" maxlength=\"120\">"
}
expect {
	field = { name: "v.on", id: "f1", column: column_of("on", "bool"), kind: Checkbox, value: "true", null: Bool.False, creating: Bool.False, options: [] }
	Widget.input(field) == "<input type=\"hidden\" name=\"v.on\" value=\"false\"><input type=\"checkbox\" id=\"f1\" name=\"v.on\" value=\"true\" checked>"
}
expect {
	field = { name: "v.state", id: "f2", column: { ..column_of("state", "text"), nullable: Bool.True }, kind: Choice(["a", "b"]), value: "gone", null: Bool.False, creating: Bool.False, options: [] }
	Widget.input(field) == "<select id=\"f2\" name=\"v.state\"><option value=\"\">—</option><option value=\"gone\" selected>gone</option><option value=\"a\">a</option><option value=\"b\">b</option></select>"
}
expect {
	field = { name: "v.author_id", id: "f4", column: column_of("author_id", "int8"), kind: Reference({ table: "authors", column: "id" }), value: "2", null: Bool.False, creating: Bool.False, options: [("1", "Ada"), ("2", "Grace")] }
	Widget.input(field) == "<select id=\"f4\" name=\"v.author_id\" required><option value=\"1\">Ada</option><option value=\"2\" selected>Grace</option></select>"
}
expect {
	field = { name: "v.n", id: "f5", column: { ..column_of("n", "int4"), defaulted: Bool.True }, kind: Integer, value: "", null: Bool.True, creating: Bool.True, options: [] }
	Widget.input(field) == "<input type=\"number\" step=\"1\" id=\"f5\" name=\"v.n\" value=\"\">"
}
expect Widget.input({ name: "v.b", id: "f6", column: column_of("b", "text"), kind: Text, value: "one\ntwo", null: Bool.False, creating: Bool.False, options: [] }) == "<textarea id=\"f6\" name=\"v.b\" rows=\"3\">one\ntwo</textarea>"
expect Widget.input({ name: "v.len", id: "f7", column: column_of("len", "int4"), kind: ReadOnly, value: "", null: Bool.True, creating: Bool.False, options: [] }) == "<span class=\"value null\">null</span>"

expect Widget.param(Integer, { ..column_of("n", "int4"), defaulted: Bool.True }, "", Creating) == Default
expect Widget.param(Integer, { ..column_of("n", "int4"), defaulted: Bool.True }, "", Editing) == Value(Null)
expect Widget.param(Text, { ..column_of("t", "text"), nullable: Bool.True }, "", Editing) == Value(Null)
expect Widget.param(Text, column_of("t", "text"), "", Editing) == Value(Text(""))
expect Widget.param(MomentUtc, column_of("at", "timestamptz"), "2026-11-21T14:05", Editing) == Value(Text("2026-11-21T14:05+00"))
expect Widget.param(Checkbox, column_of("on", "bool"), "false", Creating) == Value(Text("false"))

expect Widget.same(MomentUtc, { value: "2026-11-21T14:05:00", null: Bool.False }, "2026-11-21T14:05")
expect !Widget.same(MomentUtc, { value: "2026-11-21T14:05:01", null: Bool.False }, "2026-11-21T14:05")
expect Widget.same(Text, { value: "", null: Bool.True }, "")
expect !Widget.same(Text, { value: "", null: Bool.True }, "x")
expect Widget.same(TimeOfDay, { value: "09:30:00", null: Bool.False }, "09:30")

expect Widget.initial({ ..column_of("on", "bool"), default: "true" }) == "true"
expect Widget.initial({ ..column_of("s", "text"), default: "'it''s'::text" }) == "it's"
expect Widget.initial({ ..column_of("p", "numeric"), default: "(0)::numeric" }) == "0"
expect Widget.initial({ ..column_of("p", "int4"), default: "'-3'::integer" }) == "-3"
expect Widget.initial({ ..column_of("at", "timestamptz"), default: "now()" }) == ""
expect Widget.initial({ ..column_of("id", "int8"), default: "nextval('books_id_seq'::regclass)" }) == ""
expect Widget.initial({ ..column_of("d", "jsonb"), default: "'{}'::jsonb" }) == "{}"

expect Widget.shown(MaybeBool, "true", 0) == "yes"
expect Widget.shown(MomentUtc, "2026-11-21T14:05:03", 0) == "2026-11-21 14:05:03 <span class=\"muted\">UTC</span>"
expect Widget.shown(Text, "a\nb <c>", 0) == "a b &lt;c&gt;"
expect Widget.cut("héllo", 3) == "hél…"
expect Widget.cut("héllo", 5) == "héllo"
expect Widget.cut("héllo", 0) == "héllo"
expect Widget.cut("", 2) == ""
