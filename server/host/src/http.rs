//! The HTTP server: files from disk as they are, everything else answered by the Roc app. A call
//! into Roc runs on one of Roc's threads, as a coroutine that pauses while its effects wait
//! (`coroutine`); a page of components is rendered there, in the same call; a stream of events
//! (`text/event-stream`) is a loop Roc runs in a call of its own, writing to the response as it
//! goes; a forwarded answer's body is fetched from elsewhere (`client::open`) and sent on as it
//! comes, never through Roc.

use crate::roc::{self, Feed};
use crate::{channels, client, coroutine, hosted, logging, signals};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, LengthLimitError, Limited, StreamBody, combinators::BoxBody};
use hyper::body::{Frame, Incoming};
use hyper::header::{CACHE_CONTROL, CONTENT_TYPE, HeaderName, HeaderValue};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use hyper_util::server::graceful::GracefulShutdown;
use std::collections::HashSet;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};

pub type Body = BoxBody<Bytes, Infallible>;

/// The most a request's body may be: Roc is handed it whole.
const MAX_BODY: usize = 16 << 20;

/// What a forwarded answer (`Server.forward`) keeps of upstream's headers: what says what its body
/// is. The answer's own headers are added after them, or replace them.
const KEPT: [&str; 6] = ["content-type", "content-length", "content-range", "accept-ranges", "etag", "last-modified"];

/// How long upstream has to begin its answer, and then to send each piece of its body.
const FORWARD_HEAD: Duration = Duration::from_secs(30);
const FORWARD_IDLE: Duration = Duration::from_secs(60);

/// How the server was started (`--help`).
pub struct Config {
    pub address: SocketAddr,
    /// Directories whose files are served as they are, at their paths.
    pub statics: Vec<PathBuf>,
    /// Single files at given paths (`--file /rocx/client.wasm=site/build/client.wasm`).
    pub files: Vec<(String, PathBuf)>,
    /// What every call to `respond!` is given besides the request.
    pub context: String,
    pub database_url: Option<String>,
    pub job_workers: usize,
    pub job_retry_ms: u64,
    /// How long an actor waits with nothing to do before it is let go (0: never), with a database.
    pub actor_idle_ms: u64,
    pub smtp_url: Option<String>,
    pub mail_from: String,
    /// Pages reload when the server restarts (after a rebuild); crashes show their message; the
    /// platform's Roc shows the dev mailbox at `GET /__rocx/mail` (`Outbox.roc`).
    pub dev: bool,
    /// `GET /__rocx/allocations` (how many allocations Roc holds now), and the mailbox as JSON
    /// (`/__rocx/mail.json`), for tests.
    pub debug: bool,
    /// How often a channel stream (`/rocx/live`) beats: a comment, and its channels' checks again.
    pub live_beat: Duration,
    /// How many threads Roc runs on (`--roc-threads`, `ROCX_ROC_THREADS`; one a core unless they
    /// say): a call that waits holds none (`coroutine`).
    pub roc_threads: usize,
}

pub const USAGE: &str = "usage: <app> [options]
  --port 8080 --host 127.0.0.1         where to listen (PORT)
  --static DIR, --file /PATH=FILE      files served as they are
  --context-file FILE                  what respond! is given besides each request
  --database-url URL                   Postgres (DATABASE_URL): Db, migrations, jobs, cron, actors
  --job-workers 4 --job-retry-ms 1000  jobs run at once; the first retry's wait, doubled after
  --actor-idle-ms 900000               an actor idle this long is let go (0: never; kept in Postgres)
  --smtp-url URL --mail-from ADDRESS   where email goes (SMTP_URL, MAIL_FROM); none: an outbox
  --dev                                reload pages on restart, show crashes, the mailbox at /__rocx/mail
  --debug                              GET /__rocx/allocations, and the mailbox as JSON
  --live-beat-ms 15000                 how often a channel stream beats, and its checks run again
  --roc-threads N                      the threads Roc runs on (ROCX_ROC_THREADS; one a core)";

