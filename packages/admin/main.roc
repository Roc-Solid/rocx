## Admin: pages for a Roc Solid app's admins.
##
## - A Django-style admin for the app's Postgres tables. It reads the tables from Postgres's
##   catalog when a page is asked for (`Catalog`), builds every statement from the catalog's names
##   and parameters (`Sql`), chooses each column's widget from its type (`Widget`), lists rows with a
##   search, filters, a sort and pages done in Postgres (`Listing`, `Paging`), and draws its pages
##   (`View`, `Look`). The app says which tables and how (`Admin`), and answers a route with
##   `AdminPage.respond!`, handing it `Db.all!`, `Db.run!` and `Random.bytes!`.
## - The jobs page (`JobsPage`): packages/jobs's queue, its kinds and schedules, as a console.
## - Their look (`AdminHtml`): whole pages in the shape of a console, which the dev mailbox shares.
##
## It names the server platform, for the jobs page; the browser's half sees the modules both halves
## can compile (`browser.roc`). See README.md.
package [Admin, AdminHtml, AdminPage, Catalog, Form, JobsPage, Listing, Look, Paging, Sql, View, Widget] { jobs: "../jobs/main.roc", pf: platform "../../server/platform/main.roc" }
