//! D-058 spike. Reads `{ engine, url?, migrations: [sql], statements: [sql] }` on stdin, builds a
//! database from the migrations (SQLite and Turso in memory; Postgres at `url`, a database made for
//! the run and dropped after), prepares each statement and prints what the engine says of it: its
//! error, or its parameters and its columns (name, declared type, the table column it comes from,
//! and whether that column is `not null`). Timings in milliseconds.
use serde_json::{Value, json};
use std::io::Read;
use std::time::Instant;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let job: Value = serde_json::from_str(&input).unwrap();
    let migrations: Vec<String> = job["migrations"].as_array().unwrap().iter().map(|m| m.as_str().unwrap().to_string()).collect();
    let statements: Vec<String> = job["statements"].as_array().unwrap().iter().map(|m| m.as_str().unwrap().to_string()).collect();
    let out = match job["engine"].as_str().unwrap() {
        "sqlite" => sqlite(&migrations, &statements),
        "turso" => turso(&migrations, &statements),
        "postgres" => postgres(job["url"].as_str().unwrap(), &migrations, &statements),
        other => panic!("engine {other}"),
    };
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}

fn sqlite(migrations: &[String], statements: &[String]) -> Value {
    let started = Instant::now();
    let conn = rusqlite::Connection::open_in_memory().unwrap();
    for m in migrations {
        if let Err(e) = conn.execute_batch(m) {
            return json!({ "migration_error": e.to_string() });
        }
    }
    let migrated = started.elapsed().as_secs_f64() * 1000.0;
    let started = Instant::now();
    let results: Vec<Value> = statements
        .iter()
        .map(|sql| match conn.prepare(sql) {
            Err(e) => json!({ "error": e.to_string() }),
            Ok(stmt) => {
                let names: Vec<String> = (1..=stmt.parameter_count()).map(|i| stmt.parameter_name(i).unwrap_or("?").to_string()).collect();
                let decls: Vec<Option<String>> = stmt.columns().map(|c| c.decl_type().map(str::to_string)).collect();
                let columns: Vec<Value> = (0..stmt.column_count())
                    .map(|i| {
                        let name = stmt.column_name(i).unwrap().to_string();
                        match stmt.column_metadata(i).ok().flatten() {
                            Some((_, table, origin, _, _, not_null, pk, _)) => json!({
                                "name": name, "decltype": decls[i], "table": table.to_str().unwrap(),
                                "origin": origin.to_str().unwrap(), "not_null": not_null || pk,
                            }),
                            None => json!({ "name": name, "decltype": decls[i] }),
                        }
                    })
                    .collect();
                json!({ "params": names, "columns": columns, "readonly": stmt.readonly() })
            }
        })
        .collect();
    json!({ "migrate_ms": migrated, "describe_ms": started.elapsed().as_secs_f64() * 1000.0, "results": results })
}

