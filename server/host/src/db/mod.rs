//! The app's database, for `Db` (`server/platform/Db.roc`): Postgres (`postgres`), SQLite
//! (`sqlite`, D-045) or Turso (`turso`, D-046: SQLite's SQL, Turso's engine), as its program says. The platform's start opens it (`open`) at the URL it
//! works out from the program and `--database-url`; an app with none has no database, and every
//! statement says so. The rest is the same for both: statements whose parameters arrive as JSON
//! (text, an integer, a boolean or null) and whose rows leave as JSON, an array of objects, each
//! column by its name, for Roc to decode into records; and a call that begins a transaction keeps a
//! connection (`Client`) until it commits or rolls back, its statements going there. A transaction
//! begun inside it is a level of it, a savepoint (`savepoint`, `release`, `rollback_to`, D-076).
//!
//! A backend is a module here with the same functions (`connect` or `open`, `client`, `query`,
//! `execute`, `script`, `begin`, `commit`, `rollback`, `abandon`, `listen`), and a scheme in `open`.

pub mod check;
#[cfg(feature = "postgres")]
mod postgres;
mod sqlite;
#[cfg(feature = "turso")]
mod turso;

use serde_json::Value;
use std::sync::OnceLock;

/// What a statement says when the server has no database.
pub const NONE: &str = "no database: the app's program says `database: Postgres`, and the server wasn't started with --database-url (or DATABASE_URL)";

/// Which database the server opened.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Flavor {
    Postgres,
    Sqlite,
    Turso,
}

impl Flavor {
    /// As Roc reads it (`Db.engine!`; `Db.backend!` reads "turso" as SQLite, its SQL).
    pub fn name(self) -> &'static str {
        match self {
            Flavor::Postgres => "postgres",
            Flavor::Sqlite => "sqlite",
            Flavor::Turso => "turso",
        }
    }

    /// Whether it is a file in the server's process (SQLite, Turso), whose notices the host keeps
    /// itself, not a server of its own.
    pub fn in_process(self) -> bool {
        matches!(self, Flavor::Sqlite | Flavor::Turso)
    }
}

static OPENED: OnceLock<Flavor> = OnceLock::new();

/// The database the server opened, if it has one.
pub fn flavor() -> Option<Flavor> {
    OPENED.get().copied()
}

/// Opens the database at `url`: `postgres://…` (or `postgresql://…`), its pool and the connection
/// that listens; or `sqlite:<path>` or `turso:<path>`, a file (made, with its directory, when
/// missing): Turso's in MVCC mode, its writes going on at once (D-049), unless the URL ends
/// `?mvcc=off`.
pub async fn open(url: &str) -> Result<Flavor, String> {
    if OPENED.get().is_some() {
        return Err("the database is open already".into());
    }
    // Checking (D-058): a scratch database of the same kind, or the one named for the check.
    let scratch = if check::active() { Some(check::scratch_for(url).await?) } else { None };
    let url = scratch.as_deref().unwrap_or(url);
    let flavor = if url.starts_with("postgres://") || url.starts_with("postgresql://") {
        open_postgres(url).await?
    } else if let Some(path) = url.strip_prefix("sqlite:") {
        sqlite::open(path.strip_prefix("//").unwrap_or(path)).await?;
        Flavor::Sqlite
    } else if let Some(path) = url.strip_prefix("turso:") {
        let path = path.strip_prefix("//").unwrap_or(path);
        let (path, mvcc) = match path.strip_suffix("?mvcc=off") {
            Some(path) => (path, false),
            None => (path, true),
        };
        open_turso(path, mvcc).await?
    } else {
        return Err(format!("database url `{}`: neither postgres://…, sqlite:<path> nor turso:<path>", scheme_only(url)));
    };
    OPENED.set(flavor).map_err(|_| "the database is open already".to_string())?;
    Ok(flavor)
}

#[cfg(feature = "postgres")]
async fn open_postgres(url: &str) -> Result<Flavor, String> {
    postgres::connect(url)?;
    postgres::start_listening(url).await?;
    Ok(Flavor::Postgres)
}

#[cfg(not(feature = "postgres"))]
async fn open_postgres(_url: &str) -> Result<Flavor, String> {
    Err(left_out(Flavor::Postgres))
}

#[cfg(feature = "turso")]
async fn open_turso(path: &str, mvcc: bool) -> Result<Flavor, String> {
    turso::open(path, mvcc).await?;
    Ok(Flavor::Turso)
}

#[cfg(not(feature = "turso"))]
async fn open_turso(_path: &str, _mvcc: bool) -> Result<Flavor, String> {
    Err(left_out(Flavor::Turso))
}

/// What opening a database this host was built without says (D-104).
#[allow(dead_code)]
fn left_out(flavor: Flavor) -> String {
    let (engine, said) = match flavor {
        Flavor::Postgres => ("Postgres", "database: Postgres"),
        Flavor::Sqlite => ("SQLite", "database: Sqlite(path)"),
        Flavor::Turso => ("Turso", "database: Turso(path)"),
    };
    format!("this server was built without {engine}: `rocx build --release` and `--image` build in the engine the app's program names alone, so say `{said}` in the program to have it")
}

