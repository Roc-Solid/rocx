import Host

## A store, Solid 2.0's (`createStore`): state of many parts in one value, each part read on its own.
## Roc has no proxies, so a read can't see which field it touched: a read *selects*, and is tracked by
## what it selected.
##
##     (todos, set_todos!) = create_store!({ items: [], filter: All })
##
##     <p>{Filter.name(todos.get!(|s| s.filter))}</p>
##     <For each!={todos.get!(|s| s.items)} keyed={|todo| todo.id}>{|todo!, _| <li>{todo!().title}</li>}</For>
##     <button on:click={|| set_todos!(|s| { ..s, filter: Done })}>Done</button>
##
## A click on Done runs the filter's hole again, and nothing else: the list's selection is computed
## again, finds the same items, and keeps quiet. A write is a function of the state (Roc's record
## update is Solid's draft), and two in one handler compose. `Store.of` reads any accessor so: an
## endpoint's answer, a memo, a prop.
Store(s) :: { read! : () => s }.{

	## A store over an accessor (a memo, an endpoint's read, a prop's getter, a row's item), read by
	## parts with `get!`. It has no setter: what changes it is what changes the accessor.
	##
	##     board = Store.of(board!)
	##     <h1>{board.get!(|b| b.title)}</h1>
	of : (() => s) -> Store(s)
	of = |read!| { read!: read! }

	## A part of the store, `select`ed: `todos.get!(|s| s.filter)`. Where it is read by what runs
	## again (a hole, an attribute, a memo, an effect's compute), the reader runs again only when that
	## part changes, compared by Roc's `==`: a write to the store computes each part read again (a pure
	## function, cheap), and one equal to what it was tells nobody. Anywhere else (a handler, a
	## component's body, inside `untrack!`, the server) it is `select` of the store's value, once.
	##
	## A part compares with `==`, so it is data: records, tags, lists, text and numbers do, a type of
	## one's own needs its `is_eq`; a function or markup can't be selected.
	get! : Store(s), (s -> a) => a where [a.is_eq : a, a -> Bool]
	get! = |store, select| {
		read! = store.read!
		if Host.tracking!({}) {
			# A selection: a memo of the part, owned by the reader's run, quiet when its part is the same.
			run! = || {
				value = select(read!())
				boxed = Box.box(|| value)
				last = Box.unbox(Host.memo_last!(boxed))
				Host.memo_done!(boxed, last() == value)
				""
			}
			id = Host.memo_new!(Box.box(run!))
			current = Box.unbox(Host.memo_get!(id))
			current()
		} else {
			select(read!())
		}
	}
}
