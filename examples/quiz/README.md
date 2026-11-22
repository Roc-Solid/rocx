# Pinwheel: a live quiz for a room full of phones

A whole Roc Solid app, small enough to read end to end. A host puts a room on a big screen; everyone
in the room joins on their phone with its four-letter code; each question shows on the big screen
with a clock while the phones show the choices; the quickest right answers score the most; after
each answer the leaderboard turns; after the last, the podium.

## A tour

1. **The front page** (`/`): join a game with its code and a name, or host one. The join form is
   checked as you type, and works without JavaScript too: it posts, and comes back with what was
   wrong.
2. **Host a game** (`/host`): the question sets, three seeded and any you made. *Open a room* makes
   a room with a fresh code (`BKRT`) and goes to its screen.
3. **The host's screen** (`/host/BKRT`), made for a projector: the code in huge letters, and who has
   joined (avatars, and names; one whose phone went is shown as dropped). *Start the game*.
4. **A question**: its number, a ring that empties as the clock runs (ticking out loud in the last
   five seconds), the prompt, the four choices in their colours, and how many have answered. It
   closes when the time is up, or as soon as everyone has answered, or when the host presses
   *Close it now*.
5. **The answer**: the right choice, how many took each (a bar chart whose bars rise), and the board:
   first as it stood, then each row gliding to its new place as the points land. The next question
   follows by itself (or *Go on now*).
6. **The podium**: the first three rising in turn, then everyone. *Play it again* keeps the room and
   its players, from nothing.
7. **A phone** (`/play/BKRT`): someone who hasn't joined gives a name; then the lobby, each question
   as four big buttons (a tap locks it in), *Right! +850* or *Not this time* after each, and where
   they finished. The page beeps when it should (a mute button is at the top).
8. **Make a set** (`/sets/new`): a title, a line about it, and the questions as plain text, a block
   each (`*` marks the right choice), checked as you type, shown beside as they will play. Saved,
   it is first on the host's page.

