//! Postgres, the database of an app whose program says `Postgres` (`db`): one pool of connections,
//! and statements whose parameters are sent as text, which Postgres reads as the type each place
//! wants, and whose rows leave as JSON. Connections use TLS when the server offers it (or the URL's
//! `sslmode` requires it), checked against the web's certificate authorities.
//!
//! One more connection listens (`LISTEN`): what Postgres is told (`NOTIFY`, delivered when the
//! transaction that sent it commits) is published on the live topic `db:<channel>`. That is how
//! the job workers, in Roc, hear that a job was queued.

use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use futures_util::StreamExt;
use super::Param;
use serde_json::{Map, Value};
use std::collections::HashSet;
use std::error::Error;
use std::sync::{Mutex, OnceLock};
use tokio_postgres::types::{Format, IsNull, ToSql, Type, to_sql_checked};
use tokio_postgres::{AsyncMessage, Row};
use tokio_postgres_rustls::MakeRustlsConnect;

static POOL: OnceLock<Pool> = OnceLock::new();

/// The connection that listens, and the channels it listens to.
static LISTENER: OnceLock<tokio_postgres::Client> = OnceLock::new();
static CHANNELS: Mutex<Option<HashSet<String>>> = Mutex::new(None);

fn tls() -> MakeRustlsConnect {
    MakeRustlsConnect::new((*crate::tls::client_config()).clone())
}

/// Connects the pool to `url` (connections open as they are first needed).
pub fn connect(url: &str) -> Result<(), String> {
    let config: tokio_postgres::Config = url.parse().map_err(|error| format!("database url: {error}"))?;
    let manager = Manager::from_config(config, tls(), ManagerConfig { recycling_method: RecyclingMethod::Fast });
    let pool = Pool::builder(manager).max_size(16).build().map_err(|error| format!("database pool: {error}"))?;
    POOL.set(pool).map_err(|_| "the database is already connected".to_string())
}

/// A connection from the pool, kept while it is out.
pub type Client = deadpool_postgres::Object;

/// Opens the connection that listens, and publishes what it hears.
pub async fn start_listening(url: &str) -> Result<(), String> {
    let config: tokio_postgres::Config = url.parse().map_err(|error| format!("database url: {error}"))?;
    let (client, mut connection) = config.connect(tls()).await.map_err(|error| format!("database: {}", described(error)))?;
    tokio::spawn(async move {
        let mut messages = futures_util::stream::poll_fn(move |context| connection.poll_message(context));
        while let Some(message) = messages.next().await {
            match message {
                Ok(AsyncMessage::Notification(notice)) => crate::live::publish(&format!("db:{}", notice.channel()), notice.payload()),
                Ok(_) => {}
                Err(error) => {
                    // A check's scratch database (D-058) is dropped with this connection open.
                    if !super::check::active() {
                        crate::logging::error("rocx server: the connection that listens to Postgres failed", &[("error", described(error).into())]);
                    }
                    break;
                }
            }
        }
    });
    LISTENER.set(client).map_err(|_| "the database is listened to already".to_string())
}

/// Listens to `channel`, if nothing has yet.
pub async fn listen(channel: &str) -> Result<(), String> {
    let Some(client) = LISTENER.get() else { return Err(super::NONE.into()) };
    let fresh = CHANNELS.lock().unwrap().get_or_insert_with(HashSet::new).insert(channel.to_string());
    if fresh {
        let quoted = channel.replace('"', "\"\"");
        if let Err(error) = client.batch_execute(&format!("listen \"{quoted}\"")).await {
            CHANNELS.lock().unwrap().get_or_insert_with(HashSet::new).remove(channel);
            return Err(described(error));
        }
    }
    Ok(())
}

pub async fn client() -> Result<Client, String> {
    pool()?.get().await.map_err(|error| format!("database: {error}"))
}

