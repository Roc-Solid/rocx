## `rocx render <url> [-o out.mp4] [-o out.webm] [-o frames/] …`: a `<Player>` (packages/video)
## filmed into video files, in Roc (packages/headless drives Chromium's headless shell; it was
## packages/video's render.mjs, in Node). The page at the URL is opened and let hydrate in real
## time, then its clock is taken over (packages/video's clock.js, run before the page's scripts):
## each frame in turn, the clock moves on by a frame, the player is sought to it (its own scrubber),
## the page settles, its animations are put where the clock says, and the player's stage is
## photographed. A frame looks the same however long it took, so two renders of one composition are
## the same frame for frame. ffmpeg writes .mp4 (H.264) and .webm (VP9) from the photographs; a
## folder (`frames/`) gets them as PNGs.
import pf.Cmd
import pf.Env
import pf.File
import pf.Stderr
import pf.Stdout
import pf.Time
import headless.Chrome
import headless.Tab
import tools.JsonValue
import Term
import "../packages/video/clock.js" as clock_js : Str

Render := [].{

	## What the command line asks for.
	Options : { url : Str, outputs : List(Str), player : Str, scale : Str, from : Try(U64, [None]), to : Try(U64, [None]), crf : Str }

	## The command line's words read: the URL, each `-o`, and the options; `Err` says what is wrong.
	options : List(Str) -> Try(Options, [Usage(Str)])
	options = |words| {
		var $options = { url: "", outputs: [], player: "0", scale: "2", from: Err(None), to: Err(None), crf: "18" }
		var $i = 0
		while $i < words.len() {
			word = words.get($i) ?? ""
			value = words.get($i + 1)
			number = |name| match value.map_err(|_| Missing).map_ok(U64.from_str) {
				Ok(Ok(n)) => Ok(n)
				_ => Err(Usage("${name} takes a whole number"))
			}
			if word == "-o" or word == "--out" or word == "--player" or word == "--scale" or word == "--from" or word == "--to" or word == "--crf" {
				given = value.map_err(|_| Usage("${word} needs a value"))?
				if word == "-o" or word == "--out" {
					$options = { ..$options, outputs: $options.outputs.append(given) }
				} else if word == "--player" {
					$options = { ..$options, player: given }
				} else if word == "--scale" {
					_ = F64.from_str(given).map_err(|_| Usage("--scale takes a number"))?
					$options = { ..$options, scale: given }
				} else if word == "--from" {
					$options = { ..$options, from: Ok(number("--from")?) }
				} else if word == "--to" {
					$options = { ..$options, to: Ok(number("--to")?) }
				} else {
					_ = number("--crf")?
					$options = { ..$options, crf: given }
				}
				$i = $i + 2
			} else if word.starts_with("-") {
				return Err(Usage("no option ${word}"))
			} else if !$options.url.is_empty() {
				return Err(Usage("one URL: ${$options.url}, then ${word}"))
			} else {
				$options = { ..$options, url: word }
				$i = $i + 1
			}
		}
		if $options.url.is_empty() {
			Err(Usage("which page? rocx render <url> [-o out.mp4] [-o out.webm] [-o frames/]"))
		} else if $options.outputs.is_empty() {
			Ok({ ..$options, outputs: ["video.mp4"] })
		} else {
			Ok($options)
		}
	}

	## `rocx render …`: the player filmed, each output written, and what was written said.
	run! : List(Str) => Try({}, [Exit(I32)])
	run! = |words| {
		styled = Term.styled!({})
		match Render.options(words) {
			Err(Usage(why)) => {
				_ = Stderr.line!("${Term.red(styled, "rocx render: ${why}")}. rocx help render says what it takes.")
				Err(Exit(2))
			}
			Ok(asked) => {
				started = Time.now_ms!({})
				match Render.film!(asked, |line| Stdout.line!(line) ?? {}) {
					Ok(made) => {
						for error in made.errors {
							_ = Stderr.line!("the page threw: ${error}")
						}
						seconds = (Time.now_ms!({}) - started).to_f64() / 1000
						_ = Stdout.line!("${Term.green(styled, "✓")} wrote ${Str.join_with(asked.outputs, ", ")}: ${made.frames.to_str()} frames, ${made.width} by ${made.height}, in ${tenths(seconds)} s")
						Ok({})
					}
					Err(Failed(why)) => {
						_ = Stderr.line!(Term.red(styled, "rocx render: ${why}"))
						Err(Exit(1))
					}
				}
			}
		}
	}

	## The player filmed and each output written: how many frames, their size in pixels, and what
	## the page threw. `log` hears what is about to be filmed.
	film! : Options, (Str => {}) => Try({ frames : U64, width : Str, height : Str, errors : List(Str) }, [Failed(Str)])
	film! = |asked, log!| {
		videos = asked.outputs.keep_if(|out| !out.ends_with("/"))
		folders = asked.outputs.keep_if(|out| out.ends_with("/"))
		for out in videos {
			_ = output_args(out, asked.crf)?
		}
		ffmpeg = if (videos.is_empty()) "" else find_ffmpeg!({})?
		binary = Chrome.find!({}).map_err(|NoChrome(how)| Failed("rendering needs Chromium's headless shell: ${how}"))?
		chrome = Chrome.launch!(binary).map_err(|CantLaunch(why)| Failed(why))?
		# For the videos, each frame a PNG in a temporary folder, which ffmpeg reads once the last is
		# taken; the folder goes however filming ends.
		temporary = (Env.var!("TMPDIR") ?? "/tmp").drop_suffix("/")
		stills = if (videos.is_empty()) "" else "${temporary}/rocx-render-${Env.pid!({}).to_str()}-${Time.now_ns!({}).to_str()}"
		filmed = film_in!(chrome, asked, if (stills.is_empty()) folders else folders.append("${stills}/"), log!)
		Chrome.close!(chrome)
		made = match filmed {
			Ok(done) if !stills.is_empty() => encode!(ffmpeg, stills, done.first, done.fps, videos, asked.crf).map_ok(|{}| done)
			other => other
		}
		if !stills.is_empty() {
			_ = File.delete!(stills)
		}
		made.map_ok(|done| { frames: done.frames, width: done.width, height: done.height, errors: done.errors })
	}
}

