## Admin: a Django-style admin for a Roc Solid app's Postgres tables. It reads the tables from
## Postgres's catalog when a page is asked for (`Catalog`), builds every statement from the
## catalog's names and parameters (`Sql`), chooses each column's widget from its type (`Widget`),
## lists rows with a search, filters, a sort and pages done in Postgres (`Listing`, `Paging`), and
## draws its pages as the platform's jobs page is drawn (`View`, `Look`). The app says which tables
## and how (`Admin`), and answers a route with `AdminPage.respond!`, handing it the server
## platform's `Db.all!`, `Db.run!` and `Random.bytes!`, since a package can't import a platform's
## modules for both of an app's halves. See README.md.
package [Admin, AdminPage, Catalog, Form, Listing, Look, Paging, Sql, View, Widget] {}
