---
title: Reading JSON by hand
date: 2026-08-29
author: theo-marsh
tags: [code, data]
summary: JSON is small enough to read with your own eyes, if you know the six things it can hold and where it likes to hide trouble.
---
Sooner or later every programmer stares at a wall of curly braces in a log file and tries to work
out what went wrong. JSON is pleasant here: the whole format fits on a postcard[^postcard]. A value
is one of six things, and once you can spot them, any document breaks down into pieces you can
read.

## The six kinds of value

```json
{
  "title": "Night trains, again",
  "minutes": 4,
  "draft": false,
  "cover": null,
  "tags": ["travel", "trains"],
  "author": { "id": "hanna-wierzba", "name": "Hanna Wierzba" }
}
```

A string in double quotes, a number, `true` or `false`, `null`, a list in square brackets, and an
object in curly ones, which maps names to more values. That's all there is. Everything else is
nesting.

## Where the trouble hides

Most broken JSON I meet is broken in one of a handful of ways:

- a trailing comma after the last item of a list or object, which JSON doesn't allow;
- single quotes instead of double quotes, usually from someone writing it by hand;
- a number that is really a string (`"4"` versus `4`), which parses fine and breaks later;
- a missing field that the reading program needed, which is not a syntax error at all.

The last one is the most common and the hardest to see, because the document is perfectly valid.
It is the reason a good program says *which* field it expected, not just that something failed.

## Making it readable

When a document arrives as one long line, ask a tool to indent it before you start reading:

```sh
curl -s https://journal.example.com/api/posts?lang=en | python3 -m json.tool | less
```

Then read it from the outside in: first the shape (a list? an object?), then the names at the top
level, and only then the values. It's the same way you would read an unfamiliar building: find the
doors before you count the windows.

[^postcard]: The whole grammar is drawn as five small diagrams on the format's home page, and a parser for it is a nice weekend exercise.
