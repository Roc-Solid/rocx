//! SQLite, the database of an app whose program says `Sqlite(path)` (`db`, D-045): a file in the
//! server's process, with no network between a statement and its rows. A pool of connections, each
//! used by one call at a time on a thread of tokio's for blocking work (SQLite's calls block), so a
//! paused call holds no Roc thread. The file is in WAL mode: reads go on while one connection
//! writes, and writes take turns, each waiting up to `BUSY` for the one before to end. A transaction
//! begins `immediate`, taking the write lock at once, so two transactions never deadlock, each
//! waiting for the other to let its read go.
//!
//! A parameter is bound as what it is (text, an integer, a `Bool` as 1 or 0, null), at its name:
//! `$1`, `$2`… (as in Postgres), `?1`, or a bare `?` in turn. A row's columns are what each value is
//! (an integer or a real a number, text a string, null), a column declared `boolean` a JSON boolean
//! and one declared `json` its JSON.

use super::Param;
use rusqlite::types::{Value as Sql, ValueRef};
use rusqlite::{Connection, InterruptHandle, Statement};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

/// How many connections the pool keeps at most.
const CONNECTIONS: usize = 8;

/// How long a write waits for the one before it to end.
const BUSY: Duration = Duration::from_secs(10);

struct Pool {
    path: PathBuf,
    idle: Mutex<Vec<Conn>>,
    permits: Arc<Semaphore>,
}

static POOL: OnceLock<Pool> = OnceLock::new();

/// A connection, and the handle that stops what it is running (`abandon`).
struct Conn {
    connection: Arc<Mutex<Connection>>,
    interrupt: Arc<InterruptHandle>,
}

/// A connection from the pool, kept while it is out: given back when dropped, unless it was
/// abandoned or a transaction is still open on it (then it is closed, which rolls that back).
pub struct Client {
    conn: Option<Conn>,
    _permit: OwnedSemaphorePermit,
}

impl Drop for Client {
    fn drop(&mut self) {
        let Some(conn) = self.conn.take() else { return };
        let idle = conn.connection.try_lock().map(|connection| connection.is_autocommit()).unwrap_or(false);
        if idle && let Some(pool) = POOL.get() {
            pool.idle.lock().unwrap().push(conn);
        }
    }
}

/// Opens the file at `path` (made, with its directory, when missing), in WAL mode, and keeps it for
/// the pool's connections.
pub async fn open(path: &str) -> Result<(), String> {
    if path.is_empty() || path == ":memory:" || path.starts_with("file::memory:") {
        return Err("sqlite: an in-memory database isn't one the server's connections share: give a file".into());
    }
    let path = PathBuf::from(path);
    if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|error| format!("sqlite: {}: {error}", dir.display()))?;
    }
    let first = blocking({
        let path = path.clone();
        move || {
            let conn = connect(&path)?;
            let mode: String = conn.query_row("pragma journal_mode = wal", [], |row| row.get(0)).map_err(described)?;
            if !mode.eq_ignore_ascii_case("wal") {
                return Err(format!("sqlite: {}: WAL mode refused (it is {mode})", path.display()));
            }
            Ok(conn)
        }
    })
    .await?;
    let pool = Pool { path, idle: Mutex::new(vec![kept(first)]), permits: Arc::new(Semaphore::new(CONNECTIONS)) };
    POOL.set(pool).map_err(|_| "the database is open already".to_string())
}

/// A new connection to the file, set up as each is: its wait for writes, foreign keys checked.
fn connect(path: &Path) -> Result<Connection, String> {
    let conn = Connection::open(path).map_err(|error| format!("sqlite: {}: {}", path.display(), described(error)))?;
    conn.busy_timeout(BUSY).map_err(described)?;
    conn.execute_batch("pragma foreign_keys = on; pragma synchronous = normal;").map_err(described)?;
    conn.set_prepared_statement_cache_capacity(64);
    Ok(conn)
}

