# Stores (D-053, item 3): design

Status: **Built** 2026-11-23 (D-053 in `DECISIONS.md`). The coordinator's go came with two
conditions; "As built", at the end, says how they changed the design.

## In short

Solid 2.0's `createStore` makes a proxy over nested data. A read of a path (`state.user.name`)
tracks that path only, and a write through the setter's draft (`setState(s => { s.user.name =
"Grace" })`) tells only the readers of what it changed. Roc has no proxies, no identity and no
reflection, so a store can't see which field a reader touches. What Roc has is functions over
values, and values compared by what they are. So:

- **A read selects:** `todos.get!(|s| s.filter)`. The reader runs again only when what it selected
  changed, compared by value. That is "a read tracks that path only", decided by the value at the
  path rather than by the path's name.
- **A write is a function of the state:** `set_todos!(|s| { ..s, filter: Done })`. Roc's record
  update is the draft. Two writes in one handler compose, as two draft setters do in Solid.
- **Per item:** a `<For>`'s row is told its item changed only when it did (compared by value), so a
  store's list given to a `<For>` patches one row when one item changes.

```roc
import pf.Solid exposing [create_store!]

(todos, set_todos!) = create_store!({ items: [], filter: All })

<p>{todos.get!(|s| Filter.name(s.filter))}</p>
<For each!={todos.get!(|s| s.items)} keyed={|todo| todo.id}>
    {|todo!, _| <li class:done={todo!().done}>{todo!().title}</li>}
</For>
<button on:click={|| set_todos!(|s| { ..s, filter: Done })}>Done</button>
```

Clicking the button runs the filter's hole again and nothing else. Toggling one todo runs that
row's holes again and nothing else (today, every row's would).

## Solid 2.0 beside this

| Solid 2.0 | Roc Solid |
|---|---|
| `const [state, setState] = createStore(init)` | `(state, set_state!) = create_store!(init)`: `state : Store(s)`, `set_state! : (s -> s) => {}` |
| `state.user.name`: tracks `user.name` | `state.get!(\|s\| s.user.name)`: the reader runs again only when `s.user.name` changes |
| `state.todos[i].done` in a row: tracks that item's `done` | the row's `todo!().done`: the row's holes run again only when its item changes (any field of it) |
| `setState(s => { s.user.name = "Grace" })` (draft) | `set_state!(\|s\| { ..s, user: { ..s.user, name: "Grace" } })` |
| `setState(s => { s.todos.push(t) })` | `set_state!(\|s\| { ..s, todos: s.todos.append(t) })` |
| two setters in one handler: both apply, in order | the same: the second is given what the first made |
| `storePath("todos", t => t.id === id, "done", true)` (1.x-style path setter) | not needed: `s.todos.map(\|t\| if (t.id == id) { ..t, done: Bool.True } else t)` |
| `reconcile(serverTodos, "id")` (keep identity by key) | not needed: write the new list; rows are kept by key, and an equal item tells no row |
| `snapshot(state)`: untracked plain value | `untrack!(\|\| state.get!(\|s\| s))` |
| a store passed to a child, read there | the same: a `Store(s)` is a value; a getter prop or a context carries it |
| `createStore(fn, seed)` / `createProjection` (derived, writable) | not now: a memo is the derived read (`create_memo!`) |
| `createOptimisticStore` | not now: D-030's optimistic memos cover the actions' case |
| `deep(store)` (track everything) | `state.get!(\|s\| s)` |

## How a read tracks

`Store(s) :: { id : U64 }` (a signal's id, with methods). `state.get!(select)`:

- **In a computation that tracks** (a hole, an attribute, a memo, an effect's compute): a
  *selection* is made, owned by that run: a memo of `select(whole)`, which also hands the runtime
  `Str.inspect` of its value. The reader tracks the selection, not the store. A write to the store
  runs each live selection again (a pure function: cheap), and a selection whose text is the one it
  had keeps quiet: its readers don't run. A selection is let go of with the run that made it, as
  any memo is.
- **Anywhere else** (a handler, an effect's apply, a timer, a component's body, inside `untrack!`,
  and always on the server, where nothing runs again): `select(whole)` is computed, once; nothing is
  made.

So the runtime compares texts it is given, never Roc values, which it can't.

Equality is `Str.inspect`'s: two values with the same text are equal. A function inside a selected
value prints as `<function>`, so a selection that differs only in a function's captures keeps quiet:
select data, not handlers (said in the docs). The value kept is always the newest, so a handler
reading it later gets the newest function anyway.

## How an item tracks

A `<For>`'s rows are made from its list each time the list is read again (`rows!`), and each row's
item is set again (`Host.row_set!`), which today tells every row's readers, since the host can't
compare Roc values. For.roc will hand `Str.inspect(item)` with it, and the runtime tells a row's
readers only when that text changed (keeping the newest value either way). This is every `<For>`'s,
whatever its list comes from: a signal's list, an endpoint's, a store's. Nothing visible changes but
fewer runs: an unchanged row's holes computed the same text, which was no patch.

Per field within one item isn't separate: a row's holes all run again when its item changes. A row
that wants finer can select from its item: `Store.of(todo!).get!(|t| t.done)` (below).

## What it costs

- **A write runs every live selection of the store once:** a call into Roc and a `Str.inspect` each.
  Solid's store touches only the paths written. With a few hundred selections that is a millisecond
  or so per write: fine for clicks and typing, worth saying for anything per frame.
- **A `<For>` re-read inspects each item:** O(the list's size) text, once per re-read. It replaces
  running each row's holes again, which cost more.
- **Host:** `memo_done!` and `row_set!` take the value's text; two new hosted functions,
  `tracking!` (whether the running computation tracks reads: is a selection worth making) and
  `signal_latest!` (a signal's value with the running handler's own pending write, so two writes in
  one handler compose). Both hosts (`web/host/host.zig` and `runtime.js`; `server/host/src`), the
  glue regenerated. The server answers `tracking!` false and ignores the texts.

## What is new in the platform

```roc
# Solid.roc
create_store! : s => (Store(s), ((s -> s) => {}))    # Solid's createStore

