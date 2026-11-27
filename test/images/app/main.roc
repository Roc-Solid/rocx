## The app enhanced:src's test (test/images.test.mjs) serves (D-125): photos in static/, and one a
## route answers.
app [program] { pf: platform "../../../server/platform/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
