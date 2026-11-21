import Chars
import Yaml

## A Markdown file's frontmatter: YAML between two `---` lines at its very start, before the body.
##
##     ---
##     title: Hello
##     tags: [roc, web]
##     ---
##     # Hello
##
## `Frontmatter.read` decodes the YAML into a record the app declares, so a missing field or a
## value of the wrong kind is an error that names it, and a field with a default (`??`) may be
## left out.
Frontmatter := [].{

	## The YAML and the body. With no frontmatter, the YAML is `""` and the body is the source.
	## `line` is the body's first line, counting from 1: what a problem in it is reported against.
	split : Str -> { yaml : Str, body : Str, line : U64 }
	split = |source| {
		text = source.drop_prefix("\u(FEFF)").replace_each("\r\n", "\n")
		if !(text.starts_with("---\n") or text == "---") {
			return { yaml: "", body: text, line: 1 }
		}
		lines = text.split_on("\n")
		var $i = 1
		while $i < lines.len() {
			line = Chars.trim_end(lines.get($i) ?? "")
			if line == "---" or line == "..." {
				return {
					yaml: Str.join_with(lines.sublist({ start: 1, len: $i - 1 }), "\n"),
					body: Str.join_with(lines.drop_first($i + 1), "\n"),
					line: $i + 2,
				}
			}
			$i = $i + 1
		}
		# An opening `---` that nothing closes: no frontmatter, and the line is the body's (a rule).
		{ yaml: "", body: text, line: 1 }
	}

	## The frontmatter as the record `data` says, and the body. A problem in the YAML counts its
	## lines from the file's first.
	read : Str -> Try({ data : data, body : Str }, Yaml.Problem)
		where [data.parser_for : Yaml.Reader -> (Yaml.State -> Try({ value : data, rest : Yaml.State }, Yaml.Problem))]
	read = |source| {
		parts = Frontmatter.split(source)
		yaml = match Yaml.parse(parts.yaml) {
			Ok(parsed) => Ok(parsed)
			Err(Syntax({ line, message })) => Err(Syntax({ line: line + 1, message }))
		}?
		data = Yaml.decode(yaml)?
		Ok({ data, body: parts.body })
	}
}

Meta := { title : Str, tags : List(Str) ?? [] }.{
	parser_for : _
	is_eq : _
}

meta : Str -> Try({ data : Meta, body : Str }, Yaml.Problem)
meta = |source| Frontmatter.read(source)

expect Frontmatter.split("---\ntitle: Hi\n---\n# Body\n") == { yaml: "title: Hi", body: "# Body\n", line: 4 }
expect Frontmatter.split("# No frontmatter\n") == { yaml: "", body: "# No frontmatter\n", line: 1 }
expect Frontmatter.split("---\nnot closed\n") == { yaml: "", body: "---\nnot closed\n", line: 1 }
expect Frontmatter.split("\u(FEFF)---\r\na: 1\r\n...\r\nbody") == { yaml: "a: 1", body: "body", line: 4 }
expect meta("---\ntitle: Hello\ntags: [a]\n---\nText") == Ok({ data: { title: "Hello", tags: ["a"] }, body: "Text" })
expect meta("---\ntitle: Hello\n---\n") == Ok({ data: { title: "Hello" }, body: "" })
expect meta("No frontmatter") == Err(MissingField("title"))
expect meta("---\ntitle: a\n  bad: b\n---\n") == Err(Syntax({ line: 3, message: "this line is indented more than the key before it" }))
