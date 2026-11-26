# Pinwheel: a live quiz for a room full of phones

A whole Roc Solid app, small enough to read end to end. A host puts a room on a big screen, and
everyone in the room joins on their phone with its four-letter code. Each question shows on the big
screen with a clock while the phones show the choices. The quickest right answers score the most.
After each answer the leaderboard turns, and after the last question comes the podium.

Read it to learn how a Roc Solid app keeps shared state in an actor (one per room, with its own
timers), pushes it to every screen over a channel, shows who is here with presence, and animates
each phase with transitions. It also uses four packages: forms, charts, presence and audio.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/quiz && ../../bin/rocx dev
```

Open http://localhost:8080. `rocx dev` builds the app (the server and the browser's half), serves it
under `--dev` along with the app's `static/` (the sounds and the stylesheet), and builds it again
each time you save a file.

Run it from the example's directory. The question sets are in SQLite:
`database: Sqlite("data/quiz.db")` in `main.roc` is a path relative to where the server starts, so
the file is `examples/quiz/data/quiz.db` (`*.db` is gitignored). The server makes the file and runs the
migrations and seeds as it starts.

Open a room, then join it from another browser or a private window. The tabs of one browser share
their cookie, so they are one visitor.

A question is open for 20 seconds and its answer shows for 7. To change that, set
`QUIZ_QUESTION_MS` and `QUIZ_REVEAL_MS`: `QUIZ_QUESTION_MS=8000 QUIZ_REVEAL_MS=3000 ../../bin/rocx dev`.
`node sounds.mjs` makes the sounds again.

Under `rocx dev`, the components' stories are at http://localhost:8080/__rocx/stories.

### Build it as it would ship

`rocx dev` builds for development. To build the browser's wasm at its smallest and run the server on
its own, from the repository's root (`just web-host` first, if the browser's host isn't built yet):

```sh
bin/rocx build examples/quiz --client examples/quiz/build/client
.tools/roc-active build --target=wasm32 --opt=size \
  --output=examples/quiz/build/client/static/rocx/app.wasm examples/quiz/build/client/main.roc
