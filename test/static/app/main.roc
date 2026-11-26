## The app `rocx build --static`'s test (test/static.test.mjs) copies as files.
app [program] { pf: platform "../../../server/platform/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