# Store.roc (a shared module, both platforms)
Store(s) :: { … }.{
    get! : Store(s), (s -> a) => a                    # a part: tracked by its value
    of : (() => s) -> Store(s)                       # any accessor (a memo, an endpoint read, a prop) read by parts
}
```

`Store.of(board!)` makes selections over anything that changes as a whole: an endpoint's answer
(`board.get!(|b| b.columns)`), a memo, a prop's getter, a row's item. It has no setter.

Why the platform and not a package: the selection needs the host (the memo's text,
`tracking!`), and `createStore` is core Solid. Store.roc is about forty lines of Roc on top.

## Alternatives weighed

1. **Paths as lenses**, each step a name and both directions:
   `Store.field("user", |s| s.user, |s, u| { ..s, user: u })`. Tracking would be per path name, as
   precise as Solid's, but every field a store is read or written through needs its lens written out
   (Roc has no `.field` accessor shorthand and no reflection), and rocx would have to generate them
   from types it doesn't see. Too much to write for what it buys.
2. **JSON paths** (`state.get!(["user", "name"])`, decoded by the type it is used as): per path, but
   untyped: a misspelled path is a failure at run time. Refused for Roc's sake.
3. **Transpiler sugar** (`state.user.name` in a `.rocx` file written as a selection): possible later
   on top of this design, as D-039 rewrote prop reads; not now (it hides a call, and rocx doesn't
   know which names are stores).
4. **Every memo compared by value** (Solid 2.0's memos compare by `===`): a memo returning markup or
   a function would never tell its readers again (both print alike), and every memo would pay for
   `Str.inspect`. Only selections compare.

## Tests (when built)

- web: a store app (`Stores.rocx`): a filter, a counter and a list of todos in one store; the server
  renders it, the browser hydrates it strictly; a click runs only the holes that selected what
  changed (the runtime's patch observer and run counts), a toggle patches one row; two writes in one
  handler both apply; a selection in a handler reads the newest; `Store.of` over a memo.
- server: a page reading a store renders it, its holes static when they read nothing else (D-052).
- docs: web/README (Stores), the components page, Solid's table.

## Open questions (with my recommendations)

1. **Selections by value, as above** (recommended), or lenses (alternative 1)?
2. **`<For>` rows compared by value for every list** (recommended: fewer runs, nothing else seen), or
   only for a store's?
3. **`Store.of`** for any accessor (recommended: it is a line, and endpoint reads are where big
   values live), or `create_store!` only?
4. **Names:** `create_store!` and `get!` (recommended), or `Store.create!` and `select!`?

## As built

The coordinator agreed to questions 1, 3 and 4 as recommended, and to 2 on conditions: compare
with Roc's `==` where the type allows rather than `Str.inspect`'s text, and compare `<For>` rows
for every list only if measuring shows it costs nothing that matters. So:

- **Selections compare with `==`.** `get! : Store(s), (s -> a) => a where [a.is_eq : a, a -> Bool]`.
  The runtime can't compare Roc values, so the comparison is Roc's: a selection's run asks for the
  value it had (`Host.memo_last!`, which answers the value it is given when there is none yet) and
  hands its new one with whether they are equal (`Host.memo_done!`'s `same`). No text is made, and
  a function or markup can't be selected at all (the compiler says the type doesn't support
  equality), which is the docs' "select data" made a rule.
- **`<For>` rows compared only with `compared`.** Measured on a `<For>` of 10,000 rows (D-053 has
  the table): comparing every list by `Str.inspect` made a list whose items all change 11% slower,
  with 22% more allocations; comparing with `==` costs nearly nothing but requires `is_eq` of every
  `<For>`'s items, which would refuse lists of records holding functions or markup (packages/intl's
  language picker is one). So it is a flag, `<For … compared>`, with `==` (`Host.row_last!`, and
  `row_set!`'s `same`). Measuring also found that `<For>` made its keys unique in quadratic time:
  a `Dict` now, 1,865 ms to 66 ms a change at 10,000 rows, for every `<For>`.
- **Host:** `memo_done!` and `row_set!` take a `same` flag rather than a text; `tracking!`,
  `memo_last!`, `signal_latest!` and `row_last!` are new. The runtime counts selections run
  (`stats.selections`) and the wasm host counts allocations (`allocations()`), for the tests: a
  write to the store of four hundred selections runs 401 of them (the one hole that ran again makes
  its selection anew), patches one hole, allocates 407 times, and takes about half a millisecond.

