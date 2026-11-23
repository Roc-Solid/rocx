//! The HTTP server: plugins' files (`files`) and files from disk as they are, everything else
//! answered by the Roc app. A call into Roc runs on one of Roc's threads, as a coroutine that
//! pauses while its effects wait (`coroutine`); a page of components is rendered there, in the same call; a stream of events
//! (`text/event-stream`) is a loop Roc runs in a call of its own, writing to the response as it
//! goes; a forwarded answer's body is fetched from elsewhere (`client::open`) and sent on as it
//! comes, never through Roc.

use crate::roc::{self, Feed};
use crate::{blobs, channels, client, coroutine, hosted, logging, signals};
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
use std::net::{IpAddr, SocketAddr};
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
    /// How long an actor waits with nothing to do before it is let go (0: never), with a database.
    pub actor_idle_ms: u64,
    /// The most the key-value store (`Kv`) keeps, in MiB, before the least recently used goes.
    pub kv_max_mb: u64,
    /// Where the app is, as the world reaches it (`--public-url`, `PUBLIC_URL`): `Env.public_url!`.
    /// Without it, where the server listens.
    pub public_url: Option<String>,
    /// Pages reload when the server restarts (after a rebuild); crashes show their message; plugins'
    /// early paths under it answer (the dev mailbox at `GET /__rocx/mail`: packages/email).
    pub dev: bool,
    /// `GET /__rocx/allocations` (how many allocations Roc holds now), `GET /__rocx/plugin-files`
    /// (the plugins' files: what a static copy of a site copies), and plugins' early paths under it
    /// (the mailbox as JSON, `/__rocx/mail.json`), for tests.
    pub debug: bool,
    /// How often a channel stream (`/rocx/live`) beats: a comment, and its channels' checks again.
    pub live_beat: Duration,
    /// How many threads Roc runs on (`--roc-threads`, `ROCX_ROC_THREADS`; one a core unless they
    /// say): a call that waits holds none (`coroutine`).
    pub roc_threads: usize,
    /// `--describe-sql FILE` (D-058): the server doesn't answer HTTP. It applies the program's
    /// migrations to a scratch database of the app's kind, prepares each statement the file lists,
    /// prints what the database says of each, and exits (`check`).
    pub describe_sql: Option<PathBuf>,
    /// `--sql-database URL` (`ROCX_SQL_DATABASE`): a database the check may migrate, named for it,
    /// in place of the scratch one it makes.
    pub sql_database: Option<String>,
}

pub const USAGE: &str = "usage: <app> [options]
  --port 8080 --host 127.0.0.1         where to listen (PORT)
  --static DIR, --file /PATH=FILE      files served as they are
  --context-file FILE                  what respond! is given besides each request
  --database-url URL                   the database (DATABASE_URL): postgres://…, or sqlite:<path> (turso:<path>) for a SQLite (Turso) app's file elsewhere
  --actor-idle-ms 900000               an actor idle this long is let go (0: never; kept in the database)
  --kv-max-mb 64                       the key-value store's limit (KV_MAX_MB): the least recently used goes past it
  --public-url https://app.example     where the app is, for links it sends (PUBLIC_URL; else where it listens)
  --dev                                reload pages on restart, show crashes, plugins' dev pages (/__rocx/mail)
  --debug                              GET /__rocx/allocations and /__rocx/plugin-files, and plugins' debug paths
  --live-beat-ms 15000                 how often a channel stream beats, and its checks run again
  --roc-threads N                      the threads Roc runs on (ROCX_ROC_THREADS; one a core)
  --describe-sql FILE                  answer no HTTP: describe each statement FILE lists (a JSON array of SQL) on a scratch
                                       database the program's migrations are applied to, print what the database says, exit
  --sql-database URL                   for --describe-sql, a database it may migrate, in place of a scratch one (ROCX_SQL_DATABASE)";

