//! Turso, the database of an app whose program says `Turso(path)` (`db`, D-046): Turso's engine
//! (`turso_core`), SQLite written again in Rust, in the server's process, a file in SQLite's
//! format. Its SQL is SQLite's, so the app's, a package's and a plugin's SQL for SQLite runs here,
//! and much is as `sqlite.rs` has it: a pool of connections, each used by one call at a time on a
//! thread of tokio's for blocking work, reads going on while others write.
//!
//! Writes go on at once (D-049): the file is in Turso's MVCC mode, and a transaction begins
//! `concurrent`, each on its own snapshot, Turso refusing the later of two that write the same row
//! (a conflict: `Conflict: …`, which `Db.transaction!` answers by running its body again,
//! `hosted.rs` noting it). A write outside a transaction (an insert, an update, a delete) runs in a
//! concurrent transaction of its own, begun again here on a conflict (after a random pause, longer
//! each time), up to `TRIES` times. What changes the schema needs a transaction of its own
//! (`exclusive`, as SQLite's `immediate`, which the others wait for): a migration is one, and a
//! statement refused in a concurrent one says so (`Exclusive: …`), so the call's next transaction
//! begins exclusive. `turso:<path>?mvcc=off` keeps
//! the file in WAL mode, where writes take turns as on SQLite.
//!
//! A statement runs in steps: a row, its end, or what it waits for. Its file's reads and writes are
//! done as they are asked (the engine's `step` of its IO drives any left); a lock another
//! connection holds comes back as a delay before trying again, which the thread sleeps (Turso's own
//! loops spin through it). Each connection keeps its statements prepared, by their SQL.
//!
//! Unlike SQLite, Turso keeps the file to this process while the server runs (an OS lock on it):
//! no other program (`sqlite3`, `node:sqlite`) opens it until the server stops.
//!
//! Parameters and rows as in `sqlite.rs`: a parameter bound as what it is (text, an integer, a
//! `Bool` as 1 or 0, null), at its name (`$1`, `?1`, or a bare `?` in turn); a row's columns what
//! each value is, a column declared `boolean` a JSON boolean and one declared `json` its JSON.

use super::Param;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::num::NonZero;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use turso_core::{
    Connection, Database, DatabaseOpts, LimboError, Numeric, OpenFlags, PlatformIO, PreparedProgram, Program, QueryMode, SqliteDialect,
    Statement, StepResult, Value as Sql,
};

/// How many connections the pool keeps at most.
const CONNECTIONS: usize = 8;

/// How long a write waits for the one before it to end.
const BUSY: Duration = Duration::from_secs(10);

/// How many prepared statements a connection keeps.
const PREPARED: usize = 64;

/// How many times a write outside a transaction is begun again after a conflict.
const TRIES: usize = 100;

/// What a conflict's message starts with: `Db.transaction!` runs its body again (`super::is_conflict`).
pub const CONFLICT: &str = "Conflict: ";

/// What a statement that needs an exclusive transaction says, refused in a concurrent one.
pub const EXCLUSIVE: &str = "Exclusive: ";

struct Pool {
    database: Arc<Database>,
    /// Whether the file is in MVCC mode, its writes going on at once.
    mvcc: bool,
    idle: Mutex<Vec<Conn>>,
    permits: Arc<Semaphore>,
}

static POOL: OnceLock<Pool> = OnceLock::new();

/// The statements a connection has prepared, by their SQL.
type Prepared = HashMap<String, (Arc<PreparedProgram>, QueryMode)>;

/// A connection, and its prepared statements: their lock is held while a statement runs on it, so
/// a connection still running one (its call cut off) is never given back to the pool.
#[derive(Clone)]
struct Conn {
    connection: Arc<Connection>,
    prepared: Arc<Mutex<Prepared>>,
}

/// A connection from the pool, kept while it is out: given back when dropped, unless it was
/// abandoned, is still running a statement, or has a transaction open (then it is closed, which
/// rolls that back).
pub struct Client {
    conn: Option<Conn>,
    _permit: OwnedSemaphorePermit,
}