/// A URL's scheme alone, for a message: its password stays out of the log.
fn scheme_only(url: &str) -> String {
    match url.split_once(':') {
        Some((scheme, _)) => format!("{scheme}:…"),
        None => "…".into(),
    }
}

/// A connection, kept while it is out: given back when dropped.
pub enum Client {
    #[cfg(feature = "postgres")]
    Postgres(postgres::Client),
    Sqlite(sqlite::Client),
    #[cfg(feature = "turso")]
    Turso(turso::Client),
}

pub async fn client() -> Result<Client, String> {
    match flavor() {
        #[cfg(feature = "postgres")]
        Some(Flavor::Postgres) => postgres::client().await.map(Client::Postgres),
        Some(Flavor::Sqlite) => sqlite::client().await.map(Client::Sqlite),
        #[cfg(feature = "turso")]
        Some(Flavor::Turso) => turso::client().await.map(Client::Turso),
        #[allow(unreachable_patterns)]
        Some(flavor) => Err(left_out(flavor)),
        None => Err(NONE.into()),
    }
}

/// A parameter as Roc gave it (`Db.Value`).
#[derive(Debug, Clone)]
pub enum Param {
    Null,
    Text(String),
    Int(i64),
    Bool(bool),
}

/// The parameters, from the JSON array `Db` sends: text, an integer, a boolean or null.
fn parameters(json: &str) -> Result<Vec<Param>, String> {
    let Value::Array(items) = serde_json::from_str(json).map_err(|error| format!("parameters: {error}"))? else {
        return Err("parameters: not a list".into());
    };
    items
        .into_iter()
        .map(|item| match item {
            Value::String(text) => Ok(Param::Text(text)),
            Value::Null => Ok(Param::Null),
            Value::Bool(yes) => Ok(Param::Bool(yes)),
            Value::Number(number) => number.as_i64().map(Param::Int).ok_or_else(|| format!("parameters: {number} isn't an I64")),
            other => Err(format!("parameters: {other} is neither text, an integer, a boolean nor null")),
        })
        .collect()
}

/// The rows `sql` reads, as a JSON array of objects, each column by its name: a null is `null`,
/// anything else its value. Whether a column may be null is the reader's to say, in the record it
/// decodes a row into (`Db.Nullable(a)`), not the host's to look up.
pub async fn query(client: &Client, sql: &str, params: &str) -> Result<String, String> {
    let params = parameters(params)?;
    match client {
        #[cfg(feature = "postgres")]
        Client::Postgres(client) => postgres::query(client, sql, &params).await,
        Client::Sqlite(client) => sqlite::query(client, sql, params).await,
        #[cfg(feature = "turso")]
        Client::Turso(client) => turso::query(client, sql, params).await,
    }
}

/// How many rows `sql` changed (or, for a statement that only reads, read).
pub async fn execute(client: &Client, sql: &str, params: &str) -> Result<u64, String> {
    let params = parameters(params)?;
    match client {
        #[cfg(feature = "postgres")]
        Client::Postgres(client) => postgres::execute(client, sql, &params).await,
        Client::Sqlite(client) => sqlite::execute(client, sql, params).await,
        #[cfg(feature = "turso")]
        Client::Turso(client) => turso::execute(client, sql, params).await,
    }
}

/// Runs `sql`'s statements, with no parameters: in the call's transaction (`in_transaction`), or in
/// a transaction of their own.
pub async fn script(client: &Client, in_transaction: bool, sql: &str) -> Result<(), String> {
    match client {
        #[cfg(feature = "postgres")]
        Client::Postgres(client) => postgres::script(client, in_transaction, sql).await,
        Client::Sqlite(client) => sqlite::script(client, in_transaction, sql).await,
        #[cfg(feature = "turso")]
        Client::Turso(client) => turso::script(client, in_transaction, sql).await,
    }
}

/// Lets go of a connection cut off in the middle of a statement (a job past its time limit): the
/// statement is cancelled, and the connection closed, never given back to the pool, so no one
/// else's statement waits behind it, and a transaction open on it ends with it. Returns at once.
#[cfg_attr(not(feature = "postgres"), allow(unused_variables))]
pub fn abandon(client: Client, runtime: &tokio::runtime::Handle) {
    match client {
        #[cfg(feature = "postgres")]
        Client::Postgres(client) => postgres::abandon(client, runtime),
        Client::Sqlite(client) => sqlite::abandon(client),
        #[cfg(feature = "turso")]
        Client::Turso(client) => turso::abandon(client),
    }
}