impl Config {
    pub fn parse(args: Vec<String>) -> Result<Config, String> {
        let env = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        let mut port: u16 = env("PORT").and_then(|port| port.parse().ok()).unwrap_or(8080);
        let mut host = "127.0.0.1".to_string();
        let mut statics = Vec::new();
        let mut files = Vec::new();
        let mut context = String::new();
        let mut database_url = env("DATABASE_URL");
        let mut actor_idle_ms = 15 * 60 * 1000;
        let mut kv_max_mb = env("KV_MAX_MB").and_then(|text| text.parse().ok()).unwrap_or(64);
        let mut public_url = env("PUBLIC_URL");
        let mut dev = false;
        let mut debug = false;
        let mut live_beat_ms: u64 = 15_000;
        let mut roc_threads = match env("ROCX_ROC_THREADS") {
            Some(given) => given.trim().parse().ok().filter(|count| *count > 0).ok_or_else(|| format!("ROCX_ROC_THREADS needs a number above 0, not {given:?}"))?,
            None => crate::coroutine::default_threads(),
        };
        let mut describe_sql = None;
        let mut sql_database = env("ROCX_SQL_DATABASE");
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
                "--job-workers" | "--job-retry-ms" => return Err(format!("{arg} is gone: jobs are a plugin (packages/jobs, D-034), whose options say how many workers run and how long a failed job waits: Job.plugin({{ jobs, workers, retry_ms }})")),
                "--actor-idle-ms" => actor_idle_ms = value()?.parse().map_err(|_| "--actor-idle-ms needs a number".to_string())?,
                "--smtp-url" | "--mail-from" => return Err(format!("{arg} is gone: email is a plugin (packages/email, D-035), which reads SMTP_URL and MAIL_FROM from the environment (or its options say)")),
                "--kv-max-mb" => kv_max_mb = value()?.parse().map_err(|_| "--kv-max-mb needs a number".to_string())?,
                "--public-url" => public_url = Some(value()?),
                "--dev" => dev = true,
                "--debug" => debug = true,
                "--live-beat-ms" => live_beat_ms = value()?.parse().ok().filter(|ms| *ms > 0).ok_or("--live-beat-ms needs a number above 0")?,
                "--roc-threads" => roc_threads = value()?.parse().ok().filter(|count| *count > 0).ok_or("--roc-threads needs a number above 0")?,
                "--blocking-threads" => return Err("--blocking-threads is gone: a call into Roc holds no thread while it waits (D-027); --roc-threads (ROCX_ROC_THREADS) says how many threads Roc runs on".into()),
                "--describe-sql" => describe_sql = Some(PathBuf::from(value()?)),
                "--sql-database" => sql_database = Some(value()?),
                "--help" | "-h" => return Err(USAGE.into()),
                other => return Err(format!("unknown argument {other} (--help lists them)")),
            }
        }
        let address = format!("{host}:{port}").parse().map_err(|error| format!("{host}:{port}: {error}"))?;
        let live_beat = Duration::from_millis(live_beat_ms);
        let public_url = public_url.map(|url| public(&url)).transpose()?;
        Ok(Config { address, statics, files, context, database_url, actor_idle_ms, kv_max_mb, public_url, dev, debug, live_beat, roc_threads, describe_sql, sql_database })
    }
}

/// A public URL as given (`--public-url`, `PUBLIC_URL`): an http(s) URL, without the `/` at its end.
fn public(url: &str) -> Result<String, String> {
    let trimmed = url.trim().trim_end_matches('/');
    let host = trimmed.strip_prefix("https://").or_else(|| trimmed.strip_prefix("http://"));
    match host {
        Some(host) if !host.is_empty() && !host.contains(char::is_whitespace) => Ok(trimmed.to_string()),
        _ => Err(format!("--public-url (PUBLIC_URL) needs an http:// or https:// URL, not {url:?}")),
    }
}