node server/build.mjs examples/quiz/main.roc examples/quiz/build/quiz
cd examples/quiz && build/quiz --port 18150 --static build/client/static --static static
```

Then open http://localhost:18150.

## A tour

1. **The front page** (`/`): join a game with its code and a name, or host one. The join form is
   checked as you type. It works without JavaScript too: it posts, and comes back with what was
   wrong.
2. **Host a game** (`/host`): the question sets, three seeded and any you made. *Open a room* makes
   a room with a fresh code (say `BKRT`) and goes to its screen.
3. **The host's screen** (`/host/BKRT`), made for a projector: the code in huge letters, and who has
   joined (avatars and names; someone whose phone went away shows as dropped). *Start the game*.
4. **A question**: its number, a ring that empties as the clock runs (ticking out loud in the last
   five seconds), the prompt, the four choices in their colours, and how many have answered. It
   closes when the time is up, as soon as everyone has answered, or when the host presses
   *Close it now*.
5. **The answer**: the right choice, how many picked each (a bar chart whose bars rise), and the
   leaderboard: first as it stood, then each row gliding to its new place as the points land. The
   next question follows by itself, or at once with *Go on now*.
6. **The podium**: the first three rising in turn, then everyone. *Play it again* keeps the room and
   its players and starts the scores from zero.
7. **A phone** (`/play/BKRT`): someone who hasn't joined gives a name. Then the lobby, each question
   as four big buttons (a tap locks the answer in), *Right! +850* or *Not this time* after each, and
   where they finished. The page plays sounds when it should; a mute button is at the top.
8. **Make a set** (`/sets/new`): a title, a line about it, and the questions as plain text, one
   block each (`*` marks the right choice). It is checked as you type and previewed beside, as it
   will play. Saved, it is first on the host's page.

## What it shows

| Feature | Where to look |
|---|---|
| One actor per room, keyed by the room's code. `Rooms` is the actor's kind (its `name` and `initial` state); its ten methods each have their own reply, and are asked or told by name (`Rooms.join.ask!`, `Rooms.beat.tell!`). It takes one turn at a time, so two answers at once, the clock running out and the host pressing Next never trip over each other | `Rooms.roc` |
| An actor's own timers: closing each question and moving each reveal on (`me.after!`, `Actor.cancel!`) | `Rooms.timed!` |
| A crash in a turn: the platform logs it and the room keeps its state; the asker gets `ActorErr(why)`, which the channel answers as a 409 and a read as a vacant room | `routes/rooms/[code]/+server.roc` (`receive!`), `Rooms.look!` |
| The rules as pure functions, given the time: joining, starting, picking, closing, advancing, the views | `Game.roc` (41 `expect`s that play games on a clock they choose) |
| Scoring as a pure, tested function; places with ties | `Score.roc` |
| A channel per room: the room's view published after each turn that changes it; a check for each subscriber (`channel!`); the room as it is now on each connect (`on_open!`); what pages say (`receive!`: Start, Next, Again, a pick); a tab that goes (`on_close!`) | `routes/rooms/[code]/+server.roc`, `Rooms.turned!` |
| Following a room from a page: subscribe from an effect, keep the newest view, say things on the channel (`Endpoint.subscribe!`, `Endpoint.say!`) | `Feed.rocx` |
| Presence (packages/presence): who is in the room, kept in the actor's state as presence's `Room` (join, leave after a grace period, sweep), and `<AvatarStack>`, a player who dropped greyed (`Offline`) | `Rooms.roc` (`tab_joined`, `present`), `Ui/Lobby.rocx` |
| A countdown kept honest: each view sets a deadline by the phone's clock (`Time.now_millis!`); `set_interval!` shows what is left and stops itself at zero with its `clear!`; the effect's next run stops the old interval | `Ui/Countdown.rocx` |
| `set_timeout!` to time a reveal: the leaderboard's points landing, the bars rising | `Ui/Board.rocx`, `Ui/Tally.rocx` |
| Sounds through a plugin: `Audio.play!` (packages/audio, `AudioPlayer.plugin({})` in `main.roc`), with sounds made by a script (a mallet and a reed, synthesized) | `sounds.mjs` → `static/sounds/`, `Sound.roc`; played from effects and timers in the two room pages |
| Transitions: each phase is its own `if` or `match` part that flies, scales or fades in and out (`transition:in`, `transition:out`); names that grow into the lobby (`transition`); podium steps that grow up in turn (`Transition.grow(Bottom).delay(…)`) | `routes/host/[code]/+page.rocx`, `routes/play/[code]/+page.rocx`, `Ui/Lobby.rocx`, `Ui/Podium.rocx` |
| `transition:move`: the leaderboard's rows gliding to their new places | `Ui/Board.rocx` |
| Charts (packages/charts): how the room answered, as a `<BarChart>` | `Ui/Tally.rocx` |
| Forms (packages/forms): one schema for a page and its endpoint (`LiveForm`, `<TextField>`, `<IssueSummary>`); the endpoint names it as its body's rules (`post_body = Joining.form`, D-093), so what doesn't pass, as a form or as JSON, is refused with its issues before the handler runs; a custom parser in `try_map`, refusals shown at their fields, plain posts that come back with a flash | `Draft.roc` + `routes/sets/`, `Joining.roc` + `routes/+page.rocx` + `routes/join/+server.roc`, `routes/play/[code]/` |
| SQLite in the server's process: migrations, seeds that can run twice, a transaction, a `json` column | `main.roc`, `migrations/`, `Sets.roc` |
| Configuration from the environment: how long a question and a reveal last | `Rooms.timing!` (`QUIZ_QUESTION_MS`, `QUIZ_REVEAL_MS`) |
| Middleware that refuses other sites' posts and hands every route the visitor (from a cookie) | `Visitor.roc` |
| Pure `view` components (`Logo`, `Mark`, `Countdown.view`, `SoundSwitch`, `Masthead`) and effectful `view!` ones (`Board`, `Lobby`, `Podium`, `Tally`, and the pages' `Asked`, `Revealed`, `Choosing`, `Playing`) | `Ui/`, the route files |
| A route file's own components, and a `<style>` for the whole file; scoped `<style>`s per component; colour tokens in one stylesheet | `routes/host/[code]/+page.rocx`, `Ui/*.rocx`, `static/pinwheel.css` |
| A big-screen layout (sizes from the viewport) and a phone one; `<Title>`; roles, labels, `aria-live` and `role="status"` | the two room pages |
| Stories (`<story>`) for the components, at `/__rocx/stories` in a dev build | `Ui/*.rocx` |

## How a room works

`Rooms.roc` is the room's actor. The rules are `Game.roc`'s, pure functions given the time; the
actor only decides when to apply them. Every method's turn goes through `Rooms.turned!`:

1. Presence is swept first, so a tab whose grace period ran out is gone before anything else is
   decided.
2. The method does its work: the room after it, and the reply.
3. If the phase changed, the timer the old phase had is cancelled and one is set for the new phase's
   deadline (`me.after!`). When it fires, it calls `close` or `advance` like any other caller.
4. If the room changed, the room's view is published on its channel (`Api.channel_rooms_code`),
   which every host's screen and every phone follows.

Who is here lives in the actor's state too, as packages/presence's `Room`: each tab that subscribes
to the channel joins (`opened`), each one that goes leaves (`closed`), and the channel's beats keep
tabs fresh (`beat`). The app doesn't use presence's ready-made channel hooks (`PresenceServer`),
because who is here is part of the game: a question closes early once everyone still in the room
has answered.

On the page, `Feed.follow!` starts from the view the server rendered with (`GET /rooms/:code`), then
subscribes from an effect. On each connect and reconnect, the channel's `on_open!` sends the room as
it is now, so a phone that slept catches up at once. Views carry a version, and a view older than
the one shown is ignored.

## Product calls

- No accounts. A random visitor id in a cookie says who hosts and who plays.
- Anyone may join until the podium. A latecomer starts from nothing.
- A right answer is worth 500 points, and up to 500 more for speed. A wrong answer, or none, is
  worth nothing.
- A question closes early once everyone in the room has answered. A player who dropped isn't waited
  for.
- The server alone decides when a question closes. A phone counts down by its own clock from what
  the server said is left, and stops taking answers at zero.
- Anyone may watch the big screen; only the host sees its buttons.

## Test it

From the repository's root:

```sh
just examples quiz
```

That builds the app, type-checks both programs, lints it, checks its SQL against SQLite
(`rocx check --sql`), runs the `expect`s and the node tests. To run the parts yourself:

```sh
bin/rocx fmt --check examples/quiz
bin/rocx check examples/quiz   # build it, type-check both programs; problems at their .rocx lines
bin/rocx check -- .tools/roc-active test examples/quiz/main.roc   # the expects: rules, scoring, components
node --test 'examples/quiz/test/*.test.mjs'                      # over HTTP and channels, and in Chromium; a SQLite file each
```

- **`expect`s** (about a hundred): `Game.roc` plays games on a clock it chooses (joining, starting,
  picking once and in time, closing early when everyone has answered, the reveal's tallies and
  points, advancing, Next, Again, versions, deadlines); `Score.roc` checks the points and the
  places; `Codes.roc`, `Draft.roc` (the editor's text, both ways) and `Joining.roc` check the forms;
  and the components check their helpers.
- **`test/game.test.mjs`** builds the app, starts it on a SQLite file of its own with a 4-second
  question, and plays it as the pages do: a whole game with a host and three players over the
  room's channel, each question's tallies and points checked, and the final scores; a question
  nobody answers, closed by the room's own timer; presence (a phone that goes shows as dropped, and
  comes back); the join forms' refusals at their fields (sent as JSON too) and a plain post's flash;
  the editor; seeding run twice; the pages as the server renders them.
- **`test/browser.test.mjs`**, in Chromium (skipped without it), hydrating strictly: joining by code
  from the front page, the lobby, answering the first question with a tap, the reveal; then the
  host's screen as the host (its buttons, said on the channel from the page) and as anyone else (no
  buttons); and the podium with the room's final scores.

## What it asked of the platform

Pinwheel met several gaps while it was built. All are fixed in the platform or in rocx now, and the
app uses the fixes:

- A module below the routes can publish on a route's channel: `Rooms` imports `Generated/Api` and
  publishes on `Api.channel_rooms_code`, typed. `Generated/Api` is the app's contract and imports
  no route file, so there is no import cycle (D-037 in DECISIONS.md).
- The browser's copy of `Generated/Api` has the same types as the server's, so the pages don't
  write an endpoint's answer type by hand.
- A component's value props are getters, read where the component reads them, so `Podium`,
  `Lobby` and `Board` take plain props (`players`, `rows`) and follow the scores while they show.
- A route file's components see the route file's own definitions.
- The browser has a clock (`Time.now_millis!`), so the countdown keeps a deadline instead of
  counting ticks, and a phone whose timers stalled shows the right time on its next tick.
- A tab has one channel stream, and a new one ends the old one first, so a tab's `on_open!` and
  `on_close!` come in order and the room can join and leave a tab as it is told.

Still worth knowing:

- **A record's function field is called with parentheses**: `(room.say!)(Start)`, not
  `room.say!(Start)`, which Roc reads as a method call.
- **Roc can't build a form of one field with the record builder** ("single-field record builder"),
  so `Joining.named` is `Joining.name.map(|typed| { name: typed })`.
- **A compiler warning fails the test build**: packages/testing's `buildForTests` treats a warning
  (`roc build`'s exit code 2, a shadowed name, say) as a failure. The app's code has none.
- **`node --test examples/quiz/test/` doesn't run on Node 24**, which loads a directory as a
  module. The glob, `'examples/quiz/test/*.test.mjs'`, works.
