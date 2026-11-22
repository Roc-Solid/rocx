# Reactive value props (D-039): design

Status: **Built** 2026-11-22 (D-039 in `DECISIONS.md`). "As built", at the end, says where the build differs from this design. The spikes in `specialize/` are throwaway
apps on the web platform, kept because the numbers below come from them.

## In short

A component's value prop becomes what it is in Solid: a getter. `<Child label={word!()} />` passes
`label: || word!()`. Inside the child, rocx rewrites each read of `label` into a call of that getter,
at the place the read is written:

- in a hole, a memo, an effect or a handler, the read runs there: tracked by the hole, memo or
  effect, so only that part is patched, and current in a handler;
- in the component's body, it runs once, untracked, as the component runs.

The child is made once, and its signals keep their state. Its author writes nothing new:
`view! = |{ label }| <p>{label}</p>` stays as it is, and so does `label : Str` in its type. rocx
writes `label : () => Str` and `|{ label: label! }|` in the generated code.

`label!={…}` accessors keep working unchanged. `Html.component_with`, which read the props where the
call was written, goes.

Two runtime changes come with it, as Solid has them:

- A `<For>`'s rows and a `<Show>`'s function child run untracked. They are made once and kept, like
  a component, because the props inside them no longer need the row made anew.
- A pure `view` component given a value read from what changes becomes a hole of its own. It is
  rendered anew when that value changes, where today it is read once and never changes.

## Where things stand

- `web/README.md` (Props): a value prop has Roc's type, so it can't be a getter.
  `Html.component_with(|| { label: word!() }, Shows.view!)` reads the props before the child runs.
  - Inside a hole, the hole runs again when a prop changes, and the child is made anew (its signals
    with it).
  - Outside a hole, the props are read once.
- `examples/board`: the "Ada has this card open" label of `<AvatarStack>` sat inside a `<Show>`. It
  was made once, empty. Workaround: the stack is rendered in a hole (`CardTile.viewing`) and made
  anew when the viewers change.
- `examples/quiz`: `<Podium players={current!().players} />` inside the finished phase's `<Show>`
  showed the lobby's scores. Workaround: an accessor prop, `players!`.
- `site/Demos/Planner.rocx`: `<PlannerDay day={day!()} />` in a `<For>` row works only because rows
  are tracked: a change of `day!()` makes the row, and the day, anew.

## The semantics, beside Solid 2.0's

| Solid 2.0 | Roc Solid with D-039 |
|---|---|
| `<Child label={word()} />` compiles to `{ get label() { return word() } }` | `<Child label={word!()} />` is `Child.view!({ label: \|\| word!() })` |
| A component runs once, untracked | Unchanged |
| `<p>{props.label}</p>`: the insert tracks the getter and patches the text | `<p>{label}</p>` is `Html.text_of(\|\| label!())`: tracked, patched |
| `createMemo(() => props.label.length)`: tracked | `create_memo!(\|\| label.len())` is `create_memo!(\|\| label!().len())`: tracked |
| `createEffect(() => props.room, (room) => …)` | `create_effect!(\|\| room, \|r\| …)`: the compute reads `room!()`, tracked |
| `onClick={() => send(props.label)}`: the current value | `on:click={\|\| send!(label)}`: the current value |
| `const first = props.label` in the body: one read, untracked (Solid 2.0 warns in dev) | `first = label` in the body: one read, untracked (no warning; see open question 3) |
| Destructuring `({ label })` in the parameters loses reactivity (Solid 2.0 warns) | `\|{ label }\|` is the only way Roc names props, so rocx gives it `props.label`'s meaning (below) |
| `items.filter((i) => i.owner === props.me)` inside an insert: read when the filter runs, tracked by the insert | `{…items.keep_if(\|i\| i.owner == me)…}`: read when that pure function is made, in the same hole, tracked by it |
| `const fmt = (x) => x + props.unit` in the body: reads the current value | `fmt = \|x\| …unit…` in the body: the value when the component ran (a difference); `fmt! = \|x\| …` reads the current one |
| `props.children` is a getter | `children` stays a value: markup whose holes are already live |
| `merge` / `omit` (Solid 2.0's `mergeProps` / `splitProps`) | Defaults stay `??` in a `Props := {…}` type; no `merge` or `omit` (not yet) |
| `<For>` maps its items untracked (`mapArray`); the row is made once | A row runs untracked, made once (D-039) |
| `<Show>`'s function child is untracked | Untracked (D-039) |

What the rows say, as rules:

1. **A value prop is a getter.** Every prop of an effectful component written in rocx is passed as a
   getter, except three kinds: a prop named as an effect (`label!`), which is already an accessor or
   a function; `children`; and the props of the platform's own components (`pf.Show`, `pf.For`,
   `pf.Title`, …), whose types are their own. A static prop is a getter too (`label: || "Go"`), since
   the child is written once for all its callers, as in Solid.
