import Block
import Frontmatter
import Md
import Yaml

## A collection, as Astro has them: a folder of Markdown files, each with frontmatter of the same
## shape, which the app declares as a record. An entry is a file read: its id (its path in the
## folder, without `.md`), its frontmatter decoded, and its body parsed.
##
## Finding the files is rocx's job: `rocx generate` (which `rocx dev` and `rocx build` run) finds an
## app's collections under `content/` and writes them into `Generated/Content/`. An app may also list
## files itself, each imported as text:
##
##     import "../content/posts/hello.md" as hello : Str
##
##     posts : Try(List(Collection.Entry(Post)), { id : Str, problem : Yaml.Problem })
##     posts = Collection.load([{ path: "hello.md", source: hello }])
Collection := [].{

	## A file of the collection, read.
	Entry(data) : { id : Str, data : data, body : Str, doc : List(Block) }

	## A file: its frontmatter decoded, its body parsed.
	entry : Str, Str -> Try(Collection.Entry(data), { id : Str, problem : Yaml.Problem })
		where [data.parser_for : Yaml.Reader -> (Yaml.State -> Try({ value : data, rest : Yaml.State }, Yaml.Problem))]
	entry = |path, source| {
		named = Collection.id(path)
		match Frontmatter.read(source) {
			Ok({ data, body }) => Ok({ id: named, data, body, doc: Md.parse(body) })
			Err(problem) => Err({ id: named, problem })
		}
	}

	## Every file, in the order given, or the first one whose frontmatter is wrong.
	load : List({ path : Str, source : Str }) -> Try(List(Collection.Entry(data)), { id : Str, problem : Yaml.Problem })
		where [data.parser_for : Yaml.Reader -> (Yaml.State -> Try({ value : data, rest : Yaml.State }, Yaml.Problem))]
	load = |files| files.map_try(|file| Collection.entry(file.path, file.source))

	## An entry's id from its path: `./2026/hello.md` is `2026/hello`.
	id : Str -> Str
	id = |path| path.drop_prefix("./").drop_suffix(".md").drop_suffix(".markdown")

	## The entry with this id.
	find : List(Collection.Entry(data)), Str -> Try(Collection.Entry(data), [NotFound])
	find = |entries, wanted| entries.find_first(|found| found.id == wanted)

	## A problem as a sentence that names the file: `hello: title is missing`.
	describe : { id : Str, problem : Yaml.Problem } -> Str
	describe = |failed| "${failed.id}: ${Yaml.describe(failed.problem)}"
}

Post := { title : Str, draft : Bool ?? Bool.False }.{
	parser_for : _
}

posts : List({ path : Str, source : Str }) -> Try(List(Collection.Entry(Post)), { id : Str, problem : Yaml.Problem })
posts = |files| Collection.load(files)

expect {
	got = posts([{ path: "./2026/hello.md", source: "---\ntitle: Hello\n---\n# Hello\n\nWorld" }, { path: "draft.md", source: "---\ntitle: Soon\ndraft: true\n---\n" }])
	match got {
		Ok([first, second]) => first.id == "2026/hello" and first.data.title == "Hello" and Md.headings(first.doc).len() == 1 and second.data.draft
		_ => Bool.False
	}
}

expect {
	got = posts([{ path: "ok.md", source: "---\ntitle: A\n---\n" }, { path: "bad.md", source: "---\ndraft: true\n---\n" }])
	match got {
		Err(failed) => Collection.describe(failed) == "bad: title is missing"
		Ok(_) => Bool.False
	}
}
