## A small app that uses packages/intl: a page in English, Polish or Arabic, chosen from the
## reader's `locale` cookie or their `Accept-Language`, switched in place by a picker, the choice
## kept by `POST /locale`. The docs show their code from these files. Run it with
## `rocx dev packages/intl/example`.
app [program] { intl: "../main.roc", pf: platform "../../../server/platform/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
