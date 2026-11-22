## A post's frontmatter: the YAML between the `---` lines at the top of each file in `content/`,
## decoded into this record by packages/markdown (`Frontmatter`, `Collection`). A field missing or of
## the wrong kind fails the build, naming the file and the field; a field with `??` may be left out.
## What the type can't say (a real date, a known author, tags that are slugs) the content rules
## check (`Rules.roc`).
##
##     ---
##     title: Notes on slow bread
##     date: 2026-02-08
##     author: iris-vale
##     tags: [bread, kitchen]
##     summary: Why the best loaf in the house takes two days and almost no work.
##     cover: /images/bread.svg
##     cover_alt: A round loaf with a deep cross cut into its crust.
##     ---
##
## A post's translation is the file of the same name in the other language's folder
## (`content/en/slow-bread.md`, `content/pl/slow-bread.md`): one slug, shared.
Post := {
	title : Str,
	date : Str,
	author : Str,
	tags : List(Str),
	summary : Str,
	cover : Str ?? "",
	cover_alt : Str ?? "",
}.{
	parser_for : _
}
