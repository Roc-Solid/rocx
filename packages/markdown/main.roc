## Markdown: a parser in plain Roc (CommonMark, and GitHub's tables, strikethrough, task lists,
## bare links and footnotes) that makes a document a tree of `Block`s and `Inline`s (`Md.parse`)
## an app can walk, and renders it as HTML text (`Md.to_html`). `Frontmatter` reads a file's YAML
## (`Yaml`) into a record the app declares, and `Collection` makes a folder of Markdown files typed
## entries. It is plain Roc, on no platform, so the server and a page in the browser use the same
## code.
##
## The component (`<Markdown>`) is in `components/`: rocx copies it into each app that names this
## package (`rocx generate`), since a package can't import a platform's `Html` for both apps at
## once. `Spec` is the specs' examples, as tests. See README.md.
package [Block, Collection, Frontmatter, Inline, Md, Spec, Yaml] {}
