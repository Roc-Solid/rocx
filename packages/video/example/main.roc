## An app that uses packages/video: a page with a short video made of its own components
## (`Launch`), played live by `<Player>`, and its stories, which the catalog plays side by side.
## `rocx build . --dev`, then build it as any app; `rocx render` films it.
app [program] { pf: platform "../../../server/platform/main.roc", video: "../main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