impl Drop for Client {
    fn drop(&mut self) {
        let Some(conn) = self.conn.take() else { return };
        let idle = conn.prepared.try_lock().is_ok() && conn.connection.get_auto_commit();
        if idle && let Some(pool) = POOL.get() {
            pool.idle.lock().unwrap().push(conn);
        }
    }
}

/// Opens the file at `path` (made, with its directory, when missing), in MVCC mode (`mvcc`) or WAL
/// mode, and keeps it for the pool's connections.
pub async fn open(path: &str, mvcc: bool) -> Result<(), String> {
    if path.is_empty() || path == ":memory:" || path.starts_with("file::memory:") {
        return Err("turso: an in-memory database isn't one the server's connections share: give a file".into());
    }
    let path = PathBuf::from(path);
    if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|error| format!("turso: {}: {error}", dir.display()))?;
    }
    let (database, first) = blocking({
        let path = path.clone();
        move || {
            let shown = path.display().to_string();
            let name = path.to_str().ok_or_else(|| format!("turso: {shown}: the path isn't UTF-8"))?;
            let io = Arc::new(PlatformIO::new().map_err(|error| format!("turso: {shown}: {error}"))?);
            let database = Database::open_file_with_flags(io, name, OpenFlags::default(), DatabaseOpts::new(), None, Arc::new(SqliteDialect))
                .map_err(|error| format!("turso: {shown}: {}", described(error)))?;
            let conn = connect(&database)?;
            let wanted = if mvcc { "mvcc" } else { "wal" };
            let mut mode = text_of(&conn, "pragma journal_mode")?;
            if !mode.eq_ignore_ascii_case(wanted) {
                mode = text_of(&conn, &format!("pragma journal_mode = '{wanted}'"))?;
            }
            if !mode.eq_ignore_ascii_case(wanted) {
                return Err(format!("turso: {shown}: {wanted} mode refused (it is {mode})"));
            }
            Ok((database, conn))
        }
    })
    .await?;
    let pool = Pool { database, mvcc, idle: Mutex::new(vec![first]), permits: Arc::new(Semaphore::new(CONNECTIONS)) };
    POOL.set(pool).map_err(|_| "the database is open already".to_string())
}

/// A new connection, set up as each is: its wait for writes, foreign keys checked.
fn connect(database: &Arc<Database>) -> Result<Conn, String> {
    let connection = database.connect().map_err(described)?;
    connection.set_busy_timeout(BUSY);
    let conn = Conn { connection, prepared: Arc::new(Mutex::new(HashMap::new())) };
    batch(&conn.connection, "pragma foreign_keys = on; pragma synchronous = normal;")?;
    Ok(conn)
}

/// The first column of the first row `sql` reads, as text.
fn text_of(conn: &Conn, sql: &str) -> Result<String, String> {
    let mut statement = conn.connection.prepare(sql).map_err(described)?;
    if !step(&mut statement)? {
        return Err(format!("`{sql}` read nothing"));
    }
    let row = statement.row().ok_or("no row")?;
    Ok(row.get_value(0).to_text().unwrap_or_default().to_string())
}

pub async fn client() -> Result<Client, String> {
    let Some(pool) = POOL.get() else { return Err(super::NONE.into()) };
    let permit = pool.permits.clone().acquire_owned().await.map_err(|_| "turso: the pool is closed".to_string())?;
    let idle = pool.idle.lock().unwrap().pop();
    let conn = match idle {
        Some(conn) => conn,
        None => {
            let database = pool.database.clone();
            blocking(move || connect(&database)).await?
        }
    };
    Ok(Client { conn: Some(conn), _permit: permit })
}

/// Runs `work` on a thread for blocking work: a statement's steps block.
async fn blocking<T: Send + 'static>(work: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    tokio::task::spawn_blocking(work).await.unwrap_or_else(|_| Err("turso: the statement panicked".into()))
}

