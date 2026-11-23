//! D-058's check of an app's SQL (`--describe-sql`): the app's own database engine says what each
//! statement is, on a database built from the program's migrations. The platform's start runs as
//! it always does (its migrations, the plugins', the app's), but the database it opens is a
//! scratch one of the app's kind: a fresh SQLite or Turso file in a directory of its own under the
//! system's temporary directory, or a Postgres database made on the server the app's URL names. Or
//! the database named for checking (`--sql-database`), as it is: the check never migrates a
//! database nobody named for it, since the app's own URL may be something real. Then each
//! statement is prepared, never run, and described: its parameters, and each column's name, type,
//! the table column it comes from and whether that is `not null`; or the engine's error. What the
//! check made goes when it ends (`finish`).
//!
//! A column's `kind` is how the host reads its values into JSON (`postgres::read`,
//! `sqlite::read`), which is what Roc's decoder will meet: `integer`, `real`, `text`, `boolean`,
//! `json`, `any` (SQLite stores whatever was written: a declared type with no affinity of its own,
//! `numeric`, `date`), `blob` and `unreadable` (what the host refuses to read), or none, for an
//! expression SQLite doesn't type.

use super::{Client, postgres, sqlite, turso};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

/// Set when the check starts: the database named for it (`--sql-database`), if any.
static CHECKING: OnceLock<Option<String>> = OnceLock::new();

/// What the check made, to be removed when it ends.
static MADE: Mutex<Option<Made>> = Mutex::new(None);

enum Made {
    /// A SQLite or Turso file's directory, with the file's log beside it.
    Dir(PathBuf),
    /// A Postgres database, on the server `server` (a URL) names.
    Postgres { server: String, name: String },
}

/// The server is checking, not serving: the database it opens is a scratch one, or `named`.
pub fn start(named: Option<String>) {
    let _ = CHECKING.set(named);
}

pub fn active() -> bool {
    CHECKING.get().is_some()
}

/// Where the check opens the app's database instead of at `url`: at `url` itself only when it is
/// the database named for checking; else at a scratch one of the same kind, made now.
pub async fn scratch_for(url: &str) -> Result<String, String> {
    if CHECKING.get().is_some_and(|named| named.as_deref() == Some(url)) {
        return Ok(url.to_string());
    }
    let stamp = format!("{}_{}", std::process::id(), nanos());
    if url.starts_with("postgres://") || url.starts_with("postgresql://") {
        let name = format!("rocx_check_{stamp}");
        postgres::create_database(url, &name).await.map_err(|why| {
            format!(
                "the check can't make a scratch database on the Postgres server the app's URL (--database-url, DATABASE_URL) names ({why}): grant its user CREATEDB, or name a database the check may migrate with --sql-database URL (ROCX_SQL_DATABASE)"
            )
        })?;
        let scratch = postgres::with_database(url, &name)?;
        *MADE.lock().unwrap() = Some(Made::Postgres { server: url.to_string(), name });
        return Ok(scratch);
    }
    let Some((scheme, rest)) = url.split_once(':') else { return Err(format!("the check can't make a database like `{url}`")) };
    let dir = std::env::temp_dir().join(format!("rocx-check-{stamp}"));
    std::fs::create_dir_all(&dir).map_err(|error| format!("the check's scratch directory {}: {error}", dir.display()))?;
    *MADE.lock().unwrap() = Some(Made::Dir(dir.clone()));
    let mode = if rest.ends_with("?mvcc=off") { "?mvcc=off" } else { "" };
    Ok(format!("{scheme}:{}{mode}", dir.join("check.db").display()))
}

/// Removes what the check made: the scratch file's directory, or the scratch Postgres database
/// (its connections ended with it).
pub async fn finish() {
    let made = MADE.lock().unwrap().take();
    match made {
        Some(Made::Dir(dir)) => {
            let _ = std::fs::remove_dir_all(dir);
        }
        Some(Made::Postgres { server, name }) => {
            if let Err(why) = postgres::drop_database(&server, &name).await {
                crate::logging::warn(&format!("rocx server: the check's scratch database {name} stays: {why}"), &[]);
            }
        }
        None => {}
    }
}

/// What the database says of `sql`, prepared and not run: `{ "params": ["$1", …], "columns": […] }`,
/// or `{ "error": … }`.
pub async fn describe(sql: &str) -> Value {
    let described = match super::client().await {
        Ok(Client::Postgres(client)) => postgres::describe(&client, sql).await,
        Ok(Client::Sqlite(client)) => sqlite::describe(&client, sql).await,
        Ok(Client::Turso(client)) => turso::describe(&client, sql).await,
        Err(why) => Err(why),
    };
    described.unwrap_or_else(|why| json!({ "error": why }))
}

/// A column, as `describe` writes it.
pub struct Column {
    pub name: String,
    /// Its type as the database names it: Postgres's always, SQLite's and Turso's declared type
    /// when it comes straight from a table column.
    pub declared: Option<String>,
    pub kind: Option<&'static str>,
    /// The table column it comes from, and whether that is `not null` (a primary key counts).
    pub origin: Option<(String, String, bool)>,
}

impl Column {
    pub fn json(self) -> Value {
        let (table, column, not_null) = match self.origin {
            Some((table, column, not_null)) => (Value::from(table), Value::from(column), Value::from(not_null)),
            None => (Value::Null, Value::Null, Value::Null),
        };
        json!({ "name": self.name, "type": self.declared, "kind": self.kind, "table": table, "column": column, "not_null": not_null })
    }
}

/// A SQLite or Turso column's kind, from its declared type, as `sqlite::read` reads its values: a
/// `boolean` a boolean and a `json` its JSON, as the host's own rule says; then SQLite's affinity
/// (an `INT` in the name an integer; `CHAR`, `CLOB` or `TEXT` text; `BLOB` a blob; `REAL`, `FLOA`
/// or `DOUB` a real; anything else numeric, which stores whatever was written).
pub fn sqlite_kind(declared: Option<&str>) -> Option<&'static str> {
    let declared = declared?.to_ascii_lowercase();
    Some(match declared.as_str() {
        "boolean" | "bool" => "boolean",
        "json" | "jsonb" => "json",
        _ if declared.contains("int") => "integer",
        _ if declared.contains("char") || declared.contains("clob") || declared.contains("text") => "text",
        _ if declared.contains("blob") => "blob",
        _ if declared.contains("real") || declared.contains("floa") || declared.contains("doub") => "real",
        _ => "any",
    })
}

/// The scratch's names: unique to the process and the moment.
fn nanos() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|now| now.as_nanos()).unwrap_or(0)
}
