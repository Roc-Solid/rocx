## Roc Solid's js-framework-benchmark entry, keyed (benchmarks/jsframework/README.md): one page,
## written as files by `rocx build --static`. Every request goes straight to its route (no
## routes/+middleware.roc).
app [program] { pf: platform "../../../server/platform/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