2. **Where a read is written decides when it runs:**
   - in a hole, a computed attribute or a getter rocx writes: there, tracked;
   - in a lambda that runs as an effect (see "the component's reads" below): there, when it runs;
   - in the component's body: once, untracked, as the component runs;
   - in a pure function: where that function is made (pure code can't call a getter).
3. **The body's reads are one-time.** `create_signal!(start_value)` takes the start value once, as
   `createSignal(props.initial)` does.
4. **Accessors stay.** `label!={word!()}` is still `|| word!()`, typed `() => Str` by the child's
   author and read as `label!()`. A plain prop and an accessor are now the same thing under the
   hood. The difference is who writes the `!`: rocx for a plain prop, the author for an accessor.
5. **Pure components keep their semantics, with one fix.** A `view` (no `!`) stays a function of
   values, called where it is written, so it can be called from pure code, and its helpers keep
   taking its `Props` as data (`packages/markdown`). The fix: when a call passes a value read from
   what changes, rocx puts the call in a hole of its own (`Html.html_of(|| Card.view({…}))`), so it
   is rendered anew when that value changes. Today it is read once and never changes, outside a hole.
   - Solid has no pure components: there, every component's props are getters, patched in place. A
     pure component has no signals, so "anew" and "in place" differ only in the DOM's own state:
     focus, selection, an input's typed text, a CSS animation.
   - Making pure components take getters would mean they can't read a prop in their body (a pure
     function can't call one), and code that passes their `Props` around as data would break. So
     where the DOM's own state matters, make the component `view!`. This is the one place we diverge
     from Solid on purpose.
   - The fix becomes necessary once rows are untracked: a pure component in a row given
     `{post!().title}` would otherwise freeze.
6. **Rows and function children run untracked**, as Solid's `mapArray` and `untrack` do. A read at
   the top level of a row (`x = row!().title`, then `{x}`) is one-time. Reads in its holes, and the
   getters it passes to its components, are live.
   - A row whose top-level read waits (its value isn't in yet) still runs again once the value is
     in. A change alone no longer re-runs it.
   - Moving the Planner demo onto getters (rule 1) is what lets its rows stop being re-made.
7. **Where a prop's expression runs** is where the child reads it, as in Solid. So:
   - a `use_context!` in a prop's expression sees the contexts at the reading place;
   - an async read in it waits in the child's hole (that hole's `<Loading>`);
   - read in the child's body, an async value is refused, with the runtime's existing message ("a
     component read a value that isn't in yet outside its markup"). Today the parent's hole waited
     for it.
   - `is_pending!(|| label)` and `refresh!(|| label)` probe the getter, and so the caller's memos.
8. **Each read evaluates the caller's expression**, as a Solid getter does.
   `label={expensive(x!())}` read in three holes computes it three times when `x!` changes; a memo
   in the caller, or in the child (`n! = create_memo!(|| label)`), shares it.

## How rocx writes it

The transpiler (`rocx-cli/Transpile.roc`) does all of it. There is no new syntax and no new API
beyond the generated shapes. Lines stay lines: nothing below adds or removes a line.

### The caller

`<Child label={word!()} n={3} on_pick={pick} title!={t!()}>…</Child>`, where `Child` is a
component written in rocx (one of the file's type blocks, an imported module's, or a package's
copy under `Generated/`):

```roc
Html.component(|| Child.view!({ label: || word!(), n: || 3, on_pick: || pick, title!: || t!(), children: [ … ] }))
```

- `Html.component_with` and the transpiler's `reads_props` go.
- The platform's own components are called as before (`Show.view!({ when!: || …, fallback: …,
  children: … })`).
- A pure component is called with values; if one of them reads something that changes, the call is
  wrapped in `Html.html_of(|| …)` (rule 5).

### The component: its props' type

The view's annotation (`view! : {…} => Html`, or `view! : Props => Html` and the block's
`Props := {…}` or `Props : {…}`) is rewritten field by field:

| Written | Generated |
|---|---|
| `label : Str` | `label : () => Str` |
| `format : Dec -> Str` | `format : () => (Dec -> Str)` |
| `max : U64 ?? 5` (a nominal type's) | `max : (() => U64) ?? (\|\| 5)` |
| `faces! : () => List(Face)`, `children : List(Html)` | unchanged |

A default that is a getter is filled at a direct call. The spike `specialize/defaults.roc` checks
this; the generated caller is a direct call, `Child.view!({…})`.

A view typed by an alias the block doesn't define (another module's) is refused, with a message
that says where to write the type. No component here does that. A view with no annotation has
nothing to rewrite: Roc infers the getters.

### The component: its pattern

| Written | Generated |
|---|---|
| `\|{ label, faces!, children, .. }\|` | `\|{ label: label!, faces!, children, .. }\|` |
| `\|{ day: today }\|` | `\|{ day: today! }\|` |
| `\|props\|` | `\|props\|`, and `props.label` becomes `props.label()` |
| `\|{}\|`, `\|_\|` | unchanged |

This applies to:

- every `view!` (and `view_with!`) in a type's block;
- a route file's `view!`: a page's `params`, a layout's `meta` and `params`, the error page's
  `status` and `problem` (open question 1);
- a file's own function component (`answer! = |{ said }| …`, rendered as `<Answer>`), when the file
  uses it only as a tag.

A `.rocx` file's view bound to a name that is also a prop with a `!` (`label` and `label!` both) is
refused.

### The component: its reads

Inside the view's definition (from `view! =` to the next item of its block), each read of a prop's
name is rewritten. A read is the name where an expression can use it. These are not reads:

- after a `.` (`card.label`);
- a record's label before `:` (`{ label: x }`);
- inside a string's text, or a comment.

A punned field with commas, `{ id, label }`, becomes `{ id, label: label!() }`. (`{ label }` alone is
a block in Roc, so it stays a read.)

What a read becomes depends on the closure it is in, the nearest enclosing one:

| The closure | Runs | A read there |
|---|---|---|
| The component's body | once, untracked | `label!()` |
| A hole, a computed attribute, a getter, a key or transition rocx writes | as a computation | `label!()`, tracked |
| An effectful lambda: `\|\| …`; a handler's value (`on:…={…}`); a function child (`{\|row!, i!\| …}`); a lambda passed straight to a call of a `!` function (`create_effect!(…, \|r\| …)`, `xs.for_each!(\|x\| …)`); a lambda bound to a `!` name (`ended! = \|x\| …`) or a `!` field (`{ set_x!: \|v\| … }`) | when called | `label!()` |
| Any other lambda with parameters (passed to `.map`, `.keep_if`, a `keyed`, bound to a plain name): maybe pure | where it is made | hoisted |

A *hoisted* read is read where the outermost maybe-pure lambda is made, by calling that lambda's
own wrapper at once, so the lambda's code is left as written:

```roc
here! = || plans!().keep_if(|plan| plan.day == day.id)                      # written
here! = || plans!().keep_if((|day| |plan| plan.day == day.id)(day!()))      # generated
```

- The read is made inside `here!`, so whatever calls `here!` tracks it: the `<For>`'s `each!`.
- No platform function is needed: `(|day| …)(day!())` is plain Roc. The spike `specialize/iife.roc`
  checks it builds and runs.
- Several props are given in one go: `(|label, sep| …)(label!(), sep!())`.
- A pure lambda inside an effectful one inside another pure one gets names with a suffix (`day_2`),
  so no name is bound twice. Roc refuses shadowing ("duplicate definition").

Markup inside a pure lambda keeps its holes as holes, so they read for themselves:
`{...xs.map(|x| <li>{x.name} {sep}</li>)}` makes a `text_of(|| sep!())` per row, patched in place.

Rewriting can add a `!` to a hole or an attribute that had none, so it becomes a computation.
That is how a prop read in a hole is tracked: the existing rule ("a hole that calls something named
with `!` is a computation") does the rest.

rocx refuses, at its line, a prop's name bound again in the view: a lambda's parameter, `name = …`,
`for name in …`. Roc refused these before too, as duplicate definitions. Now that the pattern binds
`label!`, rocx has to refuse them itself.

### What isn't rewritten

- Pure components (rule 5).
- The platform's components (`.roc`, in `web/platform`).
- A hand-written `.roc` component: none exists outside the platform. If one is written, its author
  types its value props as getters (`label : () => Str`), which the docs will say.
- Helpers outside the view: the props aren't in scope there.
- Stories: a `<story>` is a caller, written as any caller is.

### The platform and the runtime

- `Html.roc` (both copies): `ComponentWith` and `component_with` go; `Html.component`'s doc says what
  it is given.
- `runtime.js`: a `<For>`'s new row and a `<Show>`'s function-child part run untracked. They are made
  once and owned as now, run again only after a wait, and never because a source changed. This builds
  on browser-gaps' item 1, which makes plain `<Show>` children and fallbacks lazy and untracked first.
- The server (`signals.rs`) runs every hole once, so it changes nothing. The JSON is the same
  (`{"t":"c"}`).
- `Routes.roc`: `Root`'s three calls of route views pass getters (`params: || params`).

## Before and after: the generated code

### 1. The web test's `Shows` (`web/test/app/Props.rocx`)

Before:

```roc
Html.element("p", [Html.attr("class", "once"),], [Html.component_with(|| { label: word!(), }, Shows.view!),]),
…
	view! : { label : Str } => Html
	view! = |{ label }| {
		(clicks!, set_clicks!) = create_signal!(0.U64)
		Html.element("button", […], [Html.text(label), Html.text(" "), Html.text_of(|| clicks!().to_str()),])
	}