## What `film!` does once the browser runs (it is closed after, however this ends): each frame a PNG
## in each of `places` (folders, each path ending in `/`).
film_in! : Chrome, Render.Options, List(Str), (Str => {}) => Try({ frames : U64, first : U64, fps : U64, width : Str, height : Str, errors : List(Str) }, [Failed(Str)])
film_in! = |chrome, asked, places, log!| {
	tab = Chrome.open!(chrome)?
	# A page that loads the runtime is filmed once it has hydrated (`rocx:ready`).
	Tab.before_each_document!(tab, "document.addEventListener(\"rocx:ready\", (event) => { window.__rocxReady = { ms: event.detail?.ms ?? 0 }; });\n${clock_js}")?
	Tab.goto!(tab, asked.url, 10_000)?
	if Tab.eval!(tab, "Boolean(document.querySelector('script[src$=\"rocx/start.js\"]'))")? == Boolean(Bool.True) {
		match Tab.wait!(tab, "window.__rocxReady", 10_000) {
			Ok({}) => {}
			Err(_) => return Err(Failed("${asked.url} didn't hydrate in 10 s; it threw ${Str.inspect(Tab.errors!(tab))}"))
		}
	}
	wanted = if (!asked.player.is_empty() and asked.player.to_utf8().all(|byte| byte >= '0' and byte <= '9')) asked.player else JsonValue.to_str(String(asked.player))
	found = Tab.eval!(
		tab,
		\\(() => {
		\\	const players = [...document.querySelectorAll("[data-rocx-video]")];
		\\	const wanted = ${wanted};
		\\	const index = typeof wanted === "number" ? wanted : players.findIndex((each) => each.getAttribute("aria-label") === wanted);
		\\	const chosen = players[index];
		\\	if (!chosen) return { count: players.length };
		\\	players.forEach((each, i) => (each.dataset.rocxFilmed = i === index ? "yes" : "no"));
		\\	return { count: players.length, fps: Number(chosen.dataset.fps), frames: Number(chosen.dataset.frames), width: Number(chosen.dataset.width), height: Number(chosen.dataset.height) };
		\\})()
	)?
	count = whole(found, "count")
	fps = whole(found, "fps")
	frames = whole(found, "frames")
	width = whole(found, "width")
	height = whole(found, "height")
	if found.get("fps").is_err() or frames == 0 {
		return Err(Failed("${asked.url} has ${count.to_str()} player${if (count == 1) "" else "s"} (<Player>, [data-rocx-video]); none is ${wanted}"))
	}
	first = (asked.from ?? 0).min(frames - 1)
	last = (asked.to ?? (frames - 1)).min(frames - 1).max(first)
	# The player at its own width, alone in its stage: its controls hidden, a scaled one at 1.
	_ = Tab.eval!(
		tab,
		\\(() => {
		\\	const style = document.createElement("style");
		\\	style.textContent = '[data-rocx-filmed="yes"] { width: ${width.to_str()}px !important; max-width: none !important; margin: 0 !important; } [data-rocx-filmed="yes"] .video-controls { display: none !important; } [data-rocx-filmed="yes"].video-scale { --video-scale: 1 !important; }';
		\\	document.head.append(style);
		\\})()
	)?
	scale = F64.from_str(asked.scale) ?? 2
	view = { width: width + 64, height: height.max(200) + 64 }
	Tab.viewport!(tab, { width: view.width, height: view.height, scale })?
	_ = Tab.eval!(tab, "(async () => { window.__rocxClock.freeze(); await window.__rocxClock.settle(); })()")?
	# The stage's place, with the page laid out at this width; a taller one gets a taller view.
	placed = place!(tab, view.height)?
	box = if (placed.taller == 0) placed else {
		Tab.viewport!(tab, { width: view.width, height: placed.taller, scale })?
		place!(tab, view.height)?
	}
	# What the page puts over the player isn't filmed: a fixed or sticky element (a top bar, a
	# page's table of contents), or one placed over it, outside the player and not around it.
	_ = Tab.eval!(
		tab,
		\\(() => {
		\\	const filmed = document.querySelector('[data-rocx-filmed="yes"]');
		\\	const stage = filmed.querySelector(".video-stage").getBoundingClientRect();
		\\	for (const element of document.body.querySelectorAll("*")) {
		\\		if (filmed.contains(element) || element.contains(filmed)) continue;
		\\		const position = getComputedStyle(element).position;
		\\		if (position === "static" || position === "relative") continue;
		\\		const box = element.getBoundingClientRect();
		\\		const over = box.right > stage.left && box.left < stage.right && box.bottom > stage.top && box.top < stage.bottom;
		\\		if (position === "fixed" || position === "sticky" || over) element.style.setProperty("visibility", "hidden", "important");
		\\	}
		\\})()
	)?
	pixels = |n| scaled(n, scale)
	log!("filming ${(last - first + 1).to_str()} frames at ${fps.to_str()} a second, ${box.width.to_str()} by ${box.height.to_str()} (${pixels(box.width)} by ${pixels(box.height)} pixels)")
	for folder in places {
		File.make_dirs!(folder).map_err(|CantWrite(why)| Failed(why))?
	}
	clip = Clip({ x: box.x.to_f64(), y: box.y.to_f64(), width: box.width.to_f64(), height: box.height.to_f64() })
	var $index = first
	while $index <= last {
		_ = Tab.eval!(
			tab,
			\\(async () => {
			\\	const clock = window.__rocxClock;
			\\	clock.advance(${if ($index == first) "0" else "1000 / ${fps.to_str()}"});
			\\	const seek = document.querySelector('[data-rocx-filmed="yes"] .video-seek');
			\\	seek.value = "${$index.to_str()}";
			\\	seek.dispatchEvent(new Event("input", { bubbles: true }));
			\\	await clock.settle();
			\\	${if ($index == first) "clock.finishAll();" else ""}
			\\	clock.sync();
			\\})()
		)?
		png = Tab.screenshot!(tab, clip)?
		for folder in places {
			File.write_bytes!("${folder}${frame_name($index)}", png).map_err(|CantWrite(why)| Failed(why))?
		}
		$index = $index + 1
	}
	errors = Tab.errors!(tab)
	Tab.close!(tab)
	Ok({ frames: last - first + 1, first, fps, width: pixels(box.width), height: pixels(box.height), errors })
}