impl Config {
    pub fn parse(args: Vec<String>) -> Result<Config, String> {
        let env = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        let mut port: u16 = env("PORT").and_then(|port| port.parse().ok()).unwrap_or(8080);
        let mut host = "127.0.0.1".to_string();
        let mut statics = Vec::new();
        let mut files = Vec::new();
        let mut context = String::new();
        let mut database_url = env("DATABASE_URL");
        let mut job_workers = 4;
        let mut job_retry_ms = 1000;
        let mut actor_idle_ms = 15 * 60 * 1000;
        let mut smtp_url = env("SMTP_URL");
        let mut mail_from = env("MAIL_FROM").unwrap_or_else(|| "rocx <rocx@localhost>".into());
        let mut dev = false;
        let mut debug = false;
        let mut live_beat_ms: u64 = 15_000;
        let mut roc_threads = match env("ROCX_ROC_THREADS") {
            Some(given) => given.trim().parse().ok().filter(|count| *count > 0).ok_or_else(|| format!("ROCX_ROC_THREADS needs a number above 0, not {given:?}"))?,
            None => crate::coroutine::default_threads(),
        };
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
            match arg.as_str() {
                "--port" => port = value()?.parse().map_err(|_| "--port needs a number".to_string())?,
                "--host" => host = value()?,
                "--static" => statics.push(PathBuf::from(value()?)),
                "--file" => {
                    let given = value()?;
                    let (path, file) = given.split_once('=').ok_or("--file needs /PATH=FILE")?;
                    files.push((path.to_string(), PathBuf::from(file)));
                }
                "--context-file" => {
                    let file = value()?;
                    context = std::fs::read_to_string(&file).map_err(|error| format!("{file}: {error}"))?;
                }
                "--database-url" => database_url = Some(value()?),
                "--migrations" => return Err("--migrations is gone: an app embeds its migrations (`program.migrations`, `import \"migrations/0001_notes.sql\" as notes : Str`)".into()),
                "--job-workers" => job_workers = value()?.parse().map_err(|_| "--job-workers needs a number".to_string())?,
                "--job-retry-ms" => job_retry_ms = value()?.parse().map_err(|_| "--job-retry-ms needs a number".to_string())?,
                "--actor-idle-ms" => actor_idle_ms = value()?.parse().map_err(|_| "--actor-idle-ms needs a number".to_string())?,
                "--smtp-url" => smtp_url = Some(value()?),
                "--mail-from" => mail_from = value()?,
                "--dev" => dev = true,
                "--debug" => debug = true,
                "--live-beat-ms" => live_beat_ms = value()?.parse().ok().filter(|ms| *ms > 0).ok_or("--live-beat-ms needs a number above 0")?,
                "--roc-threads" => roc_threads = value()?.parse().ok().filter(|count| *count > 0).ok_or("--roc-threads needs a number above 0")?,
                "--blocking-threads" => return Err("--blocking-threads is gone: a call into Roc holds no thread while it waits (D-027); --roc-threads (ROCX_ROC_THREADS) says how many threads Roc runs on".into()),
                "--help" | "-h" => return Err(USAGE.into()),
                other => return Err(format!("unknown argument {other} (--help lists them)")),
            }
        }
        let address = format!("{host}:{port}").parse().map_err(|error| format!("{host}:{port}: {error}"))?;
        let live_beat = Duration::from_millis(live_beat_ms);
        Ok(Config { address, statics, files, context, database_url, job_workers, job_retry_ms, actor_idle_ms, smtp_url, mail_from, dev, debug, live_beat, roc_threads })
    }
}

/// The address the server listens on, taken before anything else starts: a port in use stops the
/// server there, with nothing running yet to stop.
pub async fn bind(config: &Config) -> Result<TcpListener, String> {
    TcpListener::bind(config.address).await.map_err(|error| format!("{}: {error}", config.address))
}