```

After (the source unchanged):

```roc
Html.element("p", [Html.attr("class", "once"),], [Html.component(|| Shows.view!({ label: || word!(), })),]),
…
	view! : { label : () => Str } => Html
	view! = |{ label: label! }| {
		(clicks!, set_clicks!) = create_signal!(0.U64)
		Html.element("button", […], [Html.text_of(|| label!()), Html.text(" "), Html.text_of(|| clicks!().to_str()),])
	}
```

- Today: "once" never changes, and "hole" is made anew (its click count back to 0).
- After: both are patched in place and keep their count.

### 2. Quiz's podium (`examples/quiz/Ui/Podium.rocx`)

Its source goes back to a plain prop: `view! : { players : List(Game.Face), me : Str } => Html`, and
`<Podium players={current!().players} me={me} />` in the two room pages. Generated:

```roc
	view! : { players : () => List(Game.Face), me : () => Str } => Html
	view! = |{ players: players!, me: me! }| {
		ranked! = create_memo!(|| Score.ranked(players!().map(|player| { id: player.id, name: player.name, score: player.score })))
		…
							Html.class_of("me", || row!().id == me!()),
```

Its caller:

```roc
Html.component(|| Podium.view!({ players: || current!().players, me: || me, }))
```

- `players` is read in the memo's `||`: tracked, so the podium follows the scores.
- `me` is read in the `class:me` attributes of rows made untracked.
- `|player|` mentions no prop, so nothing is hoisted.

### 3. Board's tile and presence's stack (`packages/presence`, a package component)

The tile renders the stack in its markup with a plain label, kept while the viewers change:

```roc
<Show when!={!viewers!().is_empty()}>
	<AvatarStack faces!={viewers!} max={3} label={CardTile.viewing_label(viewers!())} />
</Show>
```

```roc
Show.view!({ when!: || !viewers!().is_empty(), children: [
	Html.component(|| AvatarStack.view!({ faces!: viewers!, max: || 3, label: || CardTile.viewing_label(viewers!()), })),
], }),
```

`AvatarStack.rocx` is copied into the app (`Generated/presence/AvatarStack.roc`) and written as any
component is:

```roc
	Props := {
		faces! : () => List(Stack.Face),
		max : (() => U64) ?? (|| 5),
		label : (() => Str) ?? (|| ""),
	}

	view! : Props => Html
	view! = |{ faces!, max: max!, label: label! }| {
		split! = create_memo!(|| Stack.split(faces!(), max!()))
		Html.element("div", […, Html.attr_of("aria-label", || if (label!().is_empty()) Stack.label(faces!()) else label!()),], [
```

The label is patched in place. The avatars' rows keep their transitions: one who comes grows in,
where today the whole stack is made anew. `CardTile.viewing` and its hole go.

### 4. The planner's day (`site/Demos/PlannerDay.rocx`), with a hoisted read

```roc
	view! : { day : () => Day, board : () => Board } => Html
	view! = |{ day: day!, board: board! }| {
		{ plans!, dragging!, set_dragging!, over!, set_over!, move! } = board!()
		here! = || plans!().keep_if((|day| |plan| plan.day == day.id)(day!()))
		dropped! = || {
			…
			if (plan.is_empty() or here!().any(|each| each.id == plan)) {} else move!({ plan, day: day!().id })
		}
		Html.element("section", [Html.attr("class", "day rx-ghqqeh"), Html.attr_of("data-day", || day!().id), Html.class_of("over", || over!() == day!().id), Html.on("dragenter", || set_over!(day!().id)), …], [
			Html.element("h4", […], [Html.text_of(|| day!().name),]),
```

- Before: `Html.attr("data-day", day.id)` and `Html.text(day.name)` were static, and the
  Planner's tracked row made the day anew when `day!()` changed.
- After: the row runs once, and the day's holes follow the getter.
- In `{ plan, day: day.id }`, the label `day:` is left alone and the value is rewritten.

## The shape the task suggested, and why not

The task suggested one accessor to the whole props record (`props! : () => { label : Str }`), with
reads rewritten to `props!().label`. I propose a getter per prop instead, as Solid's props object
has, for three reasons:

1. **A read of one prop would evaluate, and track, every prop's expression.**
   - A hole that renders markup from `open` would be made anew when `title` changed.
   - An effect reading `room` would run its apply again: a channel resubscribed when an unrelated
     prop changed.
   - The runtime can't compare Roc values, so a memo per prop can't stop this.
2. **A prop that waits would hold every read of every prop**: the whole child waits on its slowest
   prop.
3. **Roc doesn't fill `??` defaults in a record a thunk returns.** `|| { label: word!() }` given
   where `() => Props` is wanted fails: "This record is missing the field: max"
   (`specialize/defaults.roc`). Every default would break: AvatarStack's `max` and `label`, the
   charts' `padding`, the forms' `hint`. A direct call with getters is filled: `max : (() => U64) ??
   (|| 5)` builds.

## Other options weighed

- **Keep values; make a component anew when a prop changes**: today's `component_with` in a hole.
  The child's signals are lost: the bug the examples hit.
- **Run the component again, keeping its signals by call order** (React's hooks). That is not Solid,
  and it needs a DOM diff.
- **Getters boxed** (`Box(() => a)`), to avoid a lambda-set specialization per call site. The
  spike shows there is none to avoid: the component's body isn't copied per call site, and boxed
  getters cost about the same (see "Wasm size").
- **Make pure components take getters too.** They couldn't read a prop in their body, and their
  helpers that take `Props` as data (`packages/markdown`) would break. Rule 5 instead.

## Migration

Apps change no source: rocx writes both sides. What behaves differently:

1. **Value props are live, the child kept.** This is the change itself. A test that expected a
   child made anew (its signals reset) when a prop changed now sees it kept.
2. **Rows and function children are untracked.** A read at a row's top level outside a hole no
   longer re-makes the row, so it shows its first value.
   - The build phase audits every `<For>` row and `<Show>` function child in the site, the
     examples and the packages, and moves such reads into holes or `<Show>`s.
   - The likely shape is `{|todo!, _| if (todo!().done) <A/> else <B/>}`, which becomes
     `{=if (…) … else …}`.
3. **A prop that waits, read in the child's body, is refused** (rule 7). Today the parent's hole
   waited for it. The audit covers this too: a child's body-level reads of props whose callers pass
   endpoint reads or async memos.
4. **The server's HTML grows** with a hole's comments (`<!--x-->…<!--/x-->`) wherever a component
   reads a prop in a hole that was static. Hydration builds a computation for each. Tests that
   compare HTML strings get their new expectations.
5. **Errors read the generated code**: `label!()` where `label` was written, `() => Str` in a type.
   Line numbers stay right.

The examples come off their workarounds:

- board: `CardTile.viewing` goes, and the stack is in the tile's markup with a plain `label`;
- quiz: `Podium` takes `players`, not `players!`;
- the README sections "What it asked of the platform" say it was fixed.

The docs follow:

- `web/README.md`: Props, the tests list, and "Not yet" (the "patched in place" item goes);
- the root README's syntax table (the `label={…}` row);
- the docs site's components page and cheatsheet;
- the platform reference, where `component_with` goes.

## Risks

1. **The transpiler now reads Roc's lambdas.** It finds where a lambda starts, ends, and whether it
   is effectful. A wrong reading writes Roc that doesn't compile.
   - The end of a lambda is found by this rule: a `,` or a closer at its depth, `else`, or a newline
     at its depth before a line indented no deeper than the line it began on.
   - Mitigations: unit tests for each form; every `.rocx` file in the repo compiled (`just check`,
     `just examples`, `just site`); the refusals above, at the line.
2. **A pure lambda taken for an effectful one**: a `||` given to a pure function, or a lambda given
   to a `!` function that wants a pure one. If it reads a prop, the compiler says "This function is
   effectful, but a pure function is expected" about generated code. None in the repo, by my
   reading. The docs will say to bind the value first (`l = label`).
3. **Rows going untracked** is a change in behavior for apps (migration 2), and touches
   `runtime.js` code that browser-gaps is changing too.
4. **The compiler fork.**
   - Closures in a record of props: the spike builds and runs them.
   - Defaults that are lambdas: the spike builds them.
   - The known `--opt=speed` miscompile of chained effectful closures (`test/compiler-bugs`) is a
     different shape, but the native server runs more closures now. `just examples` runs each app's
     server.
5. **Cost.**
   - A getter per prop per call site, and a computation per prop-reading hole: see "Wasm size".
   - Comments in the HTML, and a computation per such hole while hydrating. A possible follow-up
     makes a hole that read nothing static, on both sides; it is not part of D-039, because strict
     hydration would have to agree.
6. **Collisions with the workers in the same files:**
   - transpiler-gaps (`Transpile.roc`);
   - browser-gaps (`runtime.js` rows and parts, `Html.roc`);
   - api-contract (`Routes.roc`: three lines);
   - client-nav (route views; open question 1).

## Test plan

**Transpiler** (`test/transpile.test.mjs`), one case each:

- caller getters, with static, computed and accessor props, `children`, a pure component's hole
  (rule 5), and the platform's components untouched;
- types: a record literal, `Props :=` with defaults, multi-line, a function type, an alias from
  elsewhere refused;
- patterns: `|{ a, b!, children, .. }|`, renamed fields, `|props|`;
- reads:
  - in the body, a hole, an attribute, a memo, an effect's both halves, a handler, a function child;
  - after `.`, as a label, punned with commas, in an interpolation, in a comment;
- hoisting: one prop, two, nested pure lambdas, pure inside effectful inside pure (`_2` names);
- refusals: a prop's name rebound;
- a route file's view, a local function component, a story, a `<NoHydration>`'s client copy.

**Web platform** (`web/test/platform.test.mjs`), with `Props.rocx` extended:

- a value prop changes:
  - the child keeps its click count;
  - the observer reports one patch, on the label's text node, and no component run;
- the same inside a hole (`{=<Shows …/>}`) and inside a `<Show>`'s children;
- a read in the body stays the first value;
- a read hoisted out of a pure lambda (`keep_if`) is patched;
- an effect reading a prop runs again;
- a handler reads the current value;
- rendered as the server would and hydrated strictly: no request, no mismatch;
- untracked rows and function children:
  - a row whose item changes keeps its element (same node);
  - a top-level read in a row is one-time;
  - the Planner test (D-030) stays green;
- no allocation left behind.

**Server platform**: the server's tests with their new HTML; a page whose component reads a prop
in a hole, as the server renders it.

**Examples, in the browser:**

- quiz: the podium with a plain `players` prop shows a score made after the page rendered (the
  existing test, rewritten);
- board: a second person opens a card, and the first sees the label change with the stack's
  element kept.

**Everything** green after rebasing onto master: `just check`, `just test`, `just examples`,
`just site`.

## Wasm size

Spike (`specialize/*_6.roc`): one component with two props, read in three holes (one through a pure
`.map`), at one call site and at six. Sizes from `--opt=size`, raw and brotli.

| | 1 site | 6 sites | per extra site |
|---|---|---|---|
| values (today) | 95,098 / 30,732 | 95,586 / 30,886 | +98 B raw |
| getters `() => T` | 96,044 / 30,991 | 97,586 / 31,273 | +308 B raw |
| boxed getters | 95,764 / 30,878 | 96,979 / 31,107 | +243 B raw |

- With five more elements in the body, the six-site build grows by the same amount (+1,549 B
  against +1,542 B). So the body isn't copied per call site, and plain getters are fine.
- The real figure is the site's client wasm, measured on master and on the branch, raw and br, and
  reported at the end. Expect it to grow by a little: a closure per prop per call site, and a
  closure per prop-reading hole.

## Order of landings

1. browser-gaps' item 1 (plain `<Show>` children and fallbacks lazy and untracked), already ahead.
2. D-039, one branch, rebased onto master often:
   - first the transpiler, `Html.roc`, untracked rows and function children, the tests and the
     docs;
   - then board and quiz moved off their workarounds.
   - transpiler-gaps may land on either side; the conflicts are in `read_code`, `read_markup`,
     `read_attributes` and `read_hole`.
3. api-contract (D-037): whichever of D-037 and D-039 lands second rebases the three `Routes.roc`
   lines.
4. client-nav (D-040), after D-039: with route views given getters, a layout kept across a
   navigation sees its `params` change in place, as SolidStart's do.

## Open questions, answered

1. **Route views get getters too:** yes, one rule, SolidStart's parity. A page's `params`, a
   layout's `meta` and `params`, the error page's `status` and `problem` are getters. This lets
   D-040 (client-side navigation, proposed) keep a page or a layout across a change of its params,
   if the user chooses that: its holes and memos follow the getter, and a read in its body is one
   the runtime sees (the getter's reads, noted on the component's run), which D-040 may make it anew
   for.
2. **A pure component's call with a changing value becomes a hole:** yes.
3. **No dev warning for reads in a body:** agreed; a follow-up, below.
4. **A file's own function component** is rewritten only when the file uses it only as a tag. When
   it is also called directly, and a tag gives it a value read from what changes, `rocx build` warns
   at that tag: its props stay values, read where the tag is (the call is a hole of its own, made
   anew), because rewriting it would break the direct calls.

## Follow-ups (not in D-039)

- **`untrack`** (Solid's), and with it **Solid 2.0's dev warning** for a reactive read at a
  component's top level (a prop's getter or a signal read in the body), whose fix is `untrack`.
- **A hole that read nothing is static**: written without comments by the server, adopted as text
  by hydration, so a prop given a constant costs no computation; both sides must agree, under strict
  hydration.
- **`merge` / `omit`** (Solid 2.0's), if an app wants to pass a props record on.

## As built

Where the build differs from the design above, and why:

- **`(props.label)()`, not `props.label()`.** For a view that names its whole record, a field's
  getter is called in parentheses: `props.label()` is a call of the method `label` of the props'
  nominal type, which the compiler refused (the charts, `Flagged`).
- **An accessor named through a prop.** `left!={clock.left!}`, where `clock` is a prop, was an
  accessor's name; `clock` is a getter now, so rocx passes `|| (clock!().left!)()`, which follows the
  prop (quiz's `Countdown`).
- **Nested roots name their own whenever one is inside another's run** (`me_2`), not only when the
  names would collide: an outer root's names aren't known until it closes.
- **D-044 composed.** D-044 (landed meanwhile) unbinds in the browser's copy a name only a
  `<NoHydration>`'s children used. A getter's binding, `{ params: params! }`, is unbound as
  `params: _`. Its offsets assumed a rewrite is never shorter than the name; they are signed now.
- **The warning for a function component kept with values** is `rocx build`'s, printed with its
  other messages (`⚠ file:line:column`), not `rocx lint`'s: the build has the transpiler's result.
- **Quiz's `Lobby` and `Board`** came off their accessor props too (`players`, `rows`), as well as
  `Podium`: the plain prop reads better there for the same reason.
- **Rows' and function children's untracked runs** are a flag on the runtime's computation
  (`untracked`). Its sources aren't kept, so only a read that waits runs it again.
