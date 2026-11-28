## An app that uses packages/video: a page with a short video made of its own components
## (`Launch`), played live by `<Player>`, and its stories, which the catalog plays side by side.
## Run it with `rocx dev packages/video/example` (its stories at `/__rocx/stories`); with it
## running, `rocx render <its url>` films the page's video.
app [program] { pf: platform "../../../server/platform/main.roc", video: "../main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
