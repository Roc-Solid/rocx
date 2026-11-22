import Fs
import Routes
import Text

## Content collections (D-042): each folder under an app's `content/` is a collection of Markdown
## files, at any depth, which `rocx build` lists in a module of its own,
## `Generated/Content/<Name>.roc` (`content/blog-posts/` is `BlogPosts`): each file imported as
## text, and `files`, the list packages/markdown's `Collection.load` reads. A new file is in it at the
## next build, and one that goes is gone, with nothing listed by hand.
##
## With one `.roc` file beside the Markdown, named for a type (`content/posts/Post.roc`: `Post := {
## title : Str, … }.{ parser_for : _ }`), the module reads the files too, as the app is built: `all`,
## each file's entry (its frontmatter decoded into a `Post`, its body parsed), and `get(id)`. A file
## whose frontmatter is wrong fails the build, naming it.
Content := [].{

	## A collection: its folder's name, its module's, its Markdown files (their paths in the folder,
	## sorted), and the type of their frontmatter, if the folder has one.
	Found : { name : Str, mod : Str, files : List(Str), frontmatter : [Some(Str), None] }

	## The collections under `dir`'s `content/`, or why one can't be.
	collections! : Str => Try(List(Content.Found), [Problem(Str)])
	collections! = |dir| {
		root = Fs.join([dir, "content"])
		if !Fs.is_dir!(root) {
			return Ok([])
		}
		var $found = []
		for entry in Fs.entries!(root) {
			folder = Fs.join([root, entry])
			if !entry.starts_with(".") and Fs.is_dir!(folder) {
				if entry.starts_with("[") or !Routes.is_path_part(entry) {
					return Err(Problem("content/${entry}: a collection's folder is named in lower case (`posts`, `blog-posts`): its module is named after it"))
				}
				files = Fs.files!(folder, ".md", |_| Bool.False).map(|path| Fs.relative(folder, path))
				var $types = []
				for file in Fs.entries!(folder) {
					if file.ends_with(".roc") and Text.is_upper(Text.at(file.to_utf8(), 0)) and Fs.is_file!(Fs.join([folder, file])) {
						$types = $types.append(file)
					}
				}
				types = $types
				kind =
					match types {
						[] => None
						[one] => Some(one.drop_suffix(".roc"))
						_ => return Err(Problem("content/${entry}: one .roc file beside the Markdown, the type of its frontmatter, not ${Str.join_with(types, ", ")}"))
					}
				$found = $found.append({ name: entry, mod: Routes.pascal(entry), files, frontmatter: kind })
			}
		}
		Ok($found)
	}

	## A collection's module: its files imported as text, `files`, and, with a type, `all` and `get`.
	## `markdown` is the name the app's header gives packages/markdown (`Collection`).
	module_text : Content.Found, Str -> Str
	module_text = |found, markdown| {
		at = "content/${found.name}"
		imported = found.files.map_with_index(|path, index| "import \"../../${at}/${path}\" as file_${index.to_str()} : Str")
		listed = found.files.map_with_index(|path, index| "\t\t{ path: ${Text.json_string(path)}, source: file_${index.to_str()} },")
		files =
			if listed.is_empty() {
				["\tfiles : List({ path : Str, source : Str })", "\tfiles = []"]
			} else {
				["\tfiles : List({ path : Str, source : Str })", "\tfiles = ["].concat(listed).append("\t]")
			}
		(head, read) =
			match found.frontmatter {
				None => (
					[
						"## Written by rocx build from ${at}/: its Markdown files, each imported as text, for",
						"## packages/markdown's `Collection.load`. Add, change or remove a file there, not this module.",
					],
					[],
				)
				Some(named) => (
					[
						"## Written by rocx build from ${at}/: its Markdown files, each imported as text, and read as",
						"## the app is built, their frontmatter decoded into a `${named}` (`${at}/${named}.roc`). Add, change or",
						"## remove a file there, not this module.",
						"import ${markdown}.Collection",
						"import ../../${at}/${named}",
					],
					[
						"",
						"\t## Every file read: its id (its path without `.md`), its frontmatter, decoded into a `${named}`, and",
						"\t## its body, parsed. Read when the app is built: a file whose frontmatter is wrong fails the",
						"\t## build, and the message names it.",
						"\tall : List(Collection.Entry(${named}))",
						"\tall =",
						"\t\tmatch Collection.load(${found.mod}.files) {",
						"\t\t\tOk(entries) => entries",
						"\t\t\tErr(failed) => crash \"${at}/\${Collection.describe(failed)}\"",
						"\t\t}",
						"",
						"\t## The entry with this id (`\"2026/hello\"`).",
						"\tget : Str -> Try(Collection.Entry(${named}), [NotFound])",
						"\tget = |id| Collection.find(${found.mod}.all, id)",
					],
				)
			}
		lines =
			head
				.concat(imported)
				.concat(["", "${found.mod} := [].{", "\t## The folder's Markdown files, each with its path in the folder, in the order of their paths."])
				.concat(files)
				.concat(read)
				.concat(["}", "", "${Routes.marker} ${at}/: edit the files there, not this module.", ""])
		Str.join_with(lines, "\n")
	}
}

sample : Content.Found
sample = { name: "blog-posts", mod: "BlogPosts", files: ["hello.md", "2026/later.md"], frontmatter: None }

expect Content.module_text(sample, "markdown").contains("import \"../../content/blog-posts/2026/later.md\" as file_1 : Str")
expect Content.module_text(sample, "markdown").contains("\t\t{ path: \"2026/later.md\", source: file_1 },")
expect !Content.module_text(sample, "markdown").contains("Collection")
expect Content.module_text({ ..sample, frontmatter: Some("Post") }, "md").contains("import md.Collection\nimport ../../content/blog-posts/Post")
expect Content.module_text({ ..sample, frontmatter: Some("Post") }, "md").contains("\tall : List(Collection.Entry(Post))")
expect Content.module_text({ ..sample, files: [] }, "markdown").contains("\tfiles = []")