## Where the filmed player's stage is, in whole CSS pixels from the document's top left, scrolled
## to; `taller`, the view's height it needs when it doesn't fit in `view_height` (else 0).
place! : Tab, U64 => Try({ x : U64, y : U64, width : U64, height : U64, taller : U64 }, [Failed(Str)])
place! = |tab, view_height| {
	box = Tab.eval!(
		tab,
		\\(() => {
		\\	const stage = document.querySelector('[data-rocx-filmed="yes"] .video-stage');
		\\	stage.scrollIntoView({ block: "start", inline: "start" });
		\\	const box = stage.getBoundingClientRect();
		\\	return { x: Math.round(box.left + scrollX), y: Math.round(box.top + scrollY), width: Math.round(box.width), height: Math.round(box.height), taller: box.height + 64 > ${view_height.to_str()} ? Math.ceil(box.height) + 64 : 0 };
		\\})()
	)?
	Ok({ x: whole(box, "x"), y: whole(box, "y"), width: whole(box, "width"), height: whole(box, "height"), taller: whole(box, "taller") })
}

## A whole number field of what the page answered; 0 when it isn't one.
whole : JsonValue, Str -> U64
whole = |value, key|
	match value.get(key) {
		Ok(Number(text)) => U64.from_str(text) ?? 0
		_ => 0
	}

## CSS pixels as device pixels at `scale`: `1280` at 2 is `2560`.
scaled : U64, F64 -> Str
scaled = |n, scale| (n.to_f64() * scale).to_str().drop_suffix(".0")

## Seconds to a tenth: `12.3`.
tenths : F64 -> Str
tenths = |seconds| {
	text = (seconds * 10).to_str()
	tens = U64.from_str(text.split_first(".").map_ok(|parts| parts.before) ?? text) ?? 0
	"${(tens // 10).to_str()}.${(tens % 10).to_str()}"
}