fn kept(connection: Connection) -> Conn {
    let interrupt = Arc::new(connection.get_interrupt_handle());
    Conn { connection: Arc::new(Mutex::new(connection)), interrupt }
}

pub async fn client() -> Result<Client, String> {
    let Some(pool) = POOL.get() else { return Err(super::NONE.into()) };
    let permit = pool.permits.clone().acquire_owned().await.map_err(|_| "sqlite: the pool is closed".to_string())?;
    let idle = pool.idle.lock().unwrap().pop();
    let conn = match idle {
        Some(conn) => conn,
        None => {
            let path = pool.path.clone();
            kept(blocking(move || connect(&path)).await?)
        }
    };
    Ok(Client { conn: Some(conn), _permit: permit })
}

/// Runs `work` on a thread for blocking work: SQLite's calls block.
async fn blocking<T: Send + 'static>(work: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    tokio::task::spawn_blocking(work).await.unwrap_or_else(|_| Err("sqlite: the statement panicked".into()))
}

/// Runs `work` with `client`'s connection, on a thread for blocking work.
async fn with<T: Send + 'static>(client: &Client, work: impl FnOnce(&Connection) -> Result<T, String> + Send + 'static) -> Result<T, String> {
    let Some(conn) = &client.conn else { return Err("sqlite: the connection was let go".into()) };
    let connection = conn.connection.clone();
    blocking(move || work(&connection.lock().unwrap())).await
}

/// SQLite's message, after the kind of failure when it has one (`ConstraintViolation: UNIQUE
/// constraint failed: items.name`).
pub fn described(error: rusqlite::Error) -> String {
    match error {
        rusqlite::Error::SqliteFailure(failure, Some(message)) if failure.code == rusqlite::ErrorCode::Unknown => message,
        rusqlite::Error::SqliteFailure(failure, Some(message)) => format!("{:?}: {message}", failure.code),
        other => other.to_string(),
    }
}

/// Binds `params` to `statement`'s parameters, each at its name: `$n` or `?n` is the n-th, a bare
/// `?` the next. A parameter the statement uses that wasn't given, or one given it doesn't use, is
/// an error, as it is in Postgres.
fn bind(statement: &mut Statement, params: &[Param]) -> Result<(), String> {
    let mut used = vec![false; params.len()];
    for index in 1..=statement.parameter_count() {
        let which = match statement.parameter_name(index) {
            None => index,
            Some(name) => match name.strip_prefix('$').or_else(|| name.strip_prefix('?')).and_then(|digits| digits.parse::<usize>().ok()) {
                Some(n) if n >= 1 => n,
                _ => return Err(format!("parameter `{name}`: name the parameters $1, $2, …")),
            },
        };
        let Some(param) = params.get(which - 1) else {
            let given = match params.len() {
                1 => "1 parameter was".to_string(),
                count => format!("{count} parameters were"),
            };
            return Err(format!("the statement uses ${which}, and {given} given"));
        };
        used[which - 1] = true;
        let value = match param {
            Param::Null => Sql::Null,
            Param::Text(text) => Sql::Text(text.clone()),
            Param::Int(number) => Sql::Integer(*number),
            Param::Bool(yes) => Sql::Integer(i64::from(*yes)),
        };
        statement.raw_bind_parameter(index, value).map_err(described)?;
    }
    match used.iter().position(|used| !used) {
        Some(unused) => Err(format!("parameter ${} was given, and the statement doesn't use it", unused + 1)),
        None => Ok(()),
    }
}