/// Runs `work` with `client`'s connection and its prepared statements, on a thread for blocking
/// work.
async fn with<T: Send + 'static>(client: &Client, work: impl FnOnce(&Arc<Connection>, &mut Prepared) -> Result<T, String> + Send + 'static) -> Result<T, String> {
    let Some(conn) = client.conn.clone() else { return Err("turso: the connection was let go".into()) };
    blocking(move || {
        let mut prepared = conn.prepared.lock().unwrap();
        work(&conn.connection, &mut prepared)
    })
    .await
}

/// Turso's message, after the kind of failure as SQLite's (`sqlite.rs`) says it, when it has one
/// (`ConstraintViolation: UNIQUE constraint failed: items.name`); a conflict after `CONFLICT`, and
/// a statement that needs an exclusive transaction after `EXCLUSIVE`.
pub fn described(error: LimboError) -> String {
    match error {
        LimboError::WriteWriteConflict => format!("{CONFLICT}another transaction wrote the same row first"),
        LimboError::BusySnapshot => format!("{CONFLICT}another transaction committed since this one began"),
        LimboError::CommitDependencyAborted => format!("{CONFLICT}a transaction this one read from rolled back"),
        LimboError::TxTerminated => format!("{CONFLICT}the transaction was ended by a conflict"),
        LimboError::Conflict(message) => format!("{CONFLICT}{message}"),
        LimboError::TxError(message) if message.starts_with("DDL statements require an exclusive transaction") => {
            format!("{EXCLUSIVE}a statement that changes the schema needs a transaction of its own")
        }
        LimboError::Constraint(message) | LimboError::ForeignKeyConstraint(message) => format!("ConstraintViolation: {message}"),
        LimboError::Busy | LimboError::TableLocked => "DatabaseBusy: database is locked".into(),
        LimboError::Interrupt => "OperationInterrupted: interrupted".into(),
        LimboError::ReadOnly => "ReadOnly: attempt to write a readonly database".into(),
        LimboError::DatabaseFull => "DiskFull: database or disk is full".into(),
        other => other.to_string(),
    }
}

/// The next step of `statement`: a row (`true`) or its end (`false`). What it waits for is done
/// here: its IO (the platform's reads and writes are done as they are asked; the engine's `step`
/// drives any left), and the delay before trying a lock again, slept.
fn step(statement: &mut Statement) -> Result<bool, String> {
    loop {
        match statement.step().map_err(described)? {
            StepResult::Row => return Ok(true),
            StepResult::Done => return Ok(false),
            StepResult::IO | StepResult::Yield => statement._io().step().map_err(described)?,
            StepResult::Sleep { duration } => std::thread::sleep(duration),
            StepResult::Busy => return Err(described(LimboError::Busy)),
            StepResult::Interrupt => return Err(described(LimboError::Interrupt)),
        }
    }
}

/// `sql`'s statements, one after another, each prepared as the one before has run (a table made,
/// then written), their rows read and let go.
fn batch(connection: &Arc<Connection>, sql: &str) -> Result<(), String> {
    let mut rest = sql;
    while let Some((mut statement, end)) = connection.consume_stmt(rest).map_err(described)? {
        while step(&mut statement)? {}
        rest = &rest[end..];
    }
    Ok(())
}

/// `sql` prepared on `connection`: from what it prepared before, when it still fits (its schema
/// unchanged), or prepared now and kept.
fn prepared(connection: &Arc<Connection>, cache: &mut Prepared, sql: &str) -> Result<Statement, String> {
    if let Some((program, mode)) = cache.get(sql)
        && program.is_compatible_with(connection)
    {
        let program = Program::from_prepared(program.clone(), connection.clone());
        return Ok(Statement::new(program, connection.get_pager(), *mode, 0));
    }
    let statement = connection.prepare(sql).map_err(described)?;
    if cache.len() >= PREPARED {
        cache.clear();
    }
    cache.insert(sql.to_string(), (statement.get_program().prepared().clone(), statement.get_query_mode()));
    Ok(statement)
}

