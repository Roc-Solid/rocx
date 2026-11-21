## Spike: can Roc code read async values as plain values, the way Solid 2.0 reads an async memo?
## A read of a value that isn't there yet throws (in JS) through the Roc frames; the runtime
## catches it, restores Roc's stack pointer, waits, and runs the render again.
platform ""
	requires {
		render! : Str => Str
	}
	exposes [Async, Cell]
	packages {}
	provides { "roc_render": render_for_host! }
	hosted {
		"roc_async_read": Host.async_read!,
		"roc_async_start": Host.async_start!,
		"roc_cell_new": Host.cell_new!,
		"roc_cell_get": Host.cell_get!,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			output: Shared,
			exports: ["render", "alloc_bytes", "result_ptr", "result_len", "live_allocations"],
			initial_stack_size: 1048576,
		},
	}

import Host
import Async
import Cell

render_for_host! : Str => Str
render_for_host! = |input| render!(input)
