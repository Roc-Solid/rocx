## The browser's platform: an app's page, Solid 2.0-style components, in one wasm module the
## browser loads (web/start.js and web/runtime.js run it). A component runs once; its markup's holes
## are computations the runtime runs again when what they read changes; an async read (an
## endpoint's answer, a memo waiting for one) aborts its computation until it is in, and the
## nearest <Loading> or <Errored> shows instead.
##
## - `main!`: the app's root, the page (`rocx build --client` writes it: `Generated/Root`), which
##   the browser hydrates from the document the server rendered. The server platform
##   (`server/platform`) renders the same components natively, and answers the endpoints they read;
##   the browser's copy of an app answers none.
##
## The modules both platforms have are written here, and the server platform's build copies them:
## the components' (`Html`, `Solid`, `Store`, `Show`, `Switch`, `Match`, `For`, `Repeat`, `Transition`, `Loading`, `Errored`, `Context`,
## `Call`, `Router`, `Submission`, `Submissions`, `Title`, `HttpStatusCode`) and HTTP's (`Server`, `Endpoint`,
## `Channel`, `Middleware`, `Events`, `OpenApi`). Roc compiles only what a program reaches, so what
## only the server uses (`Middleware`, `OpenApi`) costs the browser's wasm nothing. `Time` is the
## browser's own, under the server's names: the clock, for handlers, effects and timers.
platform ""
	requires {
		main! : {} => Html
	}
	exposes [Browser, Call, Channel, Context, Endpoint, Errored, Events, For, Html, HttpStatusCode, Loading, Match, Middleware, OpenApi, Repeat, Router, Server, Show, Solid, Store, Submission, Submissions, Switch, Time, Title, Transition]
	packages {}
	provides { "roc_mount": mount_for_host!, "roc_run": run_for_host! }
	hosted {
		"roc_action": Host.action!,
		"roc_boundary": Host.boundary!,
		"roc_browser_call": Host.browser_call!,
		"roc_cleanup": Host.cleanup!,
		"roc_clear_timer": Host.clear_timer!,
		"roc_context_find": Host.context_find!,
		"roc_context_get": Host.context_get!,
		"roc_context_value": Host.context_value!,
		"roc_effect_new": Host.effect_new!,
		"roc_effect_options": Host.effect_options!,
		"roc_event_value": Host.event_value!,
		"roc_fail": Host.fail!,
		"roc_fetch": Host.fetch!,
		"roc_flash": Host.flash!,
		"roc_for_new": Host.for_new!,
		"roc_head": Host.head!,
		"roc_host_live_publish": Host.live_publish!,
		"roc_interval": Host.interval!,
		"roc_is_pending": Host.is_pending!,
		"roc_keep": Host.keep!,
		"roc_listen": Host.listen!,
		"roc_location": Host.location!,
		"roc_memo_done": Host.memo_done!,
		"roc_memo_get": Host.memo_get!,
		"roc_memo_last": Host.memo_last!,
		"roc_memo_new": Host.memo_new!,
		"roc_now_millis": Host.now_millis!,
		"roc_now_nanos": Host.now_nanos!,
		"roc_optimistic_set": Host.optimistic_set!,
		"roc_problem": Host.problem!,
		"roc_read_at": Host.read_at!,
		"roc_refresh": Host.refresh!,
		"roc_request": Host.request!,
		"roc_resync": Host.resync!,
		"roc_retry": Host.retry!,
		"roc_revalidate": Host.revalidate!,
		"roc_row_get": Host.row_get!,
		"roc_row_index": Host.row_index!,
		"roc_row_last": Host.row_last!,
		"roc_row_set": Host.row_set!,
		"roc_say": Host.say!,
		"roc_signal_get": Host.signal_get!,
		"roc_signal_latest": Host.signal_latest!,
		"roc_signal_new": Host.signal_new!,
		"roc_signal_set": Host.signal_set!,
		"roc_status": Host.status!,
		"roc_submission": Host.submission!,
		"roc_submission_clear": Host.submission_clear!,
		"roc_submission_drop": Host.submission_drop!,
		"roc_submission_retry": Host.submission_retry!,
		"roc_submissions": Host.submissions!,
		"roc_submit": Host.submit!,
		"roc_subscribe": Host.subscribe!,
		"roc_timeout": Host.timeout!,
		"roc_title": Host.title!,
		"roc_tracking": Host.tracking!,
		"roc_untrack": Host.untrack!,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			output: Shared,
			exports: ["mount", "run", "release", "result_ptr", "result_len", "live_allocations", "allocations", "frame_begin", "frame_end", "frame_unwound", "reclaim"],
			initial_stack_size: 1048576,
		},
	}

import Host
import Html
import Browser
import Solid
import Store
import Show
import Switch
import Match
import For
import Repeat
import Loading
import Errored
import Call
import Channel
import Server
import Context
import Endpoint
import Middleware
import Events
import OpenApi
import Router
import HttpStatusCode
import Transition
import Submission
import Submissions
import Time
import Title

## The app's markup, its holes registered with the runtime, as JSON (`Html.serialize!`).
mount_for_host! : {} => Str
mount_for_host! = |{}| Html.serialize!(main!({}))

## Runs a computation, a handler or a fallback the runtime keeps; its answer as JSON.
run_for_host! : Box(() => Str) => Str
run_for_host! = |runner| {
	run = Box.unbox(runner)
	run()
}
