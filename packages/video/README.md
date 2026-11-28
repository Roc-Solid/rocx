# video

Videos made of an app's own components, as Remotion makes them of React's. A **composition** is a
component that reads the frame it is at and renders what that moment looks like. `<Player>` plays
it live in a page, and `rocx render` films it a frame at a time into an MP4 or a WebM. The same code
is the landing page's animation and the file you post, and it follows your components: when a
component changes, so does its video, the next time it plays or is rendered.

The user guide, with a live demo, is the docs site's
[Video page](https://roc-solid.github.io/ecosystem/video); this file is the reference.

Nothing in it needs the host, so it is a package rather than part of the platform. It isn't a
plugin either: it adds nothing to the server.

- `Timeline` (plain Roc, on no platform): where a frame is along a span, eased, sprung or through
  keyframes, and what a number or a text is there.
- `<Player>` and `<Sequence>`, in `components/`: the clock and its stretches.
- `rocx render` (in rocx, on packages/headless) and `clock.js`, the clock it runs in the page: the
  renderer, with Chromium's headless shell and ffmpeg.
- The stories' catalog plays every player it shows from one transport, so videos side by side play
  in step (see [Stories](#stories)).

## Installing it

Name the package in the app's header:

```roc
app [program] { pf: platform "…/server/platform/main.roc", video: "…/packages/video/main.roc" }
```

Then import what you use in a `.rocx` file:

```roc
import video.Player
import video.Sequence
import video.Timeline
```

`rocx generate` (which `rocx dev` and `rocx build` run first) copies `components/Player.rocx` and
`components/Sequence.rocx` into each app that names the package (`Generated/video/`). They need the
server's `Html` on the server and the browser's in the browser, so they are compiled as part of the
app.

## A composition

A scene reads its clock with `Player.clock!` in its body, and the frame in its holes and memos:

```rocx
import pf.Html
import pf.Solid exposing [create_memo!]
import video.Player
import video.Timeline

## The name springs up into place, and is typed as it does.
LaunchTitle := [].{
	view! : {} => Html
	view! = |{}| {
		{ frame!, fps, .. } = Player.clock!({})
		rise! = create_memo!(|| Timeline.spring(frame!(), fps))
		<h1 style:transform={"translateY(${((1.0 - rise!()) * 48.0).to_str()}px)"}>
			{Timeline.typed("Acme Rockets", Timeline.progress(frame!(), 4, 28))}
		</h1>
	}
}
```

A composition puts scenes on its timeline with `<Sequence>`, and a page plays it with `<Player>`:

```rocx
<Player frames={120} label="Acme's launch">
	<div class="launch">
		<Sequence frames={80}><LaunchTitle /></Sequence>
		<Sequence from={40}><LaunchCount /></Sequence>
	</div>
</Player>
```

`packages/video/example` is that app: a page with the video and a bar to scrub it, its stories, and
tests that play, seek and render it.

Four things to keep in mind:

- **Read the frame where it is tracked.** `frame!()` in a hole, a computed attribute or a memo runs
  again each frame; in the component's body it is read once.
- **Give a pure component a memo, not the frame.** A pure component is made again each time what
  its props read changes. Given `frame!()`, that is every frame. Given a memo
  (`ticked! = create_memo!(|| frame!() >= 14)`, then `checked={ticked!()}`), it is made once per
  change, since a memo computed again to the same value tells no one (D-109). Its own CSS
  transitions then play.
- **A computed style doesn't multiply.** The platform lets a style's value hold letters, digits,
  spaces and `.,%#()-+` (`safe_css`), so `calc(… * …)` and `a / b` are dropped. Give the numbers
  as custom properties (`style:--row={row!().to_str()}`) and do the arithmetic in the stylesheet
  (`transform: translateY(calc(var(--row) * (100% + 8px)))`).
- **Write motion from the frame.** Everything a frame shows is worked out from the frame, so a
  frame looks the same played, scrubbed to, or rendered. The components' own CSS transitions and
  the platform's `transition` directives play too: in a page in real time, and in a render by the
  renderer's clock (see [Rendering](#rendering)).

## `<Player>`

| Prop | Type | What it is |
|---|---|---|
| `frames` | `U64` | How long it is, in frames. |
| `fps` | `U64 ?? 30` | Frames a second (0 is taken as 30). |
| `width`, `height` | `U64 ?? 1280`, `U64 ?? 720` | The video's size, in CSS pixels: what a render films (with `Flow`), or the stage's size (with `Scale`). |
| `fit` | `[Flow, Scale] ?? Flow` | `Flow`: the composition is laid out as any markup, at the player's width. `Scale`: it is laid out at `width` by `height` and scaled to the player's width (`on:viewport` measures it), as a video is. |
| `autoplay` | `Bool ?? Bool.True` | Plays from the start on its first animation frame. |
| `loop` | `Bool ?? Bool.True` | Plays again from the start when it ends; without, it stops on its last frame. |
| `poster` | `[Start, End, Frame(U64)] ?? End` | The frame the server renders, and the browser as it hydrates, and what shows where nothing plays it. |
| `controls` | `[Corner, Bar, Hidden] ?? Corner` | A play and pause button in its corner; a bar with the button, a scrubber and the time; or nothing to see. Anything that moves by itself for more than five seconds needs a way to pause it (WCAG 2.2.2): keep `Corner` on a page. |
| `label` | `Str ?? ""` | The player's `aria-label` (`role="group"`, `aria-roledescription="video"`). |
| `class` | `Str ?? ""` | Classes added to `video`. |
| children | markup | The composition. |

What a composition reads, from `Player.clock!({})` (`Player.Clock`):

| Field | Type | What it is |
|---|---|---|
| `frame!` | `() => U64` | The frame shown, from 0: a getter that tracks. Inside a `<Sequence>`, its frames from its start. |
| `fps` | `U64` | Frames a second. |
| `frames` | `U64` | How many frames in all (inside a `<Sequence>`, in it). |

Its element says where it is, for whatever drives it from outside (the catalog, the renderer, a
test): `data-rocx-video`, `data-frame`, `data-playing` (`yes`/`no`), `data-live` (`yes` from its
first animation frame: the page is live), `data-fps`, `data-frames`, `data-width` and
`data-height`. Every player has a scrubber, `input.video-seek` (shown with `Bar`, hidden
otherwise): set its value to a frame and dispatch `input`, and the player goes there and pauses.

How it plays: the server renders the poster frame, and the browser hydrates the same. On its first
animation frame (`on:frame.ms` on its stage) it is live, and with `autoplay` it goes to frame 0 and
plays: each animation frame adds its milliseconds, and the frame is the time times `fps`, rounded
down. A tab that comes back after a while goes on where it was (the platform gives at most 100 ms a
frame).

The CSS custom property `--video-accent` colours the scrubber.

## `<Sequence>`

| Prop | Type | What it is |
|---|---|---|
| `from` | `U64 ?? 0` | The frame its stretch starts at. |
| `frames` | `U64 ?? 0` | How long its stretch is; 0 is to the end. |
| `hold` | `Bool ?? Bool.False` | Shows what is inside before its stretch (at its first frame) and after (at its last), instead of only during it: three steps side by side, each waiting its turn and staying done. |
| children | markup | What plays in the stretch, reading its clock (`frame!` from 0 at `from`). |

Without `hold`, what is inside is made as its stretch starts and goes as it ends (an `if`), so its
`transition:in` and `transition:out` play there. Sequences nest.

## `Timeline`

| Function | What it gives |
|---|---|
| `progress(frame, from, to)` | How far `frame` is along the span: 0 at `from` and before, 1 at `to` and after. |
| `ease(share, easing)` | A share eased: `Linear`, `In`, `Out`, `InOut` (cubic), `Back` (past the goal and back). |
| `eased(frame, from, to, easing)` | `progress`, eased. |
| `mix(a, b, share)` | The value `share` of the way from `a` to `b`. |
| `tween(frame, from, to, a, b, easing)` | A value going from `a` to `b` over the span. |
| `keys(frame, [(frame, value), …])` | A value through keyframes, steadily from each to the next; held before the first and after the last. |
| `keys_with(frame, points, easing)` | The same, each move eased: a pointer that glides from place to place and rests at each. |
| `spring(frame, fps)` | A spring let go at frame 0, from 0 toward 1: past 1 a little, settled in about a second (stiffness 100, damping 10, mass 1). |
| `spring_with(frame, fps, { stiffness, damping, mass })` | Another spring. |
| `since(frame, start)` | The frames since `start`, 0 before it: `spring(since(frame, 30), fps)`. |
| `frames_of(seconds, fps)` | Seconds in whole frames. |
| `round(value)`, `whole_u64(value)` | A count as it climbs. |
| `typed(text, share)` | The first share of a text's characters: typed, a character at a time. |

Every function gives the same answer for the same frame.

## Rendering

```sh
rocx render http://localhost:8091/ -o launch.mp4 -o launch.webm
rocx render http://localhost:8091/__rocx/stories/Launch/a-bar-to-scrub -o frames/
```

`rocx render` opens the page in Chromium's headless shell, driven from Roc by packages/headless
(D-128). It takes the page's clock over before the page's own scripts run (`clock.js`), lets it load
and hydrate in real time, then freezes the clock and films each frame in turn:

1. the clock moves on a frame: each timer due runs at its time, then each animation frame asked
   for;
2. the player is sought to the frame (its scrubber);
3. the page settles: a few turns of its tasks, its fonts and images;
4. every animation is put where the clock says (`document.getAnimations()`: the platform's
   transitions, CSS transitions and animations, `element.animate`), held still that far in since
   it was first seen, or finished once past its end. The first frame filmed is at rest: what its
   seek started (a transition away from the poster frame) is finished first, so a render from
   frame 0, or from `--from`, doesn't open on the poster fading out;
5. the player's stage is photographed, its controls hidden, at `--scale` device pixels a CSS pixel.

A path ending in `/` gets a PNG a frame (`frame-00000.png`, numbered from the video's start). For
the video files the photographs wait in a temporary folder, and once the last is taken one ffmpeg
writes each file: `.mp4` in H.264 and `.webm` in VP9, both 4:2:0 and their size made even. A frame
doesn't depend on how long it took to film, so two renders of one composition are the same, frame
for frame (the example's test renders twice and compares).

| Option | What it does |
|---|---|
| `-o <path>`, `--out <path>` | A file to write, again for more: `.mp4`, `.webm`, or a folder ending in `/` (`video.mp4` when none). |
| `--player <n\|label>` | The page's player to film: its index from 0, or its `aria-label`. The first unless it says. |
| `--scale <n>` | Device pixels a CSS pixel (2): a 1280 by 720 player filmed at 2560 by 1440. |
| `--from <frame>`, `--to <frame>` | A stretch of it (the last frame in it). |
| `--crf <n>` | H.264's quality (18; lower is better and bigger). |

Chromium is `$CHROME`, else Playwright's newest headless shell, as the tests find it. ffmpeg is
`$FFMPEG`, else the `ffmpeg` on PATH, else Nix's (`nix build nixpkgs#ffmpeg-headless`, fetched
once). A page that throws while it is filmed has its errors said at the end. `rocx help render`
lists the options.

## Stories

A video is a story whose markup has a `<Player>`; nothing else marks it. The catalog
(`/__rocx/stories`, under `rocx dev`) shows a transport above the stage whenever a story it shows
has a live player:

- play and pause (Space), a frame back and on (← and →, a second with Shift), the start (Home), a
  scrubber in time, the time and frame, a speed (¼× to 2×), and looping;
- one clock for every player shown: a component's stories side by side, or stories compared, play
  in step, each sought to its frame at the same time (a shorter one keeps its last frame until the
  longest ends);
- **Render** copies the command that films each story shown into an MP4 and a WebM named after it
  (`rocx render <url> -o <story>.mp4 -o <story>.webm`), when the app names this package.

Comparing works for any stories, videos or not: the pin beside a story in the side (or P) picks it,
and "Compare N side by side" (or C) opens the picked ones together, from any component.

## Not yet

- **Reduced motion.** A player plays whatever `prefers-reduced-motion` says: nothing in Roc can
  read a media query yet. Its corner button pauses it. The smallest platform change is a read of
  the runtime's `reducedMotion()` (one host function); then a player would rest on its poster.
- **Playing when seen.** A player starts as the page goes live, not as it scrolls into view; one
  further down plays its loop meanwhile. An event for an element coming into view would start it
  there.
- **Scripted input.** A demo is driven by its props from the frame (a pointer drawn moving, a box
  ticked at a frame), not by real clicks dispatched at frames.
- **Encoding as it films.** `rocx render` hands the frames to ffmpeg after the last is taken: the
  CLI platform can't write to a child's stdin yet.
- **Audio.** Videos are silent; ffmpeg could mix a track in.
- **Rendering on the server** with an app's data (a video per post): a plugin with Chromium and
  ffmpeg beside the server.
