## Stories: the ways a component looks, written beside it (`<story name="Tip">…</story>` in its
## block), and a dev build's catalog of them at /__rocx/stories, Storybook's job. The transpiler
## makes each story a definition in its place (`story_tip`), which every build checks and only a
## dev build (`rocx build --dev`) calls: Generated/Routes answers /__rocx/stories/<id> with the
## story in the app's layout, and /__rocx/stories with this file's catalog, a page of its own.
##
## A story is a component's. An app's stories/ directory holds modules of stories alone, of drafts
## beside one another (`stories/Landing.rocx`): a dev build compiles them for their stories, and the
## app's own build skips the directory, so nothing in it (its <style>s neither) is published.
## (Was src/stories.mjs.)
import Value
import Text
import "catalog.html" as catalog_template : Str

Stories := [].{

	## A story as rocx build finds it: the file and module it is in, its component, its name, its
	## definition (`story_tip!`) and the line of its `<story>`.
	Story : { file : Str, module_path : Str, component : Str, name : Str, def : Str, line : U64 }

	## A story with its id, the rest of its URL under /__rocx/stories, and the name Root imports its
	## module as (`StoryUiCallout`).
	Placed : { file : Str, module_path : Str, component : Str, name : Str, def : Str, line : U64, id : Str, alias : Str }

	## Where the catalog is, and each story under it: a dev build's, beside the host's `/__rocx/mail`.
	stories_path : Str
	stories_path = "/__rocx/stories"

	## An app's directory of modules that hold stories alone (`stories/Landing.rocx`, drafts beside one
	## another): a dev build compiles them, and another build skips the directory, its styles too.
	stories_dir : Str
	stories_dir = "stories"

	## The last lines of every generated file start with this.
	marker : Str
	marker = "# rocx: generated from"

	## A name in lower case, its runs of other characters one `-`, none at its ends: `Wide hero` is
	## `wide-hero`.
	kebab : Str -> Str
	kebab = |words| {
		var $out = []
		var $dash = Bool.False
		for code in Text.code_points(words) {
			# JavaScript's toLowerCase: A to Z, and the two characters it lowers into ASCII.
			lowered =
				if code >= 'A' and code <= 'Z' {
					[code + 32]
				} else if code == 0x0130 {
					['i', 0x0307]
				} else if code == 0x212A {
					['k']
				} else {
					[code]
				}
			for c in lowered {
				if (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') {
					if $dash and !$out.is_empty() {
						$out = $out.append('-')
					}
					$dash = Bool.False
					$out = $out.append(c.to_u8_wrap())
				} else {
					$dash = Bool.True
				}
			}
		}
		Str.from_utf8_lossy($out)
	}

	## A module's path as the name Root imports it by: each part's words capitalised, the rest
	## dropped (`stories/Landing` is `StoriesLanding`), after `Story`.
	alias_of : Str -> Str
	alias_of = |path| {
		part_name = |part| {
			bytes = part.to_utf8()
			var $out = []
			var $i = 0
			while $i < bytes.len() {
				c = Text.at(bytes, $i)
				starts = $i == 0 or !Text.is_alnum(Text.at(bytes, $i - 1))
				if starts and (Text.is_lower(c) or Text.is_digit(c)) {
					$out = $out.append(if (Text.is_lower(c)) c - 32 else c)
				} else if Text.is_alnum(c) {
					$out = $out.append(c)
				}
				$i = $i + 1
			}
			Str.from_utf8_lossy($out)
		}
		"Story".concat(Str.join_with(path.split_on("/").map(part_name), ""))
	}

	## A story's id: its module's path, its component's name unless it is the module's
	## (`Ui/Callout/tip`, `stories/Landing/Split/hero`), and its name.
	id_of : Story -> Str
	id_of = |story| {
		last = story.module_path.split_on("/").last() ?? ""
		parts = if (story.component == last) [story.module_path] else [story.module_path, story.component]
		Str.join_with(parts.append(Stories.kebab(story.name)), "/")
	}

	## Each story with its id and alias. A problem when two would be at one id.
	story_ids : List(Story) -> Try(List(Placed), [Problem(Str)])
	story_ids = |stories| {
		var $placed = []
		for story in stories {
			id = Stories.id_of(story)
			match $placed.find_first(|other| other.id == id) {
				Ok(other) => return Err(Problem("${story.file}:${story.line.to_str()}: the story \"${story.name}\" would be at ${Stories.stories_path}/${id}, as ${other.file}:${other.line.to_str()}'s is: rename one"))
				Err(_) => {}
			}
			$placed = $placed.append({ file: story.file, module_path: story.module_path, component: story.component, name: story.name, def: story.def, line: story.line, id, alias: Stories.alias_of(story.module_path) })
		}
		Ok($placed)
	}

	## Generated/Stories.roc: the catalog's page, which Generated/Routes answers /__rocx/stories with.
	stories_module : List(Placed), Str, Str -> Str
	stories_module = |stories, title, root| {
		html = Stories.catalog_html(stories, title, root)
		quoted = Str.join_with(html.split_on("\n").map(|line| "\t\t${Text.roc_string(line)},"), "\n")
		Str.join_with(
			[
				"## A dev build's catalog of the app's stories (`<story>` in a component's block): the page",
				"## Generated/Routes answers /__rocx/stories with. Written by rocx build --dev.",
				"Stories := [].{",
				"\tcatalog : Str",
				"\tcatalog = Str.join_with([\n${quoted}\n\t], \"\\n\")",
				"}",
				"",
				"${Stories.marker} the app's stories: rocx build --dev writes it.",
				"",
			],
			"\n",
		)
	}

	## Text as HTML shows it.
	escape_html : Str -> Str
	escape_html = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;")

	## The catalog's list of stories, as its script reads it (JSON, a `<` written `\u003c`, so a name
	## can't end the script): drafts (stories/) first, then components', each as rocx build found them.
	catalog_data : List(Placed), Str -> Str
	catalog_data = |stories, root| {
		draft = |file| file.starts_with("${Stories.stories_dir}/")
		entry = |story|
			Object(
				[
					{ key: "id", value: Text(story.id) },
					{ key: "file", value: Text(story.file) },
					{ key: "component", value: Text(story.component) },
					{ key: "name", value: Text(story.name) },
					{ key: "line", value: Value.count(story.line) },
					{ key: "kind", value: Text(if (draft(story.file)) "draft" else "component") },
					{ key: "path", value: Text("${root}/${story.file}") },
				],
			)
		drafts = stories.keep_if(|story| draft(story.file)).map(entry)
		others = stories.keep_if(|story| !draft(story.file)).map(entry)
		Value.encode(Array(drafts.concat(others))).replace_each("<", "\\u003c")
	}

	## The catalog: a page of its own (src/catalog.html), whose script needs nothing but the list it
	## is given.
	catalog_html : List(Placed), Str, Str -> Str
	catalog_html = |stories, title, root| {
		titled = Stories.escape_html(title)
		data = Stories.catalog_data(stories, root)
		# The template's places, filled once each, in order: what fills one isn't read for the next.
		around_title = catalog_template.split_on("@@TITLE@@")
		head = around_title.get(0) ?? ""
		middle = around_title.get(1) ?? ""
		around_data = (around_title.get(2) ?? "").split_on("@@DATA@@")
		head.concat(titled).concat(middle).concat(titled).concat(around_data.get(0) ?? "").concat(data).concat(around_data.get(1) ?? "")
	}

	## A story from the JSON rocx internal is given.
	story_of : Value -> Story
	story_of = |value| {
		file: Value.str(Value.field(value, "file")),
		module_path: Value.str(Value.field(value, "module")),
		component: Value.str(Value.field(value, "component")),
		name: Value.str(Value.field(value, "name")),
		def: Value.str(Value.field(value, "def")),
		line: Value.int_or(Value.field(value, "line"), 0).to_u64_wrap(),
	}

	## A placed story from the JSON rocx internal is given.
	listed_of : Value -> Placed
	listed_of = |value| {
		file: Value.str(Value.field(value, "file")),
		module_path: Value.str(Value.field(value, "module")),
		component: Value.str(Value.field(value, "component")),
		name: Value.str(Value.field(value, "name")),
		def: Value.str(Value.field(value, "def")),
		line: Value.int_or(Value.field(value, "line"), 0).to_u64_wrap(),
		id: Value.str(Value.field(value, "id")),
		alias: Value.str(Value.field(value, "alias")),
	}

	## `{ ...story, id, alias }`: the story's own fields, in their order, with its id and alias.
	placed_value : Value, Placed -> Value
	placed_value = |given, placed| {
		set = |pairs, key, value|
			if pairs.any(|each| each.key == key) {
				pairs.map(|each| if (each.key == key) { key, value } else each)
			} else {
				pairs.append({ key, value })
			}
		Object(set(set(Value.fields(given), "id", Text(placed.id)), "alias", Text(placed.alias)))
	}

	## `rocx internal`'s calls of this module's functions (src/rocx.mjs names them), by name.
	rpc : Str, List(Value) -> Try(Value, [Failed(Value), Unknown(Str)])
	rpc = |name, args| {
		arg = |i| args.get(i) ?? Null
		options = arg(1)
		title = Value.str_or(Value.field(options, "title"), "app")
		root = Value.str_or(Value.field(options, "root"), ".")
		match name {
			"storyIds" => {
				given = Value.items(arg(0))
				match Stories.story_ids(given.map(Stories.story_of)) {
					Ok(placed) => Ok(Array(List.map2(given, placed, Stories.placed_value)))
					Err(Problem(message)) => Err(Failed(Value.problem(message)))
				}
			}
			"storiesModule" => Ok(Text(Stories.stories_module(Value.items(arg(0)).map(Stories.listed_of), title, root)))
			"catalogHtml" => Ok(Text(Stories.catalog_html(Value.items(arg(0)).map(Stories.listed_of), title, root)))
			_ => Err(Unknown(name))
		}
	}
}
