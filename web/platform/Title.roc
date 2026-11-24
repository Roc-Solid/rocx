import Html

## `<Title>`, as @solidjs/meta has it: the document's title, from anywhere in the page.
##
##     <Title>{post!().title} · Notes</Title>
##
## The last `<Title>` rendered that is still there is the title: a page's, rendered after its
## layouts', over theirs; one inside an `if`'s part, while it shows. Its holes are computations, so
## the title follows what they read. With none, the root layout's own `<title>` stands. The server
## puts the title in the page's `<head>`, first (`<title data-rocx>`), and the browser keeps
## `document.title` to it, from hydration on; hydrating, nothing in the layout's `<head>` changes.
Title := [].{

	## What `<Title>` is: its children are the document's title, while it is rendered.
	view! : { children : List(Html) } => Html
	view! = |{ children }| Html.document_title(children)
}