/// Answers requests on `listener` (`bind`) until `stop` says so; then stops listening and waits (up
/// to `grace`) for the requests and streams being answered.
pub async fn serve(listener: TcpListener, config: Config, mut stop: watch::Receiver<bool>, grace: Duration) -> std::io::Result<()> {
    // The address in the message itself: what starts the server reads it there.
    logging::info(&format!("rocx server: http://{} (Roc, native)", listener.local_addr()?), &[]);
    let config = Arc::new(config);
    let graceful = GracefulShutdown::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else { continue };
                unacknowledged_deadline(&stream);
                let config = config.clone();
                let service = service_fn(move |request| answer(request, config.clone()));
                let connection = http1::Builder::new().serve_connection(TokioIo::new(stream), service);
                let watched = graceful.watch(connection);
                tokio::spawn(async move {
                    let _ = watched.await;
                });
            }
            _ = stop.changed() => break,
        }
    }
    drop(listener);
    tokio::select! {
        _ = graceful.shutdown() => {}
        _ = tokio::time::sleep(grace) => logging::warn("rocx server: stopped with requests still being answered", &[]),
    }
    Ok(())
}

// A page in a frame (a story in the dev catalog, beside others) leaves it to the page around it,
// which reloads it too: each held stream is one of the six connections a browser makes to a host,
// and a seventh frame's would wait for one forever.
const RELOAD: &str = r#"<script data-rocx>if(window.top===window){let gone=false;const at=new EventSource("/__reload");at.onerror=()=>{gone=true};at.onopen=()=>{if(gone)location.reload()}}</script>"#;

fn full(status: StatusCode, content_type: &str, body: impl Into<Bytes>) -> Response<Body> {
    let mut response = Response::new(Full::new(body.into()).boxed());
    *response.status_mut() = status;
    response.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_str(content_type).unwrap());
    response
}

async fn answer(request: Request<Incoming>, config: Arc<Config>) -> Result<Response<Body>, Infallible> {
    let path = percent_decoded(request.uri().path());
    if config.dev && path == "/__reload" {
        // Never sends: a page notices the server went (a rebuild) when this breaks, and reloads
        // when it can connect again.
        let mut response = Response::new(StreamBody::new(futures_util::stream::pending::<Result<Frame<Bytes>, Infallible>>()).boxed());
        response.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
        return Ok(response);
    }
    // The tab's stream of its channels, and what its pages say on them: the host's, not Roc's
    // (Roc runs only briefly, for each channel's check and hooks: `channels`).
    if path == "/rocx/live" {
        return Ok(channels::stream(request, &config));
    }
    if path == "/rocx/live/send" {
        return Ok(channels::send(request, config).await);
    }
    if config.debug && path == "/__rocx/allocations" {
        return Ok(full(StatusCode::OK, "text/plain", roc::live_allocations().to_string()));
    }
    if matches!(*request.method(), Method::GET | Method::HEAD) {
        if let Some(response) = file(&config, &path).await {
            return Ok(response);
        }
    }
    Ok(from_roc(request, config).await)
}

/// A file for `path`: one given by `--file`, or one in a `--static` directory (never outside it).
async fn file(config: &Config, path: &str) -> Option<Response<Body>> {
    let found = match config.files.iter().find(|(at, _)| at == path) {
        Some((_, file)) => Some(file.clone()),
        None => {
            let relative = Path::new(path.trim_start_matches('/'));
            if path.ends_with('/') || relative.components().any(|part| !matches!(part, Component::Normal(_))) {
                return None;
            }
            config.statics.iter().map(|dir| dir.join(relative)).find(|candidate| candidate.is_file())
        }
    }?;
    let bytes = tokio::fs::read(&found).await.ok()?;
    let mut response = full(StatusCode::OK, content_type(&found), bytes);
    if config.dev {
        response.headers_mut().insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    }
    Some(response)
}

fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|ext| ext.to_str()) {
        Some("css") => "text/css",
        Some("js" | "mjs") => "text/javascript",
        Some("svg") => "image/svg+xml",
        Some("wasm") => "application/wasm",
        Some("html") => "text/html; charset=utf-8",
        Some("txt") => "text/plain; charset=utf-8",
        Some("json") => "application/json",
        Some("png") => "image/png",
        Some("ico") => "image/x-icon",
        Some("woff2") => "font/woff2",
        // Sound files, for `Audio.play!`.
        Some("wav") => "audio/wav",
        Some("mp3") => "audio/mpeg",
        Some("ogg" | "oga" | "opus") => "audio/ogg",
        Some("m4a" | "aac") => "audio/mp4",
        Some("flac") => "audio/flac",
        Some("weba") => "audio/webm",
        _ => "application/octet-stream",
    }
}