pub async fn query(client: &Client, sql: &str, params: Vec<Param>) -> Result<String, String> {
    let sql = sql.to_string();
    with(client, move |conn| {
        let mut statement = conn.prepare_cached(&sql).map_err(described)?;
        bind(&mut statement, &params)?;
        let mut columns = Vec::new();
        for column in statement.columns() {
            let name = column.name().to_string();
            if let Some(key) = name.strip_suffix('?').or_else(|| name.strip_suffix('!')) {
                return Err(format!(
                    "column `{name}`: a name doesn't say whether it may be null any more: call it `{key}`, and read it as `Db.Nullable(a)` if it may be"
                ));
            }
            let declared = column.decl_type().map(|declared| declared.to_ascii_lowercase());
            columns.push((name, declared));
        }
        let mut rows = statement.raw_query();
        let mut out = Vec::new();
        while let Some(row) = rows.next().map_err(described)? {
            let mut object = Map::new();
            for (index, (name, declared)) in columns.iter().enumerate() {
                let value = row.get_ref(index).map_err(described)?;
                object.insert(name.clone(), read(value, declared.as_deref(), name)?);
            }
            out.push(Value::Object(object));
        }
        Ok(Value::Array(out).to_string())
    })
    .await
}

/// A column's value as JSON, from what it is, and what its column was declared as.
fn read(value: ValueRef, declared: Option<&str>, name: &str) -> Result<Value, String> {
    Ok(match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(number) if matches!(declared, Some("boolean" | "bool")) => Value::Bool(number != 0),
        ValueRef::Integer(number) => Value::from(number),
        ValueRef::Real(number) => match serde_json::Number::from_f64(number) {
            Some(number) => Value::Number(number),
            None => return Err(format!("column `{name}` is {number}, which JSON has no number for")),
        },
        ValueRef::Text(bytes) => {
            let text = std::str::from_utf8(bytes).map_err(|_| format!("column `{name}` isn't UTF-8 text"))?;
            if matches!(declared, Some("json" | "jsonb")) {
                serde_json::from_str(text).map_err(|error| format!("column `{name}` is declared json, and isn't: {error}"))?
            } else {
                Value::from(text)
            }
        }
        ValueRef::Blob(_) => return Err(format!("column `{name}` is a blob, which Db can't read yet: read `hex({name})`")),
    })
}

pub async fn execute(client: &Client, sql: &str, params: Vec<Param>) -> Result<u64, String> {
    let sql = sql.to_string();
    with(client, move |conn| {
        let mut statement = conn.prepare_cached(&sql).map_err(described)?;
        bind(&mut statement, &params)?;
        let reads = statement.readonly();
        let before = conn.total_changes();
        let mut rows = statement.raw_query();
        let mut read = 0u64;
        while rows.next().map_err(described)?.is_some() {
            read += 1;
        }
        drop(rows);
        // What it changed (an `insert … returning` too), not counting a trigger's; a statement that
        // changes nothing (a `create table`) is 0, not the last one's count.
        Ok(if reads { read } else if conn.total_changes() == before { 0 } else { conn.changes() })
    })
    .await
}

pub async fn script(client: &Client, in_transaction: bool, sql: &str) -> Result<(), String> {
    let sql = sql.to_string();
    with(client, move |conn| {
        if in_transaction {
            return conn.execute_batch(&sql).map_err(described);
        }
        conn.execute_batch("begin immediate").map_err(described)?;
        if let Err(error) = conn.execute_batch(&sql) {
            let _ = conn.execute_batch("rollback");
            return Err(described(error));
        }
        conn.execute_batch("commit").map_err(described)
    })
    .await
}

/// Stops what `client` is running (`sqlite3_interrupt`), and closes it once that has stopped,
/// rolling back a transaction open on it; never given back to the pool.
pub fn abandon(mut client: Client) {
    if let Some(conn) = client.conn.take() {
        conn.interrupt.interrupt();
    }
}

pub async fn begin(client: &Client) -> Result<(), String> {
    with(client, |conn| conn.execute_batch("begin immediate").map_err(described)).await
}

pub async fn commit(client: &Client) -> Result<(), String> {
    with(client, |conn| conn.execute_batch("commit").map_err(described)).await
}

pub async fn rollback(client: &Client) {
    let _ = with(client, |conn| {
        if !conn.is_autocommit() {
            conn.execute_batch("rollback").map_err(described)?;
        }
        Ok(())
    })
    .await;
}
