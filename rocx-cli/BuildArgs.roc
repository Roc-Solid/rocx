## `rocx build`'s words read (D-107): which build, the app's directory, where it goes, and the rest
## for that build's own reader (`Release.options`, `Image.options`, `Static.options`).
##
## - `rocx build [dir]` is the release (dist/), `--image` the container image (<name>.tar), and
##   `--static` the static copy (dist/); `--out PATH` says where, else those.
## - The words before D-107 still read as they did: `--release <out>`, `--image <file.tar>`,
##   `<dir> --static <out>`; and `--client`, `--dev` or more than one directory is code generation
##   alone (`rocx generate`, what `rocx build <dir>…` was).

BuildArgs := [].{

	Read : { mode : [Release, Image, Static, Generate], dir : Str, out : Str, rest : List(Str) }

	## The flags that take a value, their value the next word.
	valued : List(Str)
	valued = ["--out", "--target", "--tag", "--base", "--route", "--built", "--release", "--opt"]

	read : List(Str) -> Read
	read = |args| {
		before = BuildArgs.until_dashes(args)
		after = args.drop_first(before.len())
		moded = before.contains("--image") or before.contains("--static") or before.contains("--release")
		if !moded and (before.contains("--client") or before.contains("--dev")) {
			return { mode: Generate, dir: before.first() ?? ".", out: "", rest: args }
		}
		mode = if (before.contains("--image")) Image else if (before.contains("--static")) Static else Release
		var $dirs = []
		var $out = ""
		var $rest = []
		var $i = 0
		while $i < before.len() {
			word = before.get($i) ?? ""
			next = before.get($i + 1) ?? ""
			takes_next = !next.is_empty() and !next.starts_with("-")
			if (word == "--out" or word == "--release") and takes_next {
				$out = next
				$i = $i + 2
			} else if word == "--out" or word == "--release" {
				# No value: left for the build's own reader to refuse.
				$rest = $rest.append(word)
				$i = $i + 1
			} else if BuildArgs.valued.contains(word) {
				$rest = $rest.concat([word, next])
				$i = $i + 2
			} else if word == "--image" and takes_next and next.ends_with(".tar") {
				# `--image <file.tar>`, as before D-107.
				$out = next
				$i = $i + 2
			} else if word == "--static" and takes_next and !$dirs.is_empty() {
				# `<dir> --static <out>`, as before D-107.
				$out = next
				$i = $i + 2
			} else if word == "--image" or word == "--static" {
				$i = $i + 1
			} else if word.starts_with("-") {
				$rest = $rest.append(word)
				$i = $i + 1
			} else {
				$dirs = $dirs.append(word)
				$i = $i + 1
			}
		}
		if mode == Release and !before.contains("--release") and $dirs.len() > 1 {
			return { mode: Generate, dir: $dirs.first() ?? ".", out: "", rest: args }
		}
		# A second directory is left for the build's own reader to refuse.
		{ mode, dir: $dirs.first() ?? ".", out: $out, rest: $dirs.drop_first(1).concat($rest).concat(after) }
	}

	## The words before `--` (the server's options, for `--static`, come after it).
	until_dashes : List(Str) -> List(Str)
	until_dashes = |args|
		match args.find_first_index(|word| word == "--") {
			Ok(at) => args.take_first(at)
			Err(_) => args
		}
}

expect BuildArgs.read([]) == { mode: Release, dir: ".", out: "", rest: [] }
expect BuildArgs.read(["app", "--target", "arm64musl"]) == { mode: Release, dir: "app", out: "", rest: ["--target", "arm64musl"] }
expect BuildArgs.read(["--out", "out"]) == { mode: Release, dir: ".", out: "out", rest: [] }
expect BuildArgs.read([".", "--release", "dist"]) == { mode: Release, dir: ".", out: "dist", rest: [] }
expect BuildArgs.read(["--image"]) == { mode: Image, dir: ".", out: "", rest: [] }
expect BuildArgs.read([".", "--image", "build/app.tar", "--tag", "app:1", "--target", "arm64musl"]) == { mode: Image, dir: ".", out: "build/app.tar", rest: ["--tag", "app:1", "--target", "arm64musl"] }
expect BuildArgs.read(["--image", "app"]) == { mode: Image, dir: "app", out: "", rest: [] }
expect BuildArgs.read(["--static"]) == { mode: Static, dir: ".", out: "", rest: [] }
expect BuildArgs.read(["site", "--static", "site/dist", "--base", "/rocx/", "--", "--debug"]) == { mode: Static, dir: "site", out: "site/dist", rest: ["--base", "/rocx/", "--", "--debug"] }
expect BuildArgs.read(["--static", "app"]) == { mode: Static, dir: "app", out: "", rest: [] }
expect BuildArgs.read(["app", "--client", "out"]).mode == Generate
expect BuildArgs.read(["app", "--dev"]).mode == Generate
expect BuildArgs.read(["a", "b"]).mode == Generate
expect BuildArgs.read(["app", "--static", "dist", "--dev"]) == { mode: Static, dir: "app", out: "dist", rest: ["--dev"] }
expect BuildArgs.read(["a", "b", "--static", "dist"]) == { mode: Static, dir: "a", out: "dist", rest: ["b"] }
expect BuildArgs.read(["app", "--static", "--out"]) == { mode: Static, dir: "app", out: "", rest: ["--out"] }