/// Begins a transaction on `client`, which the call that asked keeps until it ends: on Turso a
/// concurrent one, unless it is to be `exclusive` (it changes the schema: `is_exclusive`).
#[cfg_attr(not(feature = "turso"), allow(unused_variables))]
pub async fn begin(client: &Client, exclusive: bool) -> Result<(), String> {
    match client {
        #[cfg(feature = "postgres")]
        Client::Postgres(client) => postgres::begin(client).await,
        Client::Sqlite(client) => sqlite::begin(client).await,
        #[cfg(feature = "turso")]
        Client::Turso(client) => turso::begin(client, exclusive).await,
    }
}

/// Whether a statement's failure is a conflict (Turso's MVCC, D-049): another transaction wrote the
/// same row first, so this one rolls back, and `Db.transaction!` runs its body again.
pub fn is_conflict(why: &str) -> bool {
    #[cfg(feature = "turso")]
    return why.starts_with(turso::CONFLICT);
    #[cfg(not(feature = "turso"))]
    return {
        let _ = why;
        false
    };
}

/// How long a transaction that lost to another's write `lost` times in a row waits before it runs
/// again: random (so the losers don't all come back at once), up to 1 ms, then 2, 4… 64 ms.
pub fn backoff(lost: u32) -> std::time::Duration {
    let ceiling_us = 1000u64 << lost.saturating_sub(1).min(6);
    let noise = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|now| now.subsec_nanos() as u64).unwrap_or(0);
    // A cheap scramble of the clock's nanoseconds (splitmix64's finish): random enough to spread
    // the losers out.
    let mut x = noise ^ (u64::from(lost) << 32) ^ 0x9e37_79b9_7f4a_7c15;
    x = (x ^ (x >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    x ^= x >> 31;
    std::time::Duration::from_micros(x % (ceiling_us + 1))
}

/// Whether a statement was refused for needing an exclusive transaction (a schema change in a
/// concurrent one, on Turso): the call's next transaction begins exclusive.
pub fn is_exclusive(why: &str) -> bool {
    #[cfg(feature = "turso")]
    return why.starts_with(turso::EXCLUSIVE);
    #[cfg(not(feature = "turso"))]
    return {
        let _ = why;
        false
    };
}

pub async fn commit(client: &Client) -> Result<(), String> {
    match client {
        #[cfg(feature = "postgres")]
        Client::Postgres(client) => postgres::commit(client).await,
        Client::Sqlite(client) => sqlite::commit(client).await,
        #[cfg(feature = "turso")]
        Client::Turso(client) => turso::commit(client).await,
    }
}

pub async fn rollback(client: &Client) {
    match client {
        #[cfg(feature = "postgres")]
        Client::Postgres(client) => postgres::rollback(client).await,
        Client::Sqlite(client) => sqlite::rollback(client).await,
        #[cfg(feature = "turso")]
        Client::Turso(client) => turso::rollback(client).await,
    }
}

/// Opens level `depth` (1, 2…) inside the transaction `client` has open (D-076): a savepoint,
/// `rocx_<depth>`, the same SQL on every backend.
pub async fn savepoint(client: &Client, depth: usize) -> Result<(), String> {
    script(client, true, &format!("savepoint rocx_{depth}")).await
}

/// Ends level `depth`, what it wrote now the level's around it.
pub async fn release(client: &Client, depth: usize) -> Result<(), String> {
    script(client, true, &format!("release savepoint rocx_{depth}")).await
}

/// Undoes what level `depth` wrote, and ends it: the level around it goes on (on Postgres, even
/// after a statement of the level failed).
pub async fn rollback_to(client: &Client, depth: usize) -> Result<(), String> {
    script(client, true, &format!("rollback to savepoint rocx_{depth}; release savepoint rocx_{depth}")).await
}

/// Postgres's `pg_notify` on `client`: delivered when its transaction commits, or at once. (On
/// SQLite and Turso the host keeps a call's notices itself: `hosted::roc_host_db_notify`.)
pub async fn notify(client: &Client, channel: &str, payload: &str) -> Result<(), String> {
    match client {
        #[cfg(feature = "postgres")]
        Client::Postgres(client) => postgres::notify(client, channel, payload).await,
        #[cfg(feature = "turso")]
        Client::Turso(_) => {
            crate::live::publish(&format!("db:{channel}"), payload);
            Ok(())
        }
        Client::Sqlite(_) => {
            crate::live::publish(&format!("db:{channel}"), payload);
            Ok(())
        }
    }
}

/// Listens to `channel`, if nothing has yet: on Postgres, its connection that listens is told; on
/// SQLite and Turso there is nothing to tell, as what is notified is published in the process.
#[cfg_attr(not(feature = "postgres"), allow(unused_variables))]
pub async fn listen(channel: &str) -> Result<(), String> {
    match flavor() {
        #[cfg(feature = "postgres")]
        Some(Flavor::Postgres) => postgres::listen(channel).await,
        #[cfg(not(feature = "postgres"))]
        Some(Flavor::Postgres) => Err(left_out(Flavor::Postgres)),
        Some(Flavor::Sqlite | Flavor::Turso) => Ok(()),
        None => Err(NONE.into()),
    }
}