/// Binds `params` to `statement`'s parameters, each at its name: `$n` or `?n` is the n-th, a bare
/// `?` the next. A parameter the statement uses that wasn't given, or one given it doesn't use, is
/// an error, as it is in Postgres.
fn bind(statement: &mut Statement, params: &[Param]) -> Result<(), String> {
    let mut used = vec![false; params.len()];
    for index in 1..=statement.parameters_count() {
        let slot = NonZero::new(index).ok_or("parameter 0")?;
        let which = match statement.parameters().name(slot) {
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
            Param::Text(text) => Sql::build_text(text.clone()),
            Param::Int(number) => Sql::from_i64(*number),
            Param::Bool(yes) => Sql::from_i64(i64::from(*yes)),
        };
        statement.bind_at(slot, value).map_err(described)?;
    }
    match used.iter().position(|used| !used) {
        Some(unused) => Err(format!("parameter ${} was given, and the statement doesn't use it", unused + 1)),
        None => Ok(()),
    }
}

pub async fn query(client: &Client, sql: &str, params: Vec<Param>) -> Result<String, String> {
    let sql = sql.to_string();
    with(client, move |connection, cache| alone(connection, &sql, || rows(connection, cache, &sql, &params))).await
}

/// The rows `sql` reads (or an `insert … returning` gives), as `query` answers them.
fn rows(connection: &Arc<Connection>, cache: &mut Prepared, sql: &str, params: &[Param]) -> Result<String, String> {
    let mut statement = prepared(connection, cache, sql)?;
    bind(&mut statement, params)?;
    let mut columns = Vec::new();
    for index in 0..statement.num_columns() {
        let name = statement.get_column_name(index).into_owned();
        if let Some(key) = name.strip_suffix('?').or_else(|| name.strip_suffix('!')) {
            return Err(format!(
                "column `{name}`: a name doesn't say whether it may be null any more: call it `{key}`, and read it as `Db.Nullable(a)` if it may be"
            ));
        }
        let declared = statement.get_column_decltype(index).map(|declared| declared.to_ascii_lowercase());
        columns.push((name, declared));
    }
    let mut out = Vec::new();
    while step(&mut statement)? {
        let row = statement.row().ok_or("turso: a step said it had a row, and had none")?;
        let mut object = Map::new();
        for (index, (name, declared)) in columns.iter().enumerate() {
            object.insert(name.clone(), read(row.get_value(index), declared.as_deref(), name)?);
        }
        out.push(Value::Object(object));
    }
    Ok(Value::Array(out).to_string())
}

/// A column's value as JSON, from what it is, and what its column was declared as.
fn read(value: &Sql, declared: Option<&str>, name: &str) -> Result<Value, String> {
    Ok(match value {
        Sql::Null => Value::Null,
        Sql::Numeric(Numeric::Integer(number)) if matches!(declared, Some("boolean" | "bool")) => Value::Bool(*number != 0),
        Sql::Numeric(Numeric::Integer(number)) => Value::from(*number),
        Sql::Numeric(Numeric::Float(number)) => match serde_json::Number::from_f64(f64::from(*number)) {
            Some(number) => Value::Number(number),
            None => return Err(format!("column `{name}` is {}, which JSON has no number for", f64::from(*number))),
        },
        Sql::Text(_) => {
            let text = value.to_text().unwrap_or_default();
            if matches!(declared, Some("json" | "jsonb")) {
                serde_json::from_str(text).map_err(|error| format!("column `{name}` is declared json, and isn't: {error}"))?
            } else {
                Value::from(text)
            }
        }
        Sql::Blob(_) => return Err(format!("column `{name}` is a blob, which Db can't read yet: read `hex({name})`")),
    })
}

pub async fn execute(client: &Client, sql: &str, params: Vec<Param>) -> Result<u64, String> {
    let sql = sql.to_string();
    with(client, move |connection, cache| alone(connection, &sql, || changed(connection, cache, &sql, &params))).await
}