/// Where the server listens, as a URL (`http://127.0.0.1:8080`): its own address, the port it was
/// given (the system's, for `--port 0`); an address that is every one of the machine's is this
/// machine's loopback, the one it can surely be reached at.
pub fn listening_url(address: SocketAddr) -> String {
    let ip = match address.ip() {
        IpAddr::V4(ip) if ip.is_unspecified() => IpAddr::V4(std::net::Ipv4Addr::LOCALHOST),
        IpAddr::V6(ip) if ip.is_unspecified() => IpAddr::V6(std::net::Ipv6Addr::LOCALHOST),
        ip => ip,
    };
    format!("http://{}", SocketAddr::new(ip, address.port()))
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
                let Ok((stream, address)) = accepted else { continue };
                unacknowledged_deadline(&stream);
                let config = config.clone();
                let peer = peer_of(address);
                let service = service_fn(move |request| answer(request, config.clone(), peer.clone()));
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

// Under --dev, every page loads the reload script. It is a file (`/__reload.js`), not inline, so a
// CSP that allows only the site's own scripts (`script-src 'self'`, as packages/guard's does)
// allows it too. A page in a frame (a story in the dev catalog, beside others) leaves reloading to
// the page around it, which reloads it too: each held stream is one of the six connections a
// browser makes to a host, and a seventh frame's would wait for one forever.
const RELOAD: &str = r#"<script src="/__reload.js" data-rocx></script>"#;
const RELOAD_JS: &str = r#"if(window.top===window){let gone=false;const at=new EventSource("/__reload");at.onerror=()=>{gone=true};at.onopen=()=>{if(gone)location.reload()}}"#;

fn full(status: StatusCode, content_type: &str, body: impl Into<Bytes>) -> Response<Body> {
    let mut response = Response::new(Full::new(body.into()).boxed());
    *response.status_mut() = status;
    response.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_str(content_type).unwrap());
    response
}

/// The address a connection came from, as `Server.Request`'s `peer` has it: the IP alone (no port),
/// an IPv4 client of a dual-stack listener as IPv4 (`203.0.113.7`, not `::ffff:203.0.113.7`).
fn peer_of(address: SocketAddr) -> String {
    address.ip().to_canonical().to_string()
}

