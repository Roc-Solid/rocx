---
title: Small shell scripts that earn their keep
date: 2026-04-04
author: theo-marsh
tags: [code, tools]
summary: Three tiny scripts I use every week, each shorter than this summary, and what they taught me about automating.
---
Most automation advice starts with a framework. Mine starts with a text file in `~/bin`. A shell
script you can read in ten seconds is a script you will still trust in two years, and you will
fix it yourself when it breaks. Here are three I use every week.

## Back up a folder with today's date

I keep an archive of my notes, and before any big reorganisation I take a snapshot. The whole
script is one line, plus a guard:

```sh
#!/bin/sh
# snap: copy a folder next to itself, named with today's date.
set -eu
src="${1:?which folder?}"
cp -R "$src" "${src%/}-$(date +%Y-%m-%d)"
```

`set -eu` makes the script stop on the first error and on any variable I forgot to set. The
`${1:?which folder?}` part stops it with a helpful message when I forget the argument.

## Find what is eating the disk

When the laptop complains about space, this answers the only question I have, which folders
under here are big:

```sh
#!/bin/sh
# big: the ten largest things in the current folder.
du -sh -- * .[!.]* 2>/dev/null | sort -rh | head -n 10
```

## Rename photos by when they were taken

Cameras name files `IMG_4031.JPG`, which tells me nothing. This renames every photo in a folder
to its date, using a small tool that reads the photo's own metadata:

```sh
#!/bin/sh
# photos: rename JPEGs to the moment they were taken, e.g. 2026-03-28_14-02-11.jpg
set -eu
for photo in *.jpg *.JPG; do
	[ -e "$photo" ] || continue
	exiftool -q '-FileName<DateTimeOriginal' -d '%Y-%m-%d_%H-%M-%S%%-c.%%le' "$photo"
done
```

## What they have in common

None of these scripts handle every case, and that is the point. Each one does the job I have,
on the machine I have. When I need more, I add a line. The moment a script needs a configuration
file, I take it as a sign that I have stopped automating a chore and started building a product.