fn pool() -> Result<&'static Pool, String> {
    POOL.get().ok_or_else(|| super::NONE.to_string())
}

/// A parameter as Roc gave it: text, which Postgres reads as the type its place in the statement
/// wants, or null.
#[derive(Debug)]
struct Text(Option<String>);

impl ToSql for Text {
    fn to_sql(&self, _: &Type, out: &mut bytes::BytesMut) -> Result<IsNull, Box<dyn Error + Sync + Send>> {
        match &self.0 {
            Some(text) => {
                out.extend_from_slice(text.as_bytes());
                Ok(IsNull::No)
            }
            None => Ok(IsNull::Yes),
        }
    }

    fn accepts(_: &Type) -> bool {
        true
    }

    fn encode_format(&self, _: &Type) -> Format {
        Format::Text
    }

    to_sql_checked!();
}

/// The parameters as Postgres is sent them: text (a number as it is written, a `Bool` as `true` or
/// `false`), or null.
fn parameters(params: &[Param]) -> Vec<Text> {
    params
        .iter()
        .map(|param| match param {
            Param::Null => Text(None),
            Param::Text(text) => Text(Some(text.clone())),
            Param::Int(number) => Text(Some(number.to_string())),
            Param::Bool(yes) => Text(Some(yes.to_string())),
        })
        .collect()
}

pub fn described(error: tokio_postgres::Error) -> String {
    match error.as_db_error() {
        Some(db) => match db.detail() {
            Some(detail) => format!("{}: {} ({detail})", db.code().code(), db.message()),
            None => format!("{}: {}", db.code().code(), db.message()),
        },
        None => error.to_string(),
    }
}

/// The rows `sql` reads, as a JSON array of objects, each column by its name: a null is `null`,
/// anything else its value. Whether a column may be null is the reader's to say, in the record it
/// decodes a row into (`Db.Nullable(a)`), not the host's to look up.
pub async fn query(client: &Client, sql: &str, params: &[Param]) -> Result<String, String> {
    let params = parameters(params);
    let statement = client.prepare_cached(sql).await.map_err(described)?;
    let refs: Vec<&(dyn ToSql + Sync)> = params.iter().map(|param| param as &(dyn ToSql + Sync)).collect();
    let rows = client.query(&statement, &refs).await.map_err(described)?;

    let mut keys = Vec::new();
    for column in statement.columns() {
        let name = column.name();
        if let Some(key) = name.strip_suffix('?').or_else(|| name.strip_suffix('!')) {
            return Err(format!(
                "column `{name}`: a name doesn't say whether it may be null any more: call it `{key}`, and read it as `Db.Nullable(a)` if it may be"
            ));
        }
        keys.push(name.to_string());
    }

    let mut out = Vec::with_capacity(rows.len());
    for row in &rows {
        let mut object = Map::new();
        for (index, key) in keys.iter().enumerate() {
            object.insert(key.clone(), read(row, index)?.unwrap_or(Value::Null));
        }
        out.push(Value::Object(object));
    }
    Ok(Value::Array(out).to_string())
}

/// How many rows `sql` changed.
pub async fn execute(client: &Client, sql: &str, params: &[Param]) -> Result<u64, String> {
    let params = parameters(params);
    let statement = client.prepare_cached(sql).await.map_err(described)?;
    let refs: Vec<&(dyn ToSql + Sync)> = params.iter().map(|param| param as &(dyn ToSql + Sync)).collect();
    client.execute(&statement, &refs).await.map_err(described)
}

/// Runs `sql`'s statements, with no parameters: in the call's transaction (`in_transaction`), or in
/// a transaction of their own.
pub async fn script(client: &Client, in_transaction: bool, sql: &str) -> Result<(), String> {
    if in_transaction {
        client.batch_execute(sql).await.map_err(described)?;
    } else {
        client.batch_execute("begin").await.map_err(described)?;
        if let Err(error) = client.batch_execute(sql).await {
            rollback(client).await;
            return Err(described(error));
        }
        client.batch_execute("commit").await.map_err(described)?;
    }
    Ok(())
}

