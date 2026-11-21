//! The server platform's host (`server/platform`): Roc compiled to native code, linked with this
//! library into one executable. It answers HTTP with tokio and hyper (`http`), keeps Roc's memory
//! and catches its crashes (`roc`), and gives Roc general effects (`hosted`): Postgres (`db`), live
//! topics and rooms (`live`), named locks and values (`memory`), TCP and TLS (`tcp`, `tls`), HTTP
//! requests to other servers (`client`), the settings it was started with (`settings`), the
//! outbox in memory (`outbox`); and it renders a page of components (`signals`). Jobs, cron,
//! migrations, actors and email are the platform's Roc.
//!
//! Starting: the address is taken (a port in use stops the server before anything starts); the
//! database is connected, and a connection listens to it; the platform's start runs in Roc (its
//! schedules checked, its tables and the app's migrations applied, the jobs a stop cut short queued
//! again); its background loops start (the job workers, the schedules), each on a thread of its
//! own; then it answers. Stopping (SIGTERM, or ^C): it stops listening, the loops
//! end (a worker finishes the job it is running), and it waits for what is running (up to ten
//! seconds) before it exits.

#[path = "roc_platform_abi.rs"]
#[allow(unsafe_op_in_unsafe_fn)]
mod abi;
mod client;
mod db;
mod hosted;
mod http;
mod live;
mod memory;
mod outbox;
mod roc;
mod settings;
mod signals;
mod tcp;
mod tls;

use std::ffi::{CStr, c_char, c_int};
use std::time::Duration;

/// How long a stop waits for requests, streams and jobs still running.
const GRACE: Duration = Duration::from_secs(10);

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
    let config = match http::Config::parse(args) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("{message}");
            return 2;
        }
    };
    // Roc runs on blocking threads, whose stacks are as deep as Roc's own default (8 MiB): a page
    // is a deep tree to render. (Stacks are reserved, not used: an idle thread costs little.) An
    // open stream holds a thread for as long as it is open, so there may be many.
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_stack_size(8 << 20)
        .max_blocking_threads(1024)
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("rocx server: {error}");
            return 1;
        }
    };
    hosted::set_runtime(runtime.handle().clone());
    match runtime.block_on(run(config)) {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("rocx server: {message}");
            1
        }
    }
}

async fn run(config: http::Config) -> Result<(), String> {
    let mut given = std::collections::HashMap::new();
    if config.database_url.is_some() {
        given.insert("database".to_string(), "yes".to_string());
    }
    given.insert("job-workers".to_string(), config.job_workers.to_string());
    given.insert("job-retry-ms".to_string(), config.job_retry_ms.to_string());
    given.insert("mail-from".to_string(), config.mail_from.clone());
    if let Some(url) = &config.smtp_url {
        given.insert("smtp-url".to_string(), url.clone());
    }
    if let Some(url) = &config.storage_url {
        given.insert("storage-url".to_string(), url.clone());
    }
    if config.dev {
        given.insert("dev".to_string(), "yes".to_string());
    }
    if config.debug {
        given.insert("debug".to_string(), "yes".to_string());
    }
    settings::set(given);

    // The address first: a server that can't listen starts nothing (no loops to leave running into
    // a runtime that is shutting down).
    let listener = http::bind(&config).await?;
    let (stop, stopping) = tokio::sync::watch::channel(false);
    hosted::set_stop(stopping.clone());
    if let Some(url) = &config.database_url {
        db::connect(url)?;
        db::start_listening(url).await?;
    }
    // The platform's start, in Roc: a bad schedule or a migration that fails stops the server here.
    let started = tokio::task::spawn_blocking(|| hosted::call(None, roc::init)).await.map_err(|_| "starting failed".to_string())?;
    match started {
        Ok(Ok(())) => {}
        Ok(Err(why)) => return Err(why),
        Err(crash) => return Err(format!("starting crashed: {}", crash.0)),
    }
    let count = tokio::task::spawn_blocking(|| hosted::call(None, roc::background_count))
        .await
        .map_err(|_| "starting failed".to_string())?
        .map_err(|crash| format!("starting crashed: {}", crash.0))?;
    let loops: Vec<_> = (0..count).map(|index| tokio::task::spawn_blocking(move || background(index))).collect();

    let stop = std::sync::Arc::new(stop);
    let signalled = stop.clone();
    tokio::spawn(async move {
        let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("a SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
        eprintln!("rocx server: stopping");
        let _ = signalled.send(true);
    });

    let served = http::serve(listener, config, stopping, GRACE).await.map_err(|error| error.to_string());
    // Stopped, or failed: the loops are told, and end (a worker finishes its job first), or the
    // grace runs out; a job cut short runs again at the next start.
    let _ = stop.send(true);
    let finished = futures_util::future::join_all(loops);
    if tokio::time::timeout(GRACE, finished).await.is_err() {
        eprintln!("rocx server: stopped with jobs still running: they run again at the next start");
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
                eprintln!("rocx: a background loop crashed, and starts again in a second: {}", crash.0);
                if hosted::pause(Duration::from_secs(1)) {
                    return;
                }
            }
        }
    }
}
