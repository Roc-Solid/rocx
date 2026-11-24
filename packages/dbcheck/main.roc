## dbcheck: an app's rows checked against what its database says of each statement, when the app
## is compiled (D-058). `rocx check --sql` writes a small app of its own (build/sql/check/main.roc) with a
## line for each `Db.all!` whose row type it can name: a `DbCheck.Rows(T, Tags)`, its string what
## the app's database engine said of the statement's columns. Its `from_quote` runs at compile time,
## reads `T`'s shape through its parser (a format that reads nothing: `Probe`) and refuses a field
## the statement doesn't return, a type the column's values can't decode into, and a plain field
## over a column that may be null. Plain Roc, on no platform. See README.md.
package [DbCheck, Probe] {}
