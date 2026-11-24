import Host
import Html

## `<For>`, as Solid 2.0 has it: rows made once, moved and dropped as the list changes. Roc's values
## have no identity, so a list says how its rows are kept:
##
##     <For each!={todos!()} keyed={|todo| todo.id}>{|todo!, index!| <li>{todo!().text}</li>}</For>
##
## keeps a row per key, as long as the key is there, moved where it goes; its item and its index are
## accessors, since both may change (an edited todo keeps its row). And
##
##     <For each!={names!()} keyed={Bool.False}>{|name!, index| <li>{name!()}</li>}</For>
##
## keeps a row per position (Solid's `<Index>` before 2.0): an accessor of the item there, which
## changes, and its index, which doesn't.
##
## The child is effectful (`=>`): it runs when its row is made, and may do what a component does
## there, hold another `<For>` or an `if`; a child that is plain markup is fine too.
##
## Each time the list is read again, every row is told its item may have changed, and the holes that
## read it run again (a value a node has already is no patch). `compared` (D-053) tells a row only
## when its item isn't `==` the one it had, so a list of ten thousand in which one changed runs one
## row's holes: a store's list, say. Its items must compare (records, tags, lists, text, numbers; a
## type of one's own needs its `is_eq`; not functions or markup):
##
##     <For each!={todos.get!(|s| s.items)} keyed={|todo| todo.id} compared>{|todo!, _| …}</For>
For := [].{
	PropsKeyed(a, k) := { each! : () => List(a), keyed : a -> k, fallback : Html ?? Html.empty({}), children : (() => a), (() => U64) => Html }

	## What `<For keyed={|item| …}>` is: a row per key, made once, moved as the list changes, and
	## dropped with its key; the child gets accessors of its item and its index. The fallback while
	## the list is empty.
	view_with_keyed! : PropsKeyed(a, k) => Html
	view_with_keyed! = |props| keyed_rows!(props, row!)

	## `<For keyed={|item| …} compared>`: the same, a row told its item changed only when it isn't
	## `==` the one it had.
	view_with_keyed_compared! : PropsKeyed(a, k) => Html where [a.is_eq : a, a -> Bool]
	view_with_keyed_compared! = |props| keyed_rows!(props, compared_row!)

	PropsUnkeyed(a) := { each! : () => List(a), fallback : Html ?? Html.empty({}), children : (() => a), U64 => Html }

	## What `<For keyed={Bool.False}>` is: a row per position; the child gets an accessor of the
	## item there and its index. The fallback while the list is empty.
	view_with_unkeyed! : PropsUnkeyed(a) => Html
	view_with_unkeyed! = |props| unkeyed_rows!(props, row!)

	## `<For keyed={Bool.False} compared>`: the same, a row told its item changed only when it isn't
	## `==` the one it had.
	view_with_unkeyed_compared! : PropsUnkeyed(a) => Html where [a.is_eq : a, a -> Bool]
	view_with_unkeyed_compared! = |props| unkeyed_rows!(props, compared_row!)
}

## A row per key, each made by `row`.
keyed_rows! : For.PropsKeyed(a, k), (U64, Str, a, ((() => a) => Html) => { key : Str, row : () => Html }) => Html
keyed_rows! = |props, row| {
	each! = props.each!
	keyed = props.keyed
	children = props.children
	rows! = |id| {
		items = each!()
		keys = keys_of(items.map(|item| Str.inspect(keyed(item))))
		var $rows = []
		var $index = 0.U64
		for item in items {
			key = keys.get($index) ?? $index.to_str()
			$rows = $rows.append(row(id, key, item, |item!| children(item!, || Host.row_index!(id, key))))
			$index = $index + 1
		}
		$rows
	}
	Html.each(rows!, props.fallback)
}

## A row per position, each made by `row`.
unkeyed_rows! : For.PropsUnkeyed(a), (U64, Str, a, ((() => a) => Html) => { key : Str, row : () => Html }) => Html
unkeyed_rows! = |props, row| {
	each! = props.each!
	children = props.children
	rows! = |id| {
		var $rows = []
		var $index = 0.U64
		for item in each!() {
			at = $index
			$rows = $rows.append(row(id, at.to_str(), item, |item!| children(item!, at)))
			$index = $index + 1
		}
		$rows
	}
	Html.each(rows!, props.fallback)
}

## A row: its item kept by the host under its key (so the row's accessor reads the item there now),
## and how to make the row.
row! : U64, Str, a, ((() => a) => Html) => { key : Str, row : () => Html }
row! = |id, key, item, make| {
	Host.row_set!(id, key, Box.box(|| item), Bool.False)
	made_row(id, key, make)
}

## A row whose item is compared with the one it had (`compared`, D-053): told it changed only when
## it isn't `==` that one. A new row's item is compared with itself.
compared_row! : U64, Str, a, ((() => a) => Html) => { key : Str, row : () => Html } where [a.is_eq : a, a -> Bool]
compared_row! = |id, key, item, make| {
	boxed = Box.box(|| item)
	last = Box.unbox(Host.row_last!(id, key, boxed))
	Host.row_set!(id, key, boxed, last() == item)
	made_row(id, key, make)
}

## How to make a row whose item the host keeps under its key: its accessor reads the item there now.
made_row : U64, Str, ((() => a) => Html) -> { key : Str, row : () => Html }
made_row = |id, key, make| {
	item! = || {
		current = Box.unbox(Host.row_get!(id, key))
		current()
	}
	{ key, row: || make(item!) }
}

## The keys, each once: the second of two equal keys is another row (`#1`), and so on. How many of
## each came before is a `Dict`'s, so a list of ten thousand rows takes ten thousand lookups (a
## count over the keys seen, each time, took fifty million comparisons).
keys_of : List(Str) -> List(Str)
keys_of = |keys| {
	var $seen = Dict.empty()
	var $out = List.with_capacity(keys.len())
	for key in keys {
		count = $seen.get(key) ?? 0.U64
		$seen = $seen.insert(key, count + 1)
		$out = $out.append(if (count == 0) key else "${key}#${count.to_str()}")
	}
	$out
}

expect keys_of(["a", "b", "a", "a"]) == ["a", "b", "a#1", "a#2"]