/// The Roc app's answer: a page or an endpoint.
async fn from_roc(request: Request<Incoming>, config: Arc<Config>) -> Response<Body> {
    let method = request.method().clone();
    let target = target(request.uri());
    // `x-rocx-channel` and `x-rocx-tab` are the host's own, on its requests about a channel
    // (`channels`): never passed on from anyone else.
    let headers: String = request
        .headers()
        .iter()
        .filter(|(name, _)| !matches!(name.as_str(), "x-rocx-channel" | "x-rocx-tab"))
        .map(|(name, value)| format!("{}: {}\n", name.as_str(), String::from_utf8_lossy(value.as_bytes())))
        .collect();
    let body = match Limited::new(request.into_body(), MAX_BODY).collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(error) if error.is::<LengthLimitError>() => {
            return full(StatusCode::PAYLOAD_TOO_LARGE, "text/plain; charset=utf-8", "the request's body is too large");
        }
        Err(_) => return full(StatusCode::BAD_REQUEST, "text/plain; charset=utf-8", "could not read the request's body"),
    };

    let started = Instant::now();
    let asked = target.clone();
    let answering = hosted::Asked::new(method.as_str(), target, headers.trim_end_matches('\n').to_string(), body, config.context.clone(), config.dev);
    let answered = coroutine::run(move || {
        hosted::call_asking(answering.clone(), || {
            let mut answer = roc::respond(&answering.method, &answering.target, &answering.headers, &answering.body, &answering.started)?;
            // A page of components: rendered for GET (and any other method), with the status it
            // set (`<HttpStatusCode>`); not for HEAD, which gets the answer's status and headers.
            if let Some(page) = answer.page.take() {
                if answering.method == "HEAD" {
                    roc::drop_page(page);
                } else {
                    match signals::render_page(page)? {
                        signals::Rendered::Page(body) => {
                            answer.body = body;
                            answer.status = hosted::status().unwrap_or(answer.status);
                        }
                        // A read the page made, its middleware redirected: the page is that
                        // redirect, with the cookies it set, and the page's own headers but its type.
                        signals::Rendered::Redirect(redirect) => {
                            let own = answer.headers.lines().filter(|line| !line.to_ascii_lowercase().starts_with("content-type:"));
                            answer.headers = own.chain(redirect.headers.lines()).collect::<Vec<_>>().join("\n");
                            answer.status = redirect.status;
                            answer.body = String::new();
                        }
                    }
                }
            }
            Ok::<_, roc::Crash>(answer)
        })
    })
    .await;
    let took = started.elapsed();

    let answer = match answered {
        Ok(Ok(answer)) => answer,
        Ok(Err(crash)) => {
            logging::error("rocx server: Roc crashed", &[("method", method.as_str().into()), ("target", asked.as_str().into()), ("error", crash.0.as_str().into())]);
            let shown = if config.dev { format!("Roc crashed: {}", crash.0) } else { "Something went wrong.".into() };
            return full(StatusCode::INTERNAL_SERVER_ERROR, "text/plain; charset=utf-8", shown);
        }
        Err(_) => return full(StatusCode::INTERNAL_SERVER_ERROR, "text/plain; charset=utf-8", "the call into Roc failed"),
    };

    if let Some(upstream) = answer.forward {
        return forwarded(upstream, &answer.headers, &method, &asked, &config).await;
    }

    let status = StatusCode::from_u16(answer.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut builder = Response::builder().status(status);
    let mut is_html = false;
    for line in answer.headers.lines() {
        let Some((name, value)) = line.split_once(": ") else { continue };
        let (Ok(name), Ok(value)) = (HeaderName::from_bytes(name.as_bytes()), HeaderValue::from_str(value)) else { continue };
        if name == CONTENT_TYPE && value.as_bytes().starts_with(b"text/html") {
            is_html = true;
        }
        builder = builder.header(name, value);
    }
    // While developing, nothing is cached, unless Roc says otherwise.
    if config.dev && !answer.headers.lines().any(|line| line.to_ascii_lowercase().starts_with("cache-control:")) {
        builder = builder.header(CACHE_CONTROL, "no-store");
    }

    if let Some(feed) = answer.feed {
        if method == Method::HEAD {
            roc::drop_feed(feed);
            return builder.body(Full::new(Bytes::new()).boxed()).unwrap();
        }
        let (sender, receiver) = mpsc::channel::<Bytes>(8);
        tokio::spawn(send_events(feed, sender));
        let frames = futures_util::stream::unfold(receiver, |mut receiver| async move {
            receiver.recv().await.map(|data| (Ok::<_, Infallible>(Frame::data(data)), receiver))
        });
        return builder.body(StreamBody::new(frames).boxed()).unwrap();
    }

    let server_timing = format!("roc;desc=\"answered by Roc, natively\";dur={:.2}", took.as_secs_f64() * 1000.0);
    builder = builder.header("server-timing", server_timing);
    if let Some(bytes) = answer.bytes {
        let body = if method == Method::HEAD { Bytes::new() } else { Bytes::from(bytes) };
        return builder.body(Full::new(body).boxed()).unwrap();
    }
    let mut body = answer.body;
    if config.dev && is_html {
        body = match body.rfind("</body>") {
            Some(at) => format!("{}{RELOAD}{}", &body[..at], &body[at..]),
            None => body,
        };
    }
    let body = if method == Method::HEAD { Bytes::new() } else { Bytes::from(body) };
    builder.body(Full::new(body).boxed()).unwrap()
}