fn turso(migrations: &[String], statements: &[String]) -> Value {
    use turso_core::{Database, DatabaseOpts, OpenFlags, PlatformIO, SqliteDialect, StepResult};
    let started = Instant::now();
    let path = std::env::temp_dir().join(format!("rocx-describe-{}.db", std::process::id()));
    let io = std::sync::Arc::new(PlatformIO::new().unwrap());
    let db = Database::open_file_with_flags(io, path.to_str().unwrap(), OpenFlags::default(), DatabaseOpts::new(), None, std::sync::Arc::new(SqliteDialect)).unwrap();
    let conn = db.connect().unwrap();
    let step = |statement: &mut turso_core::Statement| -> Result<bool, String> {
        loop {
            match statement.step().map_err(|e| e.to_string())? {
                StepResult::Row => return Ok(true),
                StepResult::Done => return Ok(false),
                StepResult::IO | StepResult::Yield => statement._io().step().map_err(|e| e.to_string())?,
                StepResult::Sleep { duration } => std::thread::sleep(duration),
                other => return Err(format!("{other:?}")),
            }
        }
    };
    for m in migrations {
        let mut rest = m.as_str();
        loop {
            match conn.consume_stmt(rest) {
                Ok(Some((mut statement, end))) => {
                    if let Err(e) = (|| -> Result<(), String> { while step(&mut statement)? {} Ok(()) })() {
                        return json!({ "migration_error": e });
                    }
                    rest = &rest[end..];
                }
                Ok(None) => break,
                Err(e) => return json!({ "migration_error": e.to_string() }),
            }
        }
    }
    let migrated = started.elapsed().as_secs_f64() * 1000.0;
    let started = Instant::now();
    let results: Vec<Value> = statements
        .iter()
        .map(|sql| match conn.prepare(sql) {
            Err(e) => json!({ "error": e.to_string() }),
            Ok(stmt) => {
                let columns: Vec<Value> = (0..stmt.num_columns())
                    .map(|i| json!({
                        "name": stmt.get_column_name(i).to_string(),
                        "decltype": stmt.get_column_decltype(i),
                        "table": stmt.get_column_table_name(i).map(|t| t.to_string()),
                        "inferred": stmt.get_column_inferred_type(i),
                    }))
                    .collect();
                json!({ "params": stmt.parameters_count(), "columns": columns })
            }
        })
        .collect();
    drop(conn);
    for suffix in ["", "-wal", "-shm", "-log"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    json!({ "migrate_ms": migrated, "describe_ms": started.elapsed().as_secs_f64() * 1000.0, "results": results })
}

#[tokio::main(flavor = "current_thread")]
async fn postgres(url: &str, migrations: &[String], statements: &[String]) -> Value {
    let started = Instant::now();
    let (admin, conn) = tokio_postgres::connect(url, tokio_postgres::NoTls).await.unwrap();
    tokio::spawn(conn);
    let scratch = format!("rocx_describe_{}", std::process::id());
    admin.batch_execute(&format!("create database {scratch}")).await.unwrap();
    let made = started.elapsed().as_secs_f64() * 1000.0;
    let scratch_url = format!("{}/{}", url.rsplit_once('/').unwrap().0, scratch);
    let (client, conn) = tokio_postgres::connect(&scratch_url, tokio_postgres::NoTls).await.unwrap();
    let task = tokio::spawn(conn);
    let mut out = json!({});
    let mut failed = None;
    for m in migrations {
        if let Err(e) = client.batch_execute(m).await {
            failed = Some(e.as_db_error().map(|d| d.message().to_string()).unwrap_or(e.to_string()));
            break;
        }
    }
    let migrated = started.elapsed().as_secs_f64() * 1000.0 - made;
    if let Some(e) = failed {
        out = json!({ "migration_error": e });
    } else {
        let started = Instant::now();
        let mut results = vec![];
        // The origin column's `not null`, from the catalog, once per table column.
        let mut not_null: std::collections::HashMap<(u32, i16), bool> = Default::default();
        for sql in statements {
            match client.prepare(sql).await {
                Err(e) => results.push(json!({ "error": e.as_db_error().map(|d| d.message().to_string()).unwrap_or(e.to_string()) })),
                Ok(stmt) => {
                    let mut columns = vec![];
                    for c in stmt.columns() {
                        let origin = match (c.table_oid(), c.column_id()) {
                            (Some(t), Some(a)) if t != 0 => {
                                if !not_null.contains_key(&(t, a)) {
                                    let row = client
                                        .query_one("select attnotnull, attrelid::regclass::text, attname::text from pg_attribute where attrelid = $1 and attnum = $2", &[&t, &a])
                                        .await
                                        .unwrap();
                                    not_null.insert((t, a), row.get(0));
                                }
                                Some(not_null[&(t, a)])
                            }
                            _ => None,
                        };
                        columns.push(json!({ "name": c.name(), "type": c.type_().name(), "not_null": origin }));
                    }
                    let params: Vec<&str> = stmt.params().iter().map(|t| t.name()).collect();
                    results.push(json!({ "params": params, "columns": columns }));
                }
            }
        }
        out = json!({ "migrate_ms": migrated, "create_ms": made, "describe_ms": started.elapsed().as_secs_f64() * 1000.0, "results": results });
    }
    drop(client);
    let _ = task.await;
    let started = Instant::now();
    admin.batch_execute(&format!("drop database {scratch}")).await.unwrap();
    out["drop_ms"] = json!(started.elapsed().as_secs_f64() * 1000.0);
    out
}