/// Lets go of a connection cut off in the middle of a statement (a job past its time limit): the
/// statement is cancelled, and the connection closed, never given back to the pool, so no one
/// else's statement waits behind it (or is cancelled by mistake), and a transaction open on it
/// ends with it. Returns at once; the cancel goes on `runtime`.
pub fn abandon(client: Client, runtime: &tokio::runtime::Handle) {
    let token = client.cancel_token();
    runtime.spawn(async move {
        let _ = token.cancel_query(tls()).await;
    });
    drop(deadpool_postgres::Object::take(client));
}

/// Tells Postgres's listeners `payload` on `channel` (`pg_notify`): when the transaction `client` is
/// in commits, or at once outside one.
pub async fn notify(client: &Client, channel: &str, payload: &str) -> Result<(), String> {
    client.execute("select pg_notify($1, $2)", &[&channel, &payload]).await.map(|_| ()).map_err(described)
}

/// Begins a transaction on `client`, which the call that asked keeps until it ends.
pub async fn begin(client: &Client) -> Result<(), String> {
    client.batch_execute("begin").await.map_err(described)
}

pub async fn commit(client: &Client) -> Result<(), String> {
    client.batch_execute("commit").await.map_err(described)
}

pub async fn rollback(client: &Client) {
    let _ = client.batch_execute("rollback").await;
}

/// Column `index` of `row` as JSON (None for a null), from the type Postgres says it is. A type
/// Db can't read yet asks for a cast.
fn read(row: &Row, index: usize) -> Result<Option<Value>, String> {
    let column = &row.columns()[index];
    let ty = column.type_();
    let failed = |error: tokio_postgres::Error| format!("column `{}`: {error}", column.name());
    Ok(match *ty {
        Type::BOOL => row.try_get::<_, Option<bool>>(index).map_err(failed)?.map(Value::from),
        Type::INT2 => row.try_get::<_, Option<i16>>(index).map_err(failed)?.map(Value::from),
        Type::INT4 => row.try_get::<_, Option<i32>>(index).map_err(failed)?.map(Value::from),
        Type::INT8 => row.try_get::<_, Option<i64>>(index).map_err(failed)?.map(Value::from),
        Type::OID => row.try_get::<_, Option<u32>>(index).map_err(failed)?.map(Value::from),
        Type::FLOAT4 => row.try_get::<_, Option<f32>>(index).map_err(failed)?.map(Value::from),
        Type::FLOAT8 => row.try_get::<_, Option<f64>>(index).map_err(failed)?.map(Value::from),
        Type::TEXT | Type::VARCHAR | Type::BPCHAR | Type::NAME | Type::UNKNOWN => {
            row.try_get::<_, Option<String>>(index).map_err(failed)?.map(Value::from)
        }
        Type::JSON | Type::JSONB => row.try_get::<_, Option<Value>>(index).map_err(failed)?,
        Type::UUID => row.try_get::<_, Option<uuid::Uuid>>(index).map_err(failed)?.map(|id| Value::from(id.to_string())),
        Type::TIMESTAMPTZ => row
            .try_get::<_, Option<chrono::DateTime<chrono::Utc>>>(index)
            .map_err(failed)?
            .map(|at| Value::from(at.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true))),
        Type::TIMESTAMP => row
            .try_get::<_, Option<chrono::NaiveDateTime>>(index)
            .map_err(failed)?
            .map(|at| Value::from(at.format("%Y-%m-%dT%H:%M:%S%.f").to_string())),
        Type::DATE => row.try_get::<_, Option<chrono::NaiveDate>>(index).map_err(failed)?.map(|day| Value::from(day.to_string())),
        _ => {
            return Err(format!(
                "column `{}` is a {ty}, which Db can't read yet: cast it (`{}::text`)",
                column.name(),
                column.name()
            ));
        }
    })
}