/// A forwarded answer (`Server.forward`): `upstream` asked with exactly the headers Roc gave it (a
/// range or a cache's question is the app's to pass on, from the request record:
/// `Server.passed_on`), and its answer sent on as it comes, its body never held
/// whole and never in Roc. Upstream's status and the headers in `KEPT`, then the answer's `own`; for
/// HEAD, a 204 or a 304, no body. An error upstream (400 or more) is its status and its reason, a
/// line of text, never what upstream said, nor the answer's headers (they describe the body it
/// would have been); a redirect not followed, or no answer, is a 502 (504 after `FORWARD_HEAD`).
/// The upstream's query is never logged nor shown: a presigned URL's signature is in it.
async fn forwarded(upstream: roc::Upstream, own: &str, method: &Method, asked: &str, config: &Config) -> Response<Body> {
    let shown = upstream.url.split('?').next().unwrap_or_default().to_string();
    let failed = |status: StatusCode, why: String| {
        let why = why.replace(&upstream.url, &shown);
        logging::error("rocx server: forwarding failed", &[("method", method.as_str().into()), ("target", asked.into()), ("upstream", shown.as_str().into()), ("error", why.as_str().into())]);
        let said = if config.dev { format!("forwarding to {shown}: {why}") } else { status.canonical_reason().unwrap_or("Bad Gateway").to_string() };
        full(status, "text/plain; charset=utf-8", said)
    };
    let outbound = match client::Outbound::new(&upstream.method, &upstream.url, &upstream.headers, Vec::new()) {
        Ok(outbound) => outbound,
        Err(why) => return failed(StatusCode::BAD_GATEWAY, why),
    };
    let response = match tokio::time::timeout(FORWARD_HEAD, client::open(outbound, true)).await {
        Ok(Ok(response)) => response,
        Ok(Err(why)) => return failed(StatusCode::BAD_GATEWAY, why),
        Err(_) => return failed(StatusCode::GATEWAY_TIMEOUT, format!("no answer within {} s", FORWARD_HEAD.as_secs())),
    };
    let status = response.status();
    if status.is_redirection() && status != StatusCode::NOT_MODIFIED {
        return failed(StatusCode::BAD_GATEWAY, format!("answered {status}, a redirect it couldn't follow"));
    }
    if status.is_client_error() || status.is_server_error() {
        // A missing object, or a range past its end, is the client's to hear about, not the log's.
        if status != StatusCode::NOT_FOUND && status != StatusCode::RANGE_NOT_SATISFIABLE {
            logging::warn("rocx server: forwarded an error", &[("method", method.as_str().into()), ("target", asked.into()), ("upstream", shown.as_str().into()), ("status", status.as_u16().into())]);
        }
        let mut refused = full(status, "text/plain; charset=utf-8", status.canonical_reason().unwrap_or("Refused"));
        if let Some(range) = response.headers().get(hyper::header::CONTENT_RANGE).filter(|_| status == StatusCode::RANGE_NOT_SATISFIABLE) {
            refused.headers_mut().insert(hyper::header::CONTENT_RANGE, range.clone());
        }
        return refused;
    }

    let mut builder = Response::builder().status(status);
    let headers = builder.headers_mut().expect("a builder with a status only");
    for name in KEPT {
        if let Some(value) = response.headers().get(name) {
            headers.insert(name, value.clone());
        }
    }
    let mut replaced = HashSet::new();
    for line in own.lines() {
        let Some((name, value)) = line.split_once(": ") else { continue };
        let (Ok(name), Ok(value)) = (HeaderName::from_bytes(name.as_bytes()), HeaderValue::from_str(value)) else { continue };
        if replaced.insert(name.clone()) {
            headers.remove(&name);
        }
        headers.append(name, value);
    }
    if config.dev && !headers.contains_key(CACHE_CONTROL) {
        headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    }
    if *method == Method::HEAD || status == StatusCode::NO_CONTENT || status == StatusCode::NOT_MODIFIED {
        return builder.body(Full::new(Bytes::new()).boxed()).unwrap();
    }
    // Each piece as it comes. If upstream stops, or goes quiet for `FORWARD_IDLE`, the body ends
    // short of its length, and the client's connection is closed rather than the body passed off
    // as whole.
    let frames = futures_util::stream::unfold(response.into_body(), |mut body| async move {
        match tokio::time::timeout(FORWARD_IDLE, body.frame()).await {
            Ok(Some(Ok(frame))) => Some((Ok::<_, Infallible>(frame), body)),
            _ => None,
        }
    });
    builder.body(StreamBody::new(frames).boxed()).unwrap()
}