async fn answer(request: Request<Incoming>, config: Arc<Config>, peer: String) -> Result<Response<Body>, Infallible> {
    let path = percent_decoded(request.uri().path());
    if config.dev && path == "/__reload" {
        // Never sends: a page notices the server went (a rebuild) when this breaks, and reloads
        // when it can connect again.
        let mut response = Response::new(StreamBody::new(futures_util::stream::pending::<Result<Frame<Bytes>, Infallible>>()).boxed());
        response.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
        return Ok(response);
    }
    if config.dev && path == "/__reload.js" {
        let mut response = full(StatusCode::OK, "text/javascript", RELOAD_JS);
        response.headers_mut().insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
        return Ok(response);
    }
    // A plugin's file (D-050): before the app and its middleware, so a guard never blocks a
    // service worker or a page's script.
    if let Some(response) = crate::files::answer(&request, &path, config.dev) {
        return Ok(response);
    }
    if config.debug && path == "/__rocx/plugin-files" {
        return Ok(full(StatusCode::OK, "application/json", crate::files::listed()));
    }
    // The tab's stream of its channels, and what its pages say on them: the host's, not Roc's
    // (Roc runs only briefly, for each channel's check and hooks: `channels`).
    if path == "/rocx/live" {
        return Ok(channels::stream(request, &config, peer));
    }
    if path == "/rocx/live/send" {
        return Ok(channels::send(request, config, peer).await);
    }
    if config.debug && path == "/__rocx/allocations" {
        return Ok(full(StatusCode::OK, "text/plain", roc::live_allocations().to_string()));
    }
    if matches!(*request.method(), Method::GET | Method::HEAD) {
        if let Some(response) = file(&config, &path).await {
            return Ok(response);
        }
    }
    Ok(from_roc(request, config, peer).await)
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

/// A file's content type, from its name's extension.
pub fn content_type(path: &Path) -> &'static str {
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
async fn from_roc(request: Request<Incoming>, config: Arc<Config>, peer: String) -> Response<Body> {
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
    let answering = hosted::Asked::new(method.as_str(), target, headers.trim_end_matches('\n').to_string(), body, peer, config.context.clone(), config.dev);
    let answered = coroutine::run(move || {
        hosted::call_asking(answering.clone(), || {
            let mut answer = roc::respond(&answering)?;
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
    if let Some((root, key, questions)) = answer.stored {
        // What the request record asks of it, as the app passed it on (`Server.stored`).
        let asked_for = |wanted: &str| {
            questions.lines().find_map(|line| line.split_once(": ").filter(|(name, _)| name.eq_ignore_ascii_case(wanted)).map(|(_, value)| value.to_string()))
        };
        let conditions = Conditions { range: asked_for("range"), if_none_match: asked_for("if-none-match") };
        return stored(root, key, &answer.headers, &method, &asked, conditions).await;
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

/// What a request asks of a stored object's answer: a range, and whether it has a copy already.
struct Conditions {
    range: Option<String>,
    if_none_match: Option<String>,
}

/// An object the host keeps (`Server.stored`: packages/storage's `file:` and `memory:` buckets,
/// D-047), sent as it is, never through Roc: its length, type, ETag and `last-modified`, and the
/// answer's own headers (in place of those); 304 when the request's `If-None-Match` meets its ETag;
/// 206 and the bytes asked for, for one range (416 for one past its end; several, or one that can't
/// be read, is the whole object); 404 when there is none.
async fn stored(root: String, key: String, own: &str, method: &Method, asked: &str, conditions: Conditions) -> Response<Body> {
    let found = tokio::task::spawn_blocking(move || blobs::root(&root).and_then(|root| blobs::find(&root, &key))).await;
    let found = match found {
        Ok(Ok(found)) => found,
        Ok(Err(why)) if why == blobs::NOT_FOUND => return full(StatusCode::NOT_FOUND, "text/plain; charset=utf-8", "Not Found"),
        Ok(Err(why)) => {
            logging::error("rocx server: a stored object couldn't be read", &[("target", asked.into()), ("error", why.as_str().into())]);
            return full(StatusCode::INTERNAL_SERVER_ERROR, "text/plain; charset=utf-8", "the object couldn't be read");
        }
        Err(_) => return full(StatusCode::INTERNAL_SERVER_ERROR, "text/plain; charset=utf-8", "the object couldn't be read"),
    };
    let info = match &found {
        blobs::Found::File(_, info) | blobs::Found::Memory(_, info) => info.clone(),
    };
    let etag = format!("\"{}\"", info.etag);
    let modified = chrono::DateTime::<chrono::Utc>::from(info.modified).format("%a, %d %b %Y %H:%M:%S GMT").to_string();
    // The object's headers, then the answer's own in place of any of them.
    let mut headers: Vec<(String, String)> = vec![
        ("content-type".into(), info.content_type.clone()),
        ("accept-ranges".into(), "bytes".into()),
        ("etag".into(), etag.clone()),
        ("last-modified".into(), modified),
    ];
    for line in own.lines() {
        let Some((name, value)) = line.split_once(": ") else { continue };
        let name = name.to_ascii_lowercase();
        headers.retain(|(kept, _)| *kept != name);
        headers.push((name, value.to_string()));
    }
    let answer = |status: StatusCode, more: Vec<(String, String)>| {
        let mut builder = Response::builder().status(status);
        for (name, value) in headers.iter().chain(more.iter()) {
            if let (Ok(name), Ok(value)) = (HeaderName::from_bytes(name.as_bytes()), HeaderValue::from_str(value)) {
                builder = builder.header(name, value);
            }
        }
        builder
    };
    let met = conditions.if_none_match.as_deref().is_some_and(|given| given.split(',').any(|tag| {
        let tag = tag.trim();
        tag == "*" || tag.trim_start_matches("W/") == etag
    }));
    if met {
        return answer(StatusCode::NOT_MODIFIED, vec![]).body(Full::new(Bytes::new()).boxed()).unwrap();
    }
    let size = info.size;
    let (status, start, length, more) = match conditions.range.as_deref().and_then(|range| one_range(range, size)) {
        Some(Ok((start, end))) => (StatusCode::PARTIAL_CONTENT, start, end - start + 1, vec![("content-range".to_string(), format!("bytes {start}-{end}/{size}"))]),
        Some(Err(())) => {
            return answer(StatusCode::RANGE_NOT_SATISFIABLE, vec![("content-range".into(), format!("bytes */{size}"))]).body(Full::new(Bytes::new()).boxed()).unwrap();
        }
        None => (StatusCode::OK, 0, size, vec![]),
    };
    let builder = answer(status, more).header(hyper::header::CONTENT_LENGTH, length);
    if *method == Method::HEAD || length == 0 {
        return builder.body(Full::new(Bytes::new()).boxed()).unwrap();
    }
    match found {
        blobs::Found::Memory(bytes, _) => builder.body(Full::new(bytes.slice(start as usize..(start + length) as usize)).boxed()).unwrap(),
        blobs::Found::File(path, _) => {
            use tokio::io::{AsyncReadExt, AsyncSeekExt};
            let file = match tokio::fs::File::open(&path).await {
                Ok(mut file) => match file.seek(std::io::SeekFrom::Start(start)).await {
                    Ok(_) => file,
                    Err(_) => return full(StatusCode::INTERNAL_SERVER_ERROR, "text/plain; charset=utf-8", "the object couldn't be read"),
                },
                Err(_) => return full(StatusCode::INTERNAL_SERVER_ERROR, "text/plain; charset=utf-8", "the object couldn't be read"),
            };
            // A chunk at a time, as the client takes them; a file that fails to read ends the body.
            let chunks = futures_util::stream::unfold((file, length), |(mut file, left)| async move {
                if left == 0 {
                    return None;
                }
                let mut buffer = vec![0u8; left.min(64 * 1024) as usize];
                match file.read(&mut buffer).await {
                    Ok(0) | Err(_) => None,
                    Ok(read) => {
                        buffer.truncate(read);
                        Some((Ok::<_, Infallible>(Frame::data(Bytes::from(buffer))), (file, left - read as u64)))
                    }
                }
            });
            builder.body(StreamBody::new(chunks).boxed()).unwrap()
        }
    }
}

/// The one range `range` asks for of `size` bytes (`bytes=0-99`, `bytes=100-`, `bytes=-100`): its
/// first and last byte; `Err` when it starts past the end; `None` for several, or one that can't
/// be read (the whole object is sent).
fn one_range(range: &str, size: u64) -> Option<Result<(u64, u64), ()>> {
    let spec = range.trim().strip_prefix("bytes=")?;
    if spec.contains(',') {
        return None;
    }
    let (first, last) = spec.split_once('-')?;
    let (first, last) = (first.trim(), last.trim());
    if first.is_empty() {
        let suffix: u64 = last.parse().ok()?;
        if suffix == 0 || size == 0 {
            return Some(Err(()));
        }
        return Some(Ok((size.saturating_sub(suffix), size - 1)));
    }
    let start: u64 = first.parse().ok()?;
    if start >= size {
        return Some(Err(()));
    }
    let end = if last.is_empty() { size - 1 } else { last.parse::<u64>().ok()?.min(size - 1) };
    if end < start {
        return None;
    }
    Some(Ok((start, end)))
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
