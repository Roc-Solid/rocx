## A small app that uses packages/intl: a page in English, Polish or Arabic, chosen from the
## reader's `locale` cookie or their `Accept-Language`, switched in place by a picker, the choice
## kept by `POST /locale`. The docs show their code from these files. Build it with
## `rocx build packages/intl/example --client <out>`.
app [program] { intl: "../main.roc", pf: platform "../../../server/platform/main.roc" }

import Generated/App
import pf.Middleware

program = App.program({
	context: |_started| {},
	middleware: Middleware.same_origin({}),
	crons: [],
})