/// Sends a stream: Roc runs it to its end in a call of its own, writing each event to the response
/// as it goes (`hosted::call`, with the response), and pausing between them (it holds no thread
/// while it waits). When the client goes, the stream's next `send!` says so, and a `sleep!` ends
/// early.
async fn send_events(feed: Feed, out: mpsc::Sender<Bytes>) {
    let sent = coroutine::run(move || hosted::call(Some(out), || roc::stream(feed))).await;
    if let Ok(Err(crash)) = sent {
        logging::error("rocx server: a stream crashed", &[("error", crash.0.into())]);
    }
}

/// How long what the server sent may go unacknowledged before the connection is dropped: a client
/// whose network went (no FIN ever comes) is noticed at the next write to it, a channel stream's
/// beat (`--live-beat-ms`), and gone about 20 s later, its subscriptions' `on_close!` told. Linux's
/// `TCP_USER_TIMEOUT`, macOS's `TCP_RXT_CONNDROPTIME`; elsewhere, the system's own (minutes).
const UNACKNOWLEDGED: Duration = Duration::from_secs(20);

fn unacknowledged_deadline(stream: &tokio::net::TcpStream) {
    use std::os::fd::AsRawFd;
    #[cfg(target_os = "linux")]
    let (option, value) = (libc::TCP_USER_TIMEOUT, UNACKNOWLEDGED.as_millis() as libc::c_int);
    #[cfg(target_os = "macos")]
    let (option, value) = (0x80 as libc::c_int, UNACKNOWLEDGED.as_secs() as libc::c_int);
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    unsafe {
        libc::setsockopt(stream.as_raw_fd(), libc::IPPROTO_TCP, option, (&value as *const libc::c_int).cast(), std::mem::size_of::<libc::c_int>() as libc::socklen_t);
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let _ = stream;
}

/// The path and query Roc is given: a trailing slash dropped (`/syntax/` is `/syntax`), as the Node
/// server does.
fn target(uri: &hyper::Uri) -> String {
    let path = uri.path();
    let path = if path.len() > 1 { path.trim_end_matches('/') } else { path };
    let path = if path.is_empty() { "/" } else { path };
    match uri.query() {
        Some(query) => format!("{path}?{query}"),
        None => path.to_string(),
    }
}

fn percent_decoded(path: &str) -> String {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&path[index + 1..index + 3], 16) {
                out.push(byte);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