Product calls: no accounts (a random visitor id in a cookie says who hosts and who plays); anyone may
join until the podium (a latecomer starts from nothing); a right answer is worth 500 points and up
to 500 more for speed, a wrong one or none nothing; a question closes early once everyone in the
room has answered (one who dropped isn't waited for); the big screen is anyone's to watch, its
buttons only the host's.

## What it shows

| Feature | Where |
|---|---|
| One actor per room (D-021): the room's state, one message at a time; typed `ask!` and `tell!`; its own timers (`Actor.after!`, `Actor.cancel!`) closing each question and moving each reveal on | `Rooms.roc` (`kind`, `turn!`, `timed!`) |
| The rules as pure functions, the time given: joining, starting, picking, closing, advancing, the views | `Game.roc` (41 `expect`s that play games on a clock they choose) |
| Scoring as a pure, tested function; places with ties | `Score.roc` |
| A crash in a turn is logged and the room carries on as it was | the platform's rule (D-021): `Rooms.ask!` turns the asker's error into `Refused` |
| Channels (D-020): the room's view published after each turn that changes it; a check per subscriber (`channel!`), the room as it is now on each (re)connect (`on_open!`), what pages say (`receive!`: Start, Next, Again, a pick), and a tab that goes (`on_close!`) | `routes/rooms/[code]/+server.roc`, `Feed.rocx` (`Endpoint.subscribe!`, `Endpoint.say!`) |
| packages/presence: who is in the room as presence's `Room` (join, leave with a grace, sweep), kept in the actor's state; `<AvatarStack>` with a status of the app's own (`dropped`) | `Rooms.roc` (`tab_joined`, `present`), `Ui/Lobby.rocx` |
| Client timers kept honest: `set_interval!` counts down from the server's `left_ms`, `set_timeout!` marks the end, the interval stops itself with its `clear!`; both start again from each view | `Ui/Countdown.rocx` |
| `set_timeout!` for timing a reveal: the board's points landing, the bars rising | `Ui/Board.rocx`, `Ui/Tally.rocx` |
| `Audio.play!` with sounds made by a script (a mallet and a reed, synthesized) | `sounds.mjs` → `static/sounds/`, `Sound.roc`; played from effects and timers in the two room pages |
| Transitions: each phase a `<Show>` that flies, scales or fades in and out (`transition:in`, `transition:out`); names that grow into the lobby (`transition`); podium steps that grow up in turn (`Transition.grow(Bottom).delay(…)`) | `routes/host/[code]/+page.rocx`, `routes/play/[code]/+page.rocx`, `Ui/Lobby.rocx`, `Ui/Podium.rocx` |
| `transition:move`: the leaderboard's rows gliding to their new places | `Ui/Board.rocx` |
| packages/charts: how the room answered, as a `<BarChart>` | `Ui/Tally.rocx` |
| packages/forms: one schema for a page and its endpoint (`LiveForm`, `<TextField>`, `<IssueSummary>`), a custom parser in `try_map`, refusals at their fields, plain posts that come back with a flash | `Draft.roc` + `routes/sets/`, `Joining.roc` + `routes/+page.rocx`, `routes/join/+server.roc`, `routes/play/[code]/` |
| Postgres: migrations, idempotent seeds, a transaction | `migrations/`, `Sets.roc` |
| Configuration from the environment: the question's and the reveal's length | `Rooms.timing!` (`QUIZ_QUESTION_MS`, `QUIZ_REVEAL_MS`) |
| A middleware that hands every route the visitor (a cookie), and refuses other sites' posts | `Visitor.roc` |
| Pure `view` components (`Logo`, `Mark`, `Countdown.view`, `SoundSwitch`, `Masthead`) and effectful `view!` ones (`Board`, `Lobby`, `Podium`, `Tally`, the pages' `Asked`, `Revealed`, `Choosing`, `Playing`) | `Ui/`, the route files |
| A route file's own components, and its `<style>` for the whole file; scoped `<style>`s per component; tokens in one stylesheet | `routes/host/[code]/+page.rocx`, `Ui/*.rocx`, `static/pinwheel.css` |
| A big-screen layout (sizes from the viewport) and a phone one; `<Title>`; roles, labels, `aria-live` and `role="status"` | the two room pages |
| Stories (`<story>`) for the components | `Ui/*.rocx` (`rocx build --dev`) |

## Build and run it

You need the repository's toolchain (`just setup`) and a Postgres (`just db`). From the
repository's root, on port 18150:

```sh
export DATABASE_URL=postgres://rocx:rocx@127.0.0.1:55432/rocx   # what `just db` prints
bin/rocx build examples/quiz --client examples/quiz/build/client  # bin/rocx: any repo script builds it
.tools/roc-active build --target=wasm32 --opt=size \
  --output=examples/quiz/build/client/static/rocx/app.wasm examples/quiz/build/client/main.roc
node server/build.mjs examples/quiz/main.roc examples/quiz/build/quiz
examples/quiz/build/quiz --port 18150 --database-url "$DATABASE_URL" \
  --static examples/quiz/build/client/static --static examples/quiz/static
```

Then http://localhost:18150. The server runs the migrations (and the seeds) as it starts. Open a
room, and join it from another browser (or a private window: a browser is one visitor). A question
is open for 20 s and its answer shown for 7 s; `QUIZ_QUESTION_MS=8000 QUIZ_REVEAL_MS=3000` before
the last command changes that. `node examples/quiz/sounds.mjs` makes the sounds again.

## Test it

```sh
export DATABASE_URL=…                                          # a Postgres; each test makes its own database
bin/rocx fmt --check examples/quiz
bin/rocx check -- .tools/roc-active test examples/quiz/main.roc   # the expects: rules, scoring, components
node --test 'examples/quiz/test/*.test.mjs'                    # over HTTP and channels, and in Chromium
```

- **`expect`s** (about a hundred of the app's own): `Game.roc` plays games with a clock it chooses
  (joining, starting, picking once and in time, closing early when everyone is in, the reveal's
  tallies and points, advancing, Next, Again, versions, deadlines); `Score.roc` the points and the
  places; `Codes.roc`, `Draft.roc` (the editor's text, both ways) and `Joining.roc` the forms; and
  the components' helpers.
- **`test/game.test.mjs`** builds the app, starts it on a database of its own with a 4 s question,
  and plays it as the pages do: a whole game with a host and three players over the room's channel,
  each question's tallies and points checked and the final scores against them; a question nobody
  answers closing on the room's own timer; presence (a phone that goes shows as dropped, and comes
  back); the join forms' refusals at their fields and a plain post's flash; the editor; seeding run
  twice; the pages as the server renders them.
- **`test/browser.test.mjs`**, in Chromium (skipped without it), hydrating strictly: joining by code
  from the front page, the lobby, answering the first question with a tap, the reveal; then the
  host's screen as the host (its buttons, said on the channel from the page) and as anyone else (no
  buttons), and the podium with the room's final scores.

## What it asked of the platform

Each gap this app met, and what it does about it:

- **An actor can't name its channel through `Generated/Api`.** The channel's route file imports
  `Rooms` (to ask the actor), and `Generated/Api` imports the route file, so `Rooms` importing `Api`
  would be an import cycle, which Roc refuses. `Rooms.channel` names the channel by its URL instead
  (`Endpoint.remote("CHANNEL", "/rooms/${code}")`), which is all `Endpoint.publish!` reads. A typed
  name for a channel that a module below the routes could import would remove the duplication.
  (Fixed in the platform since: `Generated/Api` is the app's contract and imports no route file
  (D-037), so `Rooms` imports it and publishes on `Api.channel_rooms_code({ code })`, typed.)
- **An endpoint's answer has no type in the browser's copy.** The host's screen read
  `Endpoint.get!(Api.get_rooms_code(…))` and compared `seat.who == Host`; in the browser that made
  `who`'s type `[Host]`, so a watcher's `"Watcher"` failed to parse ("Invalid JSON"), and only in the
  browser, so the page hydrated into the error page. Both room pages say the type (`seat : Game.Seat`).
  The platform does document it (for `use_submissions!`); a reported type at the read, or the same
  types in both copies, would catch it at build. (Fixed in the platform since: the browser's copy of
  `Api` has the same types as the server's, copied from each handler's annotation (D-037), so the
  pages say no type. The host's list's sets, `Sets.Summary`, became `Draft.Summary`: `Sets` imports
  `Db`, which the browser's copy can't compile, and `rocx build` said so at the route.)
- **A value prop inside a `<Show>`'s children was read when the page first rendered**, not when the
  part showed: the podium, written `<Podium players={current!().players} />` inside the finished
  phase's `<Show>`, showed every score as it was in the lobby. The workaround was an accessor
  (`players!`). (Fixed in the platform since, twice over: what a `<Show>` shows is made as it shows,
  as Solid makes it, and a value prop is a getter, as Solid's are (D-039), read where the component
  reads it, so the podium follows the scores while it shows. `Podium`, `Lobby` and `Board` take
  plain props again (`players`, `rows`), and the browser test checks a score made after the page
  rendered.)
- **`<For>` and `<Show>` can't sit inside a pure function child** (a `<For>` row's, a `<Show>`'s
  narrowed child): the platform's components are effectful calls, and those children are pure, so
  the compiler says "This function is effectful, but a pure function is expected" about generated
  code. Each such part is a small `view!` component of its own (`Asked`, `Revealed`, `Choosing`,
  `Preview`), which the child renders. (Fixed in the platform since: a function child is effectful
  now, so it may hold a `<For>` or a `<Show>`; the components stay, as they read well.)
- **A route file's components don't see the route file's own definitions**: helpers they use are
  defined in their own block (`Asked.answered`, `Revealed.taken`). (Fixed in rocx since: a route
  file's components see its definitions, as its page does; the helpers stay, as they read well.)
- **The browser has no clock.** The countdown counts down from the server's `left_ms` with
  `set_interval!` and starts again from each view, so a drifting or sleeping phone is put right by
  the next view; the server alone decides when a question closes (presence's PROPOSALS.md, W2).
- **Channel hooks weren't told which stream** a subscription was on. A tab whose stream reconnected
  (the same tab id) could be told `on_open!` for the new stream before `on_close!` for the old one,
  so the room counted each tab's open streams and left presence only at zero. (Fixed in the platform
  since: a tab has one stream, and a new one ends the old first, so a tab's hooks come in order; the
  room joins and leaves a tab as it is told.)
- **packages/presence's server glue was events, not channels.** The app uses presence's `Room`
  (the logic) inside its own actor, fed by the room's channel's hooks, and its `<AvatarStack>`; the
  channel's beat check (`x-rocx-channel: check`, with `x-rocx-tab`) is the heartbeat. (Presence
  runs on channels since, its hooks `PresenceServer`'s; the room stays the actor's, as who is here
  is part of the game.)
- **A record's function field is called with parentheses**: `(room.say!)(Start)`, not
  `room.say!(Start)`, which Roc reads as a method call.
- **Roc can't build a form of one field with the record builder** ("single-field record builder"):
  `Joining.named` is `Joining.name.map(|typed| { name: typed })`.
- **A compiler warning fails the test build**: `buildForTests` treats `roc build`'s exit code 2 (a
  warning: a shadowed name) as a failure. The code has no warnings.
- **`node --test examples/quiz/test/` doesn't run on Node 24**, which takes a directory as a module
  to load; the glob (`'examples/quiz/test/*.test.mjs'`) does.
- **Fixed: checking transitions in a Firefox-based browser headlessly was limited.** Driven over
  WebDriver BiDi (a scratch script, then), Zen ran every animation the runtime starts (each phase's
  in and out, the board's glides, with their keyframes and lengths), but a headless window's
  document was hidden and its animation timeline barely moved (raising `layout.throttled_frame_rate`
  helped a little), so its screenshots showed first frames. Headless Chromium doesn't play them
  either. packages/testing now launches Gecko (`launchBrowser({ engine: "gecko" })`), and each tab
  it goes to is the shown one (BiDi's `browsingContext.activate`): its document is visible, and its
  transitions run in real time, sixty frames a second.
