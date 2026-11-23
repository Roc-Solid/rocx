import Html

## `<Repeat>`, as Solid 2.0 has it: a row for each index from `from!` (0 unless it says) up to, not
## including, `from! + count!`, with no list behind them:
##
##     <Repeat count!={stars!()}>{|index| <span class="star" />}</Repeat>
##
## A row is kept as long as its index is in the range, so when the range moves (`from!` grows as a
## list scrolls) only the rows that come into it are made, and only those that leave it go: what a
## virtual list renders the rows that show with.
##
##     <Repeat count!={shown!()} from!={first!()}>{|index| <Row index={index} />}</Repeat>
##
## The child is effectful (`=>`): it runs when its row is made, given the row's index, which doesn't
## change, and may do what a component does there. The fallback while the count is 0.
Repeat := [].{
	Props := { count! : () => U64, from! : (() => U64) ?? (|| 0), fallback : Html ?? Html.empty({}), children : U64 => Html }

	## What `<Repeat count!={…}>{|index| …}</Repeat>` is: a row per index in the range, made once and
	## kept while its index is in it.
	view_with! : Props => Html
	view_with! = |props| {
		count! = props.count!
		from! = props.from!
		children = props.children
		rows! = |_id| {
			first = from!()
			end = first + count!()
			var $rows = []
			var $index = first
			while $index < end {
				at = $index
				$rows = $rows.append({ key: at.to_str(), row: || children(at) })
				$index = $index + 1
			}
			$rows
		}
		Html.each(rows!, props.fallback)
	}
}
