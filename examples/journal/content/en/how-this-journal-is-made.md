---
title: How this journal is made
date: 2026-11-07
author: theo-marsh
tags: [code, colophon]
summary: Markdown files, a Roc program, two small islands of interactivity and no database. A tour of the machinery behind these pages.
---
Iris asked me to write down how the journal works, mostly so that she can add a post without
asking me. So this is the colophon: what the pages are made of, and why it is built the way it is.

## Posts are files

Each post is a Markdown file in a folder named after its language, `content/en/` or `content/pl/`.
A translation is simply the file with the same name in the other folder. At the top of each file,
between two lines of dashes, is the frontmatter: a few fields of YAML that say what the post is.

```yaml
---
title: Notes on slow bread
date: 2026-02-14
author: iris-vale
tags: [bread, kitchen]
summary: Why the best loaf in the house takes two days and almost no work.
cover: /images/bread.svg
cover_alt: A round loaf on a wooden board.
---
```

The program reads every file when it is compiled, not when someone visits. The frontmatter is
decoded into a typed record, so a missing title or a date written the wrong way round is not a
broken page in production. It's a compile error that names the file and the field.

## The rules the compiler checks

Some rules don't fit into a type, so they live in a small module that runs over every post before
the program is built:

| Rule                                   | Why                                       |
|:---------------------------------------|:------------------------------------------|
| the date is a real day, `YYYY-MM-DD`    | so the post sorts and prints correctly     |
| the author is one of ours              | so their page and name exist              |
| one to five tags, each a slug          | so every tag has a tidy address           |
| a cover has a description              | for readers who can't see the image       |
| no `#` headings in the body            | the title is the page's only top heading  |
| every footnote is referred to, once    | so each back link has one place to go     |

If any rule fails, the build fails and lists every problem at once.

## Pages are rendered once

The site is written in Roc, with a web framework called Roc Solid. Every page is rendered on the
server: the article, the lists, the masthead, the footer. Almost all of it is marked so that the
browser never runs it again; the HTML arrives finished and stays as it is. That keeps the pages
fast and the Markdown parser out of your browser entirely.

Only two things on the site are interactive. The search page filters titles and tags as you type,
and the row of reactions under each post shows your click immediately, before the server has
answered. Those are small islands of compiled WebAssembly in an otherwise static page.

## Reactions without a database

The reaction counts live in the server's memory, in a key-value store with atomic operations.
Each count is a counter, and whether you have given a reaction is a key that only one request can
create. Clicking twice very fast still counts once.

```roc
match Kv.add!(mark, Bool.True, {}) {
	Ok({}) => { _ = Kv.increment!(count, 1, {}) }
	Err(Exists) => {}
}
```

A restart forgets everything, and that is fine: reactions are a friendly gesture, not a ledger.
A rate limit stops anyone from applauding a post four hundred times a minute.

## Machine-readable parts

Each language has an Atom feed for feed readers, there is a sitemap that tells search engines
which pages are translations of which, and a small JSON API lists the posts with their URLs and
translations. The API describes itself in an OpenAPI document, which you can browse from the
footer.

## Adding a post

Write the file, add two lines to the list of posts in `Posts.roc`, and build. If the build passes,
the post is fine. If it doesn't, the message says what to fix. That is the whole workflow, and
it is the reason I'm happy to hand it over.
