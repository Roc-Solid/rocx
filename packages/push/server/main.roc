## Push on the server platform: subscribing, sending and the job that delivers (`Push`), and the
## subscriptions' table (`PushStore`). A package that names the server platform, so that
## `roc check packages/push/server/main.roc` checks these modules on their own. An app copies them
## in by hand for now: see ../README.md, "Setting up", and PROPOSALS.md.
package [Push, PushStore] { jobs: "../../jobs/main.roc", pf: platform "../../../server/platform/main.roc", push: "../main.roc" }
