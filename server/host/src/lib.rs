//! The server platform's host (`server/platform`): Roc compiled to native code, linked with this
//! library into one executable. It answers HTTP with tokio and hyper (`http`), keeps Roc's memory
//! and catches its crashes (`roc`), and gives Roc general effects (`hosted`): the app's database,
//! Postgres or SQLite (`db`), live topics and rooms (`live`), actors' mailboxes and timers (`actors`), named values (`memory`), TCP
//! and TLS (`tcp`, `tls`), HTTP requests to other servers on connections kept alive, through a proxy
//! when there is one (`client`, `proxy`), the settings it was started
//! with (`settings`), values by key in memory (`kv`, for `Kv`); and it renders a page of components
//! (`signals`). Jobs, cron, migrations, actors' state and email are the platform's Roc.
//!
//! Starting: the address is taken (a port in use stops the server before anything starts); the
//! platform's start runs in Roc (the app's database opened, where its program and `--database-url`
//! say, and for Postgres a connection that listens to it; the app's plugins checked, its tables, the plugins' and the app's migrations applied, the plugins'
//! starts run: the jobs plugin's queues again the jobs a stop cut short); its background loops
//! start (the plugins': the job workers, the schedules), each a call of its own that pauses while
//! it waits; then it answers. Stopping (SIGTERM, or ^C): it stops listening, the
//! loops end (a worker finishes the job it is running), and it waits for what is running (up to ten
//! seconds) before it exits, its log flushed.
//!
//! Roc runs on threads of its own (`coroutine`, D-027), as many as the machine has cores
//! (`--roc-threads`, or `ROCX_ROC_THREADS`, says otherwise): each call into Roc (a request, a stream, an actor's turn, a
//! background loop) is a coroutine on one of them, which pauses whenever an effect waits, so any
//! number of calls can be waiting at once, and none holds a thread while it does.
//!
//! Every line it logs, and every line Roc does, is an event on the log (`logging`): a level, a
//! message and fields, written pretty or as JSON, as the app's `program` says, by a thread of its
//! own.

#[path = "roc_platform_abi.rs"]
#[allow(unsafe_op_in_unsafe_fn)]
mod abi;
mod actors;
mod blobs;
mod channels;
mod client;
mod coroutine;
mod db;
mod files;
mod hosted;
mod http;
mod kv;
mod live;
mod logging;
mod memory;
mod proxy;
mod roc;
mod settings;
mod signals;
mod tcp;
mod tls;

use std::ffi::{CStr, c_char, c_int};
use std::time::Duration;

/// How long a stop waits for requests, streams and jobs still running.
const GRACE: Duration = Duration::from_secs(10);

/// `--describe-sql FILE` (D-058): no HTTP, no background loops. The platform's start, on a
/// scratch database (`db::check`), applies the program's migrations; then each statement in `FILE`
/// (a JSON array of SQL) is prepared and described, and the answers, in the same order, go to
/// stdout: `{ "engine": "sqlite", "statements": [{ "params": […], "columns": […] } or { "error": … }] }`.
/// The scratch database goes, whatever happened.
async fn described(config: http::Config, mut given: std::collections::HashMap<String, String>, file: &std::path::Path) -> Result<(), String> {
    let text = std::fs::read_to_string(file).map_err(|error| format!("--describe-sql {}: {error}", file.display()))?;
    let statements: Vec<String> = serde_json::from_str(&text).map_err(|error| format!("--describe-sql {}: a JSON array of SQL, each a string: {error}", file.display()))?;
    db::check::start(config.sql_database.clone());
    // The platform's start opens the app's kind of database whatever URL is about (a SQLite app's
    // check makes a file, and needs none): DATABASE_URL may be a Postgres one in a shell.
    given.insert("describe_sql".to_string(), "yes".to_string());
    given.insert("public_url".to_string(), config.public_url.clone().unwrap_or_else(|| "http://127.0.0.1".to_string()));
    settings::set(given);
    let (_stop, stopping) = tokio::sync::watch::channel(false);
    hosted::set_stop(stopping);
    actors::start(None);
    let started = coroutine::run(|| hosted::call(None, roc::init)).await.map_err(|_| "starting failed".to_string());
    let answer = match started {
        Ok(Ok(Ok(()))) => match db::flavor() {
            Some(flavor) => {
                let mut answers = Vec::with_capacity(statements.len());
                for sql in &statements {
                    answers.push(db::check::describe(sql).await);
                }
                Ok(serde_json::json!({ "engine": flavor.name(), "statements": answers }))
            }
            None if statements.is_empty() => Ok(serde_json::json!({ "engine": null, "statements": [] })),
            None => Err("the app has no database to check against: its program says `database: Postgres`, and the check has no server to make a scratch database on: give --database-url (DATABASE_URL), or name a database the check may migrate with --sql-database URL (ROCX_SQL_DATABASE)".to_string()),
        },
        Ok(Ok(Err(why))) => Err(why),
        Ok(Err(crash)) => Err(format!("starting crashed: {}", crash.0)),
        Err(why) => Err(why),
    };
    db::check::finish().await;
    let answer = answer?;
    println!("{answer}");
    Ok(())
}