/// How many rows `sql` changed (or, for a statement that only reads, read), as `execute` answers.
fn changed(connection: &Arc<Connection>, cache: &mut Prepared, sql: &str, params: &[Param]) -> Result<u64, String> {
    let mut statement = prepared(connection, cache, sql)?;
    bind(&mut statement, params)?;
    let reads = statement.get_program().is_readonly();
    let before = connection.total_changes();
    let mut read = 0u64;
    while step(&mut statement)? {
        read += 1;
    }
    // What it changed (an `insert … returning` too); a statement that changes nothing (a
    // `create table`) is 0, not the last one's count.
    Ok(if reads {
        read
    } else if connection.total_changes() == before {
        0
    } else {
        u64::try_from(statement.n_change()).unwrap_or(0)
    })
}

pub async fn script(client: &Client, in_transaction: bool, sql: &str) -> Result<(), String> {
    let sql = sql.to_string();
    with(client, move |connection, _| {
        if in_transaction {
            return batch(connection, &sql);
        }
        // A script changes the schema: its transaction is exclusive on MVCC too.
        batch(connection, "begin immediate")?;
        if let Err(error) = batch(connection, &sql) {
            if !connection.get_auto_commit() {
                let _ = batch(connection, "rollback");
            }
            return Err(error);
        }
        batch(connection, "commit")
    })
    .await
}

/// Stops what `client` is running (Turso's interrupt, as `sqlite3_interrupt`), and closes it once
/// that has stopped, rolling back a transaction open on it; never given back to the pool.
pub fn abandon(mut client: Client) {
    if let Some(conn) = client.conn.take() {
        conn.connection.interrupt();
    }
}

/// Begins a transaction: `concurrent` on MVCC, unless it is to be `exclusive` (it changes the
/// schema), or `immediate` in WAL mode, taking the write lock at once.
pub async fn begin(client: &Client, exclusive: bool) -> Result<(), String> {
    let sql = if mvcc() && !exclusive { "begin concurrent" } else { "begin immediate" };
    with(client, move |connection, _| batch(connection, sql)).await
}

/// Whether the file is in MVCC mode.
fn mvcc() -> bool {
    POOL.get().is_some_and(|pool| pool.mvcc)
}

/// Whether `sql` writes rows (an insert, an update, a delete, a replace, or a `with` before one),
/// so that on MVCC, outside a transaction, it runs in a concurrent one of its own. Anything else (a
/// read, a schema change, a pragma) runs as it is.
fn writes_rows(sql: &str) -> bool {
    let word: String = sql.trim_start().chars().take_while(|c| c.is_ascii_alphabetic()).collect::<String>().to_ascii_lowercase();
    matches!(word.as_str(), "insert" | "update" | "delete" | "replace" | "with")
}

/// Runs `run` (a statement, prepared and stepped by it): as it is, or, on MVCC for a write outside
/// a transaction, in a concurrent transaction of its own, committed, and begun again on a conflict
/// (the statement run again from its start), up to `TRIES` times.
fn alone<T>(connection: &Arc<Connection>, sql: &str, mut run: impl FnMut() -> Result<T, String>) -> Result<T, String> {
    if !(mvcc() && connection.get_auto_commit() && writes_rows(sql)) {
        return run();
    }
    let mut tries = 0;
    loop {
        batch(connection, "begin concurrent")?;
        let result = run().and_then(|value| batch(connection, "commit").map(|()| value));
        let Err(why) = result else { return result };
        if !connection.get_auto_commit() {
            let _ = batch(connection, "rollback");
        }
        tries += 1;
        if !why.starts_with(CONFLICT) || tries >= TRIES {
            return Err(why);
        }
        // A pause first, random, longer each time (`super::backoff`): a slower writer isn't
        // starved by faster ones.
        std::thread::sleep(super::backoff(u32::try_from(tries).unwrap_or(u32::MAX)));
    }
}

pub async fn commit(client: &Client) -> Result<(), String> {
    with(client, |connection, _| batch(connection, "commit")).await
}

pub async fn rollback(client: &Client) {
    let _ = with(client, |connection, _| {
        if !connection.get_auto_commit() {
            batch(connection, "rollback")?;
        }
        Ok(())
    })
    .await;
}