/// What Postgres says of `sql`, prepared and not run (D-058's check, `db::check`): its parameters,
/// each the type Postgres gives its place (they are sent untyped, as `query` sends them), and each
/// column's name and type, and, for one that comes straight from a table's column, whether that
/// is `not null` (`pg_attribute.attnotnull`).
pub async fn describe(client: &Client, sql: &str) -> Result<Value, String> {
    let statement = client.prepare(sql).await.map_err(described)?;
    let params: Vec<Value> = (1..=statement.params().len()).map(|n| Value::from(format!("${n}"))).collect();
    let types: Vec<Value> = statement.params().iter().map(|ty| Value::from(ty.name())).collect();
    let mut columns = Vec::new();
    for column in statement.columns() {
        let origin = match (column.table_oid(), column.column_id()) {
            (Some(table), Some(at)) if table != 0 && at > 0 => {
                let row = client
                    .query_one("select attrelid::regclass::text, attname::text, attnotnull from pg_attribute where attrelid = $1 and attnum = $2", &[&table, &at])
                    .await
                    .map_err(described)?;
                Some((row.get::<_, String>(0), row.get::<_, String>(1), row.get::<_, bool>(2)))
            }
            _ => None,
        };
        let ty = column.type_();
        columns.push(super::check::Column { name: column.name().to_string(), declared: Some(ty.name().to_string()), kind: Some(kind(ty)), origin }.json());
    }
    Ok(serde_json::json!({ "params": params, "param_types": types, "columns": columns }))
}

/// How `read` reads a column of type `ty`: its kind, for D-058's check (`db::check`).
fn kind(ty: &Type) -> &'static str {
    match *ty {
        Type::BOOL => "boolean",
        Type::INT2 | Type::INT4 | Type::INT8 | Type::OID => "integer",
        Type::FLOAT4 | Type::FLOAT8 => "real",
        Type::TEXT | Type::VARCHAR | Type::BPCHAR | Type::NAME | Type::UNKNOWN | Type::UUID | Type::TIMESTAMPTZ | Type::TIMESTAMP | Type::DATE => "text",
        Type::JSON | Type::JSONB => "json",
        _ => "unreadable",
    }
}

/// Makes the database `name` on the server `url` names (D-058's scratch database).
pub async fn create_database(url: &str, name: &str) -> Result<(), String> {
    let config: tokio_postgres::Config = url.parse().map_err(|error| format!("database url: {error}"))?;
    let (client, connection) = config.connect(tls()).await.map_err(described)?;
    let task = tokio::spawn(connection);
    let made = client.batch_execute(&format!("create database \"{name}\"")).await.map_err(described);
    drop(client);
    let _ = task.await;
    made
}

/// Drops the database `name` on the server `url` names, ending what is connected to it.
pub async fn drop_database(url: &str, name: &str) -> Result<(), String> {
    let config: tokio_postgres::Config = url.parse().map_err(|error| format!("database url: {error}"))?;
    let (client, connection) = config.connect(tls()).await.map_err(described)?;
    let task = tokio::spawn(connection);
    let dropped = client.batch_execute(&format!("drop database if exists \"{name}\" with (force)")).await.map_err(described);
    drop(client);
    let _ = task.await;
    dropped
}

/// `url` with its database `name` in place of the one it names: `postgres://user@host/name?…`.
pub fn with_database(url: &str, name: &str) -> Result<String, String> {
    let (scheme, rest) = url.split_once("://").ok_or("database url: not a postgres:// one")?;
    let (address, query) = match rest.split_once('?') {
        Some((address, query)) => (address, format!("?{query}")),
        None => (rest, String::new()),
    };
    let server = address.split_once('/').map_or(address, |(server, _)| server);
    Ok(format!("{scheme}://{server}/{name}{query}"))
}

