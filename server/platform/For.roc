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
## there, hold another `<For>` or a `<Show>`; a child that is plain markup is fine too.
For := [].{
	PropsKeyed(a, k) := { each! : () => List(a), keyed : a -> k, fallback : Html ?? Html.empty({}), children : (() => a), (() => U64) => Html }

	## What `<For keyed={|item| …}>` is: a row per key, made once, moved as the list changes, and
	## dropped with its key; the child gets accessors of its item and its index. The fallback while
	## the list is empty.
	view_with_keyed! : PropsKeyed(a, k) => Html
	view_with_keyed! = |props| {
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
				$rows = $rows.append(row!(id, key, item, |item!| children(item!, || Host.row_index!(id, key))))
				$index = $index + 1
			}
			$rows
		}
		Html.each(rows!, props.fallback)
	}

	PropsUnkeyed(a) := { each! : () => List(a), fallback : Html ?? Html.empty({}), children : (() => a), U64 => Html }

	## What `<For keyed={Bool.False}>` is: a row per position; the child gets an accessor of the
	## item there and its index. The fallback while the list is empty.
	view_with_unkeyed! : PropsUnkeyed(a) => Html
	view_with_unkeyed! = |props| {
		each! = props.each!
		children = props.children
		rows! = |id| {
			var $rows = []
			var $index = 0.U64
			for item in each!() {
				at = $index
				$rows = $rows.append(row!(id, at.to_str(), item, |item!| children(item!, at)))
				$index = $index + 1
			}
			$rows
		}
		Html.each(rows!, props.fallback)
	}
}

## A row: its item kept by the host under its key (so the row's accessor reads the item there now),
## and how to make the row.
row! : U64, Str, a, ((() => a) => Html) => { key : Str, row : () => Html }
row! = |id, key, item, make| {
	Host.row_set!(id, key, Box.box(|| item))
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