## A frame's file: `frame-00042.png`.
frame_name : U64 -> Str
frame_name = |index| {
	digits = index.to_str()
	"frame-${Str.repeat("0", 5 - digits.count_utf8_bytes().min(5))}${digits}.png"
}

## ffmpeg's arguments that write `out` from the frames: H.264 for .mp4, VP9 for .webm, each in 4:2:0
## (what every player plays), its size made even.
output_args : Str, Str -> Try(List(Str), [Failed(Str)])
output_args = |out, crf| {
	even = ["-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2"]
	lower = Str.with_ascii_lowercased(out)
	if lower.ends_with(".mp4") {
		Ok(even.concat(["-c:v", "libx264", "-preset", "slow", "-crf", crf, "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]))
	} else if lower.ends_with(".webm") {
		Ok(even.concat(["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p", out]))
	} else {
		Err(Failed("${out}: a video is written as .mp4 or .webm (or frames into a folder, ending in /)"))
	}
}

## One ffmpeg writing every video from the frames in `stills` (`frame-<index>.png`, from `first`).
encode! : Str, Str, U64, U64, List(Str), Str => Try({}, [Failed(Str)])
encode! = |ffmpeg, stills, first, fps, videos, crf| {
	var $outputs = []
	for out in videos {
		dir = dirname(out)
		if !dir.is_empty() {
			File.make_dirs!(dir).map_err(|CantWrite(why)| Failed(why))?
		}
		$outputs = $outputs.concat(output_args(out, crf)?)
	}
	args = ["-hide_banner", "-loglevel", "error", "-y", "-framerate", fps.to_str(), "-start_number", first.to_str(), "-i", "${stills}/frame-%05d.png"].concat($outputs)
	match Cmd.new(ffmpeg).args(args).output!() {
		Ok({ code: 0, .. }) => Ok({})
		Ok({ code, stderr, .. }) => Err(Failed("ffmpeg failed (${code.to_str()}): ${stderr}"))
		Err(CantStart(why)) => Err(Failed("ffmpeg: ${why}"))
	}
}

## The directory part of a path ("" for a file here).
dirname : Str -> Str
dirname = |path| {
	parts = path.split_on("/")
	Str.join_with(parts.take_first(parts.len() - 1), "/")
}

## ffmpeg: `$FFMPEG`, the one on PATH, or Nix's ffmpeg-headless (built once, then from the store).
find_ffmpeg! : {} => Try(Str, [Failed(Str)])
find_ffmpeg! = |{}|
	match Env.var!("FFMPEG") {
		Ok(given) => Ok(given)
		Err(NotFound) =>
			if runs(Cmd.new("ffmpeg").args(["-version"]).output!()) {
				Ok("ffmpeg")
			} else {
				built = Cmd.new("nix").args(["build", "nixpkgs#ffmpeg-headless", "--no-link", "--print-out-paths"]).output!()
				bin = match built {
					Ok({ code: 0, stdout, .. }) => stdout.split_on("\n").keep_if(|line| line.ends_with("-bin")).first() ?? ""
					_ => ""
				}
				if !bin.is_empty() and File.exists!("${bin}/bin/ffmpeg") {
					Ok("${bin}/bin/ffmpeg")
				} else {
					Err(Failed("rendering to a video file needs ffmpeg: set $FFMPEG, put it on PATH, or install Nix (it is fetched as nixpkgs#ffmpeg-headless)"))
				}
			}
	}

## Whether a command ran and ended well.
runs : Try({ code : I32, stdout : Str, stderr : Str }, [CantStart(Str)]) -> Bool
runs = |ran|
	match ran {
		Ok({ code: 0, .. }) => Bool.True
		_ => Bool.False
	}

expect Render.options(["http://localhost:8091/"]) == Ok({ url: "http://localhost:8091/", outputs: ["video.mp4"], player: "0", scale: "2", from: Err(None), to: Err(None), crf: "18" })
expect Render.options(["-o", "a.mp4", "http://x/", "-o", "frames/", "--from", "3", "--to", "9", "--player", "Launch", "--scale", "1"]).map_ok(|o| (o.outputs, o.from, o.to, o.player, o.scale)) == Ok((["a.mp4", "frames/"], Ok(3), Ok(9), "Launch", "1"))
expect Render.options(["http://x/", "--from", "soon"]) == Err(Usage("--from takes a whole number"))
expect Render.options(["--crf"]) == Err(Usage("--crf needs a value"))
expect Render.options([]).is_err()
expect frame_name(42) == "frame-00042.png"
expect output_args("a.gif", "18").is_err()
expect dirname("out/launch.mp4") == "out" and dirname("launch.mp4") == ""
expect scaled(1280, 2) == "2560"
