app [render!] { pf: platform "../platform/main.roc" }

import pf.Async
import pf.Cell

## A page that needs five answers; it reads each as a plain Str.
render! : Str => Str
render! = |page| {
	count = Cell.new!({ label: "visits", n: 41 })
	seen = Cell.get!(count)
	keys = ["/user", "/posts", "/comments", "/likes", "/friends"]
	if (page == "parallel") {
		for key in keys {
			Async.start!(key)
		}
	} else {
		{}
	}
	var $parts = []
	for key in keys {
		# Allocate a little before each read, so an abort has something to leak.
		$parts = $parts.append("${key}=${Async.read!(key)}")
	}
	"${page}: ${Str.join_with($parts, ", ")} (${seen.label} ${(seen.n + 1).to_str()})"
}