/// The executable's entry: Roc links the app against this library, and the app has no `main` of
/// its own.
#[unsafe(no_mangle)]
pub extern "C" fn main(argc: c_int, argv: *const *const c_char) -> c_int {
    // Rust's own `main` would do this: a write to a client that has gone must be an error, not a
    // signal that ends the process.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
    let args = (1..argc.max(1) as usize)
        .map(|index| unsafe { CStr::from_ptr(*argv.add(index)) }.to_string_lossy().into_owned())
        .collect();
    logging::start();
    let code = served(args);
    // What is still on the log's queue is written before the process exits.
    logging::flush();
    code
}

/// The server, from its arguments to its stop: the process's exit code.
fn served(args: Vec<String>) -> c_int {
    let config = match http::Config::parse(args) {
        Ok(config) => config,
        // What it was asked for, for a person to read, as it is.
        Err(message) if message == http::USAGE => {
            eprintln!("{message}");
            return 2;
        }
        Err(message) => {
            logging::error("rocx server: can't start", &[("error", message.into())]);
            return 2;
        }
    };
    // tokio's threads answer HTTP and drive every socket and timer. Roc runs on threads of its own
    // (`coroutine`), each call a coroutine with a stack as deep as Roc's own default (8 MiB: a page
    // is a deep tree to render), which pauses while it waits: a call that waits (an open stream's,
    // say) holds no thread.
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            logging::error("rocx server: can't start", &[("error", error.to_string().into())]);
            return 1;
        }
    };
    hosted::set_runtime(runtime.handle().clone());
    if let Err(message) = coroutine::start(config.roc_threads, runtime.handle().clone()) {
        logging::error("rocx server: can't start", &[("error", message.into())]);
        return 1;
    }
    let code = match runtime.block_on(run(config)) {
        Ok(()) => 0,
        Err(message) => {
            logging::error("rocx server: can't start", &[("error", message.into())]);
            1
        }
    };
    // Whatever Roc still runs (past the grace) is left where it is: the process exits.
    coroutine::halt();
    code
}

async fn run(config: http::Config) -> Result<(), String> {
    let mut given = std::collections::HashMap::new();
    // The platform's start opens the database (`Host.db_open!`): at this URL, or the program's file.
    // A check (D-058) opens a scratch one instead (`db::check`), or the one named for it.
    let url = if config.describe_sql.is_some() { config.sql_database.as_ref().or(config.database_url.as_ref()) } else { config.database_url.as_ref() };
    if let Some(url) = url {
        given.insert("database_url".to_string(), url.clone());
    }
    if config.dev {
        given.insert("dev".to_string(), "yes".to_string());
    }
    if config.debug {
        given.insert("debug".to_string(), "yes".to_string());
    }
    kv::set_limit(usize::try_from(config.kv_max_mb).unwrap_or(usize::MAX).saturating_mul(1024 * 1024));
    if let Some(file) = config.describe_sql.clone() {
        return described(config, given, &file).await;
    }

    // The address first: a server that can't listen starts nothing (no loops to leave running into
    // a runtime that is shutting down).
    let listener = http::bind(&config).await?;
    // Where the app is: as it was given, or else where it listens, now that the port is known
    // (`--port 0`: the system's).
    let listening = listener.local_addr().map_err(|error| error.to_string())?;
    given.insert("public_url".to_string(), config.public_url.clone().unwrap_or_else(|| http::listening_url(listening)));
    settings::set(given);
    let (stop, stopping) = tokio::sync::watch::channel(false);
    hosted::set_stop(stopping.clone());
    // Actors: their router, before the platform's start tells it the app's kinds. Kept in the
    // database, an actor idle for long enough is let go; without one, its task is all it has.
    let idle = (config.actor_idle_ms > 0).then(|| Duration::from_millis(config.actor_idle_ms));
    actors::start(idle);
    // The platform's start, in Roc: a bad schedule or a migration that fails stops the server here.
    let started = coroutine::run(|| hosted::call(None, roc::init)).await.map_err(|_| "starting failed".to_string())?;
    match started {
        Ok(Ok(())) => {}
        Ok(Err(why)) => return Err(why),
        Err(crash) => return Err(format!("starting crashed: {}", crash.0)),
    }
    let count = coroutine::run(|| hosted::call(None, roc::background_count))
        .await
        .map_err(|_| "starting failed".to_string())?
        .map_err(|crash| format!("starting crashed: {}", crash.0))?;
    let loops: Vec<_> = (0..count).map(|index| coroutine::run(move || background(index))).collect();

    let stop = std::sync::Arc::new(stop);
    let signalled = stop.clone();
    tokio::spawn(async move {
        let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("a SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
        logging::info("rocx server: stopping", &[]);
        let _ = signalled.send(true);
    });

    let served = http::serve(listener, config, stopping, GRACE).await.map_err(|error| error.to_string());
    // Stopped, or failed: the loops are told, and end (a worker finishes its job first), or the
    // grace runs out; a job cut short runs again at the next start.
    let _ = stop.send(true);
    let finished = futures_util::future::join_all(loops);
    if tokio::time::timeout(GRACE, finished).await.is_err() {
        logging::warn("rocx server: stopped with jobs still running: they run again at the next start", &[]);
    }
    served
}

/// Runs background loop `index` until it ends; one that crashes starts again a second later,
/// unless the server is stopping.
fn background(index: u64) {
    loop {
        match hosted::call_background(index) {
            Ok(()) => return,
            Err(crash) => {
                logging::error("rocx server: a background loop crashed, and starts again in a second", &[("error", crash.0.into())]);
                if hosted::pause(Duration::from_secs(1)) {
                    return;
                }
            }
        }
    }
}
