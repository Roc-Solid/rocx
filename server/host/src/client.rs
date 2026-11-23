//! `Http` (`server/platform/Http.roc`): requests to other servers, over HTTP/1.1, plain or over TLS
//! (rustls, checked against the web's certificate authorities: `tls`), directly or through a proxy
//! (`proxy`); redirects are followed here, as `fetch` follows them.
//!
//! Connections are kept alive: a pool of idle ones a place (a scheme, host and port, and the proxy
//! on the way), each kept 30 s with nothing to do, or a second less than its server says it keeps
//! one (`keep-alive: timeout=5`), 32 at most a place; any number are open at once. A connection goes
//! back to the pool once its answer's body has been read to its end (a body dropped part-read, as
//! one over `max_bytes` is, is drained if the rest of it has come already, and its connection closed
//! if not).
//! A request on a kept connection that its server closed meanwhile is made again on a new one, once:
//! when it was never sent, or when its method is idempotent (GET, HEAD, OPTIONS, TRACE, PUT,
//! DELETE, or an `idempotency-key` says so), as Go's client does.
//!
//! A proxy: an `http://` URL's request is sent to it whole (the absolute URL in its first line, and
//! `proxy-authorization` from the proxy URL's user and password); an `https://` URL's goes through a
//! tunnel (`CONNECT host:443`), with TLS to the server inside it, so the proxy sees nothing of it.
//! A proxy may be `https://` itself: TLS to the proxy, then the same.
//!
//! `open` makes a request and gives back the answer with its body still to come, so a body may be
//! streamed somewhere else as it arrives, never held whole (a `Forward` answer: `http::forwarded`).
//! `fetch` reads it whole, within a time limit and a size limit: what Roc gets from `Http.fetch!`.
//! `open_chunked` keeps the body for Roc to read a chunk at a time (`chunk`, `Http.fetch_chunks!`),
//! within the same limits, the time limit counted from the request to the body's last byte.

use crate::proxy::{self, Proxy};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
use hyper::body::Incoming;
use hyper::client::conn::http1::SendRequest;
use hyper::header::{HeaderName, HeaderValue};
use hyper::{Method, Request, Response, StatusCode, Uri};
use hyper_util::rt::TokioIo;
use std::collections::HashMap;
use std::error::Error;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;

/// How many redirects are followed before giving up, as `fetch`'s.
const MAX_REDIRECTS: usize = 20;

/// How long a connection is kept with nothing to do, unless its server says it keeps one for less.
const IDLE: Duration = Duration::from_secs(30);

/// The most idle connections kept to one place; past it, the one idle longest goes.
const IDLE_PER_PLACE: usize = 32;

/// Which proxy a request goes through (`Http.Init`'s `proxy`).
#[derive(Clone, Debug)]
pub enum Via {
    /// The environment's: `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` (`proxy`).
    FromEnv,
    /// None.
    Direct,
    /// This one, for every host.
    Proxy(String),
}

/// A request to make.
#[derive(Clone)]
pub struct Outbound {
    pub method: Method,
    pub url: String,
    /// Each name and value as given; `host` is added unless given.
    pub headers: Vec<(String, String)>,
    pub body: Bytes,
    pub via: Via,
}

impl Outbound {
    /// A request from what Roc gives: the method, the URL, a header a line (`name: value`), the body;
    /// through the environment's proxy, if it names one (`via` says otherwise).
    pub fn new(method: &str, url: &str, headers: &str, body: Vec<u8>) -> Result<Outbound, String> {
        let method = Method::from_bytes(method.as_bytes()).map_err(|_| format!("{method} isn't a method"))?;
        let headers = headers
            .lines()
            .filter(|line| !line.is_empty())
            .map(|line| match line.split_once(':') {
                Some((name, value)) => Ok((name.trim().to_string(), value.trim().to_string())),
                None => Err(format!("a header without a value: {line}")),
            })
            .collect::<Result<_, _>>()?;
        Ok(Outbound { method, url: url.to_string(), headers, body: Bytes::from(body), via: Via::FromEnv })
    }

    /// The same request, through `via`: what Roc says, `env` (the environment's proxy), `direct`
    /// (none), or `via <url>` (that one).
    pub fn through(mut self, via: &str) -> Result<Outbound, String> {
        self.via = match via {
            "" | "env" => Via::FromEnv,
            "direct" => Via::Direct,
            _ => match via.strip_prefix("via ") {
                Some(url) => Via::Proxy(url.to_string()),
                None => return Err(format!("{via:?} isn't a proxy: env, direct, or via <url>")),
            },
        };
        Ok(self)
    }
}

/// What a fetch may come to besides an answer.
pub enum Failure {
    /// No answer: the address, the connection, TLS, or HTTP itself.
    Http(String),
    /// No whole answer within the time allowed.
    TimedOut,
    /// A body larger than allowed.
    TooLarge,
}

/// An answer, read whole.
pub struct Fetched {
    pub status: u16,
    /// A header a line, `name: value`.
    pub headers: String,
    pub body: Vec<u8>,
}

/// Makes `outbound` and reads its answer whole: given up after `timeout` (`None`: never), refused
/// if its body is over `max_bytes` (`None`: any size). A redirect is followed if `follow`, or is the
/// answer. Any status is an answer.
pub async fn fetch(outbound: Outbound, timeout: Option<Duration>, max_bytes: Option<u64>, follow: bool) -> Result<Fetched, Failure> {
    let exchange = async {
        let head = outbound.method == Method::HEAD;
        let response = open(outbound, follow).await.map_err(Failure::Http)?;
        let status = response.status().as_u16();
        let headers: String = response
            .headers()
            .iter()
            .map(|(name, value)| format!("{}: {}\n", name.as_str(), String::from_utf8_lossy(value.as_bytes())))
            .collect();
        // The answer to a HEAD (or a 204 or 304) has no body: its `content-length` is the size of
        // what a GET would get (S3's HEAD says how large an object is), not of anything to read.
        let bodiless = head || status == 204 || status == 304;
        let declared = response
            .headers()
            .get(hyper::header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok()?.parse::<u64>().ok())
            .filter(|_| !bodiless);
        let body = response.into_body();
        let body = match max_bytes {
            Some(max) if declared.is_some_and(|length| length > max) => return Err(Failure::TooLarge),
            Some(max) => Limited::new(body, usize::try_from(max).unwrap_or(usize::MAX)).collect().await.map_err(|error| {
                if error.is::<LengthLimitError>() { Failure::TooLarge } else { Failure::Http(format!("reading the answer: {}", described(&*error))) }
            })?,
            None => body.collect().await.map_err(|error| Failure::Http(format!("reading the answer: {}", described(&error))))?,
        };
        Ok(Fetched { status, headers: headers.trim_end_matches('\n').to_string(), body: body.to_bytes().to_vec() })
    };
    match timeout {
        Some(limit) => tokio::time::timeout(limit, exchange).await.unwrap_or(Err(Failure::TimedOut)),
        None => exchange.await,
    }
}

/// An answer whose body Roc reads a chunk at a time (`chunk`): when its time is up, and how many
/// more bytes it may have.
struct Chunked {
    body: Incoming,
    until: Option<Instant>,
    left: Option<u64>,
}

/// The answers being read in chunks, by id. An id is its call's (`hosted` keeps the call's list,
/// and lets go of what is left of them when the call ends).
static CHUNKED: LazyLock<Mutex<HashMap<u64, Chunked>>> = LazyLock::new(Mutex::default);
static NEXT_CHUNKED: AtomicU64 = AtomicU64::new(1);

/// Makes `outbound`, as `fetch` does, and keeps its answer's body to be read in chunks (`chunk`):
/// an id for it, the status, and the headers (a `name: value` a line). The time limit runs from
/// now to the body's last byte; a body whose `content-length` is over `max_bytes` is refused here.
pub async fn open_chunked(outbound: Outbound, timeout: Option<Duration>, max_bytes: Option<u64>, follow: bool) -> Result<(u64, u16, String), Failure> {
    let until = timeout.map(|limit| Instant::now() + limit);
    let head = outbound.method == Method::HEAD;
    let opening = open(outbound, follow);
    let response = match until {
        Some(at) => tokio::time::timeout_at(at.into(), opening).await.map_err(|_| Failure::TimedOut)?,
        None => opening.await,
    }
    .map_err(Failure::Http)?;
    let status = response.status().as_u16();
    let headers: String = response
        .headers()
        .iter()
        .map(|(name, value)| format!("{}: {}\n", name.as_str(), String::from_utf8_lossy(value.as_bytes())))
        .collect();
    let bodiless = head || status == 204 || status == 304;
    let declared = response.headers().get(hyper::header::CONTENT_LENGTH).and_then(|value| value.to_str().ok()?.parse::<u64>().ok()).filter(|_| !bodiless);
    if max_bytes.is_some_and(|max| declared.is_some_and(|length| length > max)) {
        return Err(Failure::TooLarge);
    }
    let id = NEXT_CHUNKED.fetch_add(1, Ordering::Relaxed);
    CHUNKED.lock().unwrap().insert(id, Chunked { body: response.into_body(), until, left: max_bytes });
    Ok((id, status, headers.trim_end_matches('\n').to_string()))
}

/// The next chunk of the body kept as `id` (`open_chunked`), as it comes: empty at its end, when it
/// is let go, as it is after an error.
pub async fn chunk(id: u64) -> Result<Vec<u8>, Failure> {
    let Some(mut chunked) = CHUNKED.lock().unwrap().remove(&id) else {
        return Err(Failure::Http("that answer's body was read to its end, or let go".into()));
    };
    let next = match chunked.until {
        Some(at) => tokio::time::timeout_at(at.into(), data(&mut chunked.body)).await.unwrap_or(Err(Failure::TimedOut)),
        None => data(&mut chunked.body).await,
    };
    let Some(data) = next? else { return Ok(Vec::new()) };
    if let Some(left) = &mut chunked.left {
        *left = left.checked_sub(data.len() as u64).ok_or(Failure::TooLarge)?;
    }
    CHUNKED.lock().unwrap().insert(id, chunked);
    Ok(data.to_vec())
}

/// Lets go of a body kept to be read in chunks: what has come of it is drained, or its connection
/// closed (`checkin`).
pub fn let_go(id: u64) {
    CHUNKED.lock().unwrap().remove(&id);
}

/// A body's next bytes (trailers skipped), or `None` at its end.
async fn data(body: &mut Incoming) -> Result<Option<Bytes>, Failure> {
    loop {
        match body.frame().await {
            None => return Ok(None),
            Some(Err(error)) => return Err(Failure::Http(format!("reading the answer: {}", described(&error)))),
            Some(Ok(frame)) => match frame.into_data() {
                Ok(data) if !data.is_empty() => return Ok(Some(data)),
                _ => {}
            },
        }
    }
}

/// Makes `outbound`, following redirects if `follow`: the answer, its body still to come (it
/// streams as it is read). Any status is an answer; an error means there was none.
pub async fn open(mut outbound: Outbound, follow: bool) -> Result<Response<Incoming>, String> {
    let mut uri = parse(&outbound.url)?;
    for _ in 0..=MAX_REDIRECTS {
        let response = once(&outbound, &uri).await?;
        let status = response.status();
        let location = response.headers().get(hyper::header::LOCATION).and_then(|value| value.to_str().ok());
        let (true, true, Some(location)) = (follow, status.is_redirection(), location) else { return Ok(response) };
        if !matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308) {
            return Ok(response);
        }
        let next = resolve(&uri, location)?;
        redirected(&mut outbound, status, &uri, &next);
        uri = next;
    }
    Err(format!("{}: more than {MAX_REDIRECTS} redirects", outbound.url))
}

/// The request a redirect asks for, as `fetch` makes it: a 303 (or a 301 or 302 to a POST) becomes
/// a GET without its body; credentials don't go to another origin.
fn redirected(outbound: &mut Outbound, status: StatusCode, from: &Uri, to: &Uri) {
    let code = status.as_u16();
    if (code == 303 && outbound.method != Method::HEAD) || (matches!(code, 301 | 302) && outbound.method == Method::POST) {
        outbound.method = Method::GET;
        outbound.body = Bytes::new();
        outbound.headers.retain(|(name, _)| {
            !["content-type", "content-length", "content-encoding", "content-language", "content-location"].iter().any(|each| name.eq_ignore_ascii_case(each))
        });
    }
    let same_origin = from.scheme_str() == to.scheme_str() && from.host() == to.host() && port_of(from) == port_of(to);
    if !same_origin {
        outbound.headers.retain(|(name, _)| !["authorization", "cookie", "proxy-authorization", "host"].iter().any(|each| name.eq_ignore_ascii_case(each)));
    }
    outbound.url = to.to_string();
}

/// An absolute `http` or `https` URL.
fn parse(url: &str) -> Result<Uri, String> {
    let uri: Uri = url.parse().map_err(|error| format!("{url}: {error}"))?;
    match uri.scheme_str() {
        Some("http" | "https") => {}
        _ => return Err(format!("{url}: only http and https URLs")),
    }
    if uri.host().is_none_or(str::is_empty) {
        return Err(format!("{url}: no host"));
    }
    Ok(uri)
}

/// Where a redirect's `location` points, from `base`: absolute, or relative to it.
fn resolve(base: &Uri, location: &str) -> Result<Uri, String> {
    let location = location.split('#').next().unwrap_or_default();
    let scheme = base.scheme_str().unwrap_or("http");
    let authority = base.authority().map(|authority| authority.as_str()).unwrap_or_default();
    let has_scheme = location.split_once(':').is_some_and(|(before, _)| {
        !before.is_empty() && before.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
    });
    let absolute = if has_scheme {
        location.to_string()
    } else if location.starts_with("//") {
        format!("{scheme}:{location}")
    } else if location.starts_with('/') {
        format!("{scheme}://{authority}{location}")
    } else if location.starts_with('?') {
        format!("{scheme}://{authority}{}{location}", base.path())
    } else {
        let path = base.path();
        let dir = &path[..path.rfind('/').map_or(0, |at| at + 1)];
        format!("{scheme}://{authority}{}{location}", if dir.is_empty() { "/" } else { dir })
    };
    parse(&absolute).map_err(|why| format!("a redirect to {location}: {why}"))
}

fn port_of(uri: &Uri) -> u16 {
    uri.port_u16().unwrap_or(if uri.scheme_str() == Some("https") { 443 } else { 80 })
}

trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}

/// Where a request goes: its scheme, its host (an IPv6 address without its brackets, in lower
/// case) and port, and the host as its `host` header writes it.
struct Place {
    https: bool,
    host: String,
    port: u16,
    authority: String,
}

impl Place {
    fn of(uri: &Uri) -> Place {
        let host = uri.host().unwrap_or_default();
        let port = port_of(uri);
        let https = uri.scheme_str() == Some("https");
        let default = port == if https { 443 } else { 80 };
        let authority = if default || uri.port().is_none() { host.to_string() } else { format!("{host}:{port}") };
        Place { https, host: host.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase(), port, authority }
    }

    /// `host:port`, as a tunnel asks for it.
    fn host_port(&self) -> String {
        if self.host.contains(':') { format!("[{}]:{}", self.host, self.port) } else { format!("{}:{}", self.host, self.port) }
    }
}

/// The proxy a request to `place` goes through, as `via` says: none, or one (an `Err` when the one
/// named can't be read).
fn proxy_for(via: &Via, place: &Place) -> Result<Option<Proxy>, String> {
    match via {
        Via::Direct => Ok(None),
        Via::Proxy(url) => proxy::parse(url, "proxy").map(Some),
        Via::FromEnv => proxy::environment().proxy_for(place.https, &place.host, place.port).transpose().map(|proxy| proxy.cloned()),
    }
}

type Sender = SendRequest<Full<Bytes>>;

/// The idle connections, a list a place (`key`), the one idle least last.
#[derive(Default)]
struct Pool {
    idle: HashMap<String, Vec<Idle>>,
    /// Whether a task is closing the connections idle too long (`sweep`).
    sweeping: bool,
}

struct Idle {
    sender: Sender,
    until: Instant,
}

static POOL: LazyLock<Mutex<Pool>> = LazyLock::new(Mutex::default);

/// An idle connection to `key`, still open and kept, if there is one.
fn checkout(key: &str) -> Option<Sender> {
    let mut pool = POOL.lock().unwrap();
    let list = pool.idle.get_mut(key)?;
    let now = Instant::now();
    let mut found = None;
    while let Some(idle) = list.pop() {
        if idle.until > now && !idle.sender.is_closed() && idle.sender.is_ready() {
            found = Some(idle.sender);
            break;
        }
    }
    if list.is_empty() {
        pool.idle.remove(key);
    }
    found
}

/// Keeps `sender`'s connection for the next request to `key`, for `keep` once it is idle: when the
/// answer it is giving has been read to its end. One closed before then (its server said
/// `connection: close`, or its body was dropped part-read) isn't kept.
fn checkin(key: String, mut sender: Sender, keep: Duration) {
    if keep.is_zero() {
        return;
    }
    tokio::spawn(async move {
        if sender.ready().await.is_err() {
            return;
        }
        let mut pool = POOL.lock().unwrap();
        let list = pool.idle.entry(key).or_default();
        if list.len() >= IDLE_PER_PLACE {
            list.remove(0);
        }
        list.push(Idle { sender, until: Instant::now() + keep });
        if !pool.sweeping {
            pool.sweeping = true;
            tokio::spawn(sweep());
        }
    });
}

/// Closes the connections idle past their time, every second, until none is left.
async fn sweep() {
    loop {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let mut pool = POOL.lock().unwrap();
        let now = Instant::now();
        pool.idle.retain(|_, list| {
            list.retain(|idle| idle.until > now && !idle.sender.is_closed());
            !list.is_empty()
        });
        if pool.idle.is_empty() {
            pool.sweeping = false;
            return;
        }
    }
}

/// How long a connection may be kept once idle, from its answer: 30 s, or a second less than its
/// server's `keep-alive: timeout=N` when that is shorter (0: not kept).
fn kept(response: &Response<Incoming>) -> Duration {
    let said = response.headers().get("keep-alive").and_then(|value| value.to_str().ok()).and_then(|value| {
        value.split(',').find_map(|part| {
            let (name, seconds) = part.trim().split_once('=')?;
            name.trim().eq_ignore_ascii_case("timeout").then(|| seconds.trim().parse::<u64>().ok()).flatten()
        })
    });
    match said {
        Some(seconds) => IDLE.min(Duration::from_secs(seconds.saturating_sub(1))),
        None => IDLE,
    }
}

/// Whether `outbound` may be made again after it may have reached its server: an idempotent method,
/// or a key that says the server takes it once.
fn idempotent(outbound: &Outbound) -> bool {
    matches!(outbound.method, Method::GET | Method::HEAD | Method::OPTIONS | Method::TRACE | Method::PUT | Method::DELETE)
        || outbound.headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("idempotency-key") || name.eq_ignore_ascii_case("x-idempotency-key"))
}

/// Whether `error` is a connection that went (its server closed it), not an answer that was wrong.
fn went(error: &hyper::Error) -> bool {
    use std::io::ErrorKind::{BrokenPipe, ConnectionAborted, ConnectionReset, UnexpectedEof};
    let mut source = error.source();
    let mut io = None;
    while let Some(cause) = source {
        if let Some(found) = cause.downcast_ref::<std::io::Error>() {
            io = Some(found.kind());
        }
        source = cause.source();
    }
    error.is_incomplete_message() || error.is_canceled() || error.is_closed() || io.is_some_and(|kind| matches!(kind, BrokenPipe | ConnectionAborted | ConnectionReset | UnexpectedEof))
}

/// One exchange, on a kept connection or a new one: no redirect followed.
async fn once(outbound: &Outbound, uri: &Uri) -> Result<Response<Incoming>, String> {
    let place = Place::of(uri);
    let proxy = proxy_for(&outbound.via, &place)?;
    // A plain request through a proxy is sent to it whole: any connection to it will do. One over
    // TLS goes through a tunnel of its own, to its place.
    let forwarded = proxy.as_ref().filter(|_| !place.https);
    let key = match (&proxy, place.https) {
        (None, _) => format!("{}://{}", if place.https { "https" } else { "http" }, place.host_port()),
        (Some(proxy), false) => format!("http via {}", proxy.key),
        (Some(proxy), true) => format!("https://{} via {}", place.host_port(), proxy.key),
    };
    // Made before a connection is taken: one that can't be sent leaves a kept connection kept.
    let mut request = request_for(outbound, uri, &place, forwarded)?;
    let (mut sender, mut reused) = match checkout(&key) {
        Some(sender) => (sender, true),
        None => (connect(&place, proxy.as_ref()).await?, false),
    };
    loop {
        match sender.try_send_request(request).await {
            Ok(response) => {
                let keep = kept(&response);
                checkin(key, sender, keep);
                return Ok(response);
            }
            Err(mut failed) => {
                let unsent = failed.take_message();
                let error = failed.into_error();
                // A kept connection its server closed meanwhile: once more, on a new one.
                if reused && (unsent.is_some() || (idempotent(outbound) && went(&error))) {
                    reused = false;
                    request = match unsent {
                        Some(request) => request,
                        None => request_for(outbound, uri, &place, forwarded)?,
                    };
                    sender = connect(&place, proxy.as_ref()).await?;
                    continue;
                }
                return Err(format!("{}: {}", outbound.url, described(&error)));
            }
        }
    }
}

/// The request to send for `outbound`: to `place`, or (`forwarded`) to that proxy, the URL whole.
fn request_for(outbound: &Outbound, uri: &Uri, place: &Place, forwarded: Option<&Proxy>) -> Result<Request<Full<Bytes>>, String> {
    let path = uri.path_and_query().map(|path| path.as_str()).unwrap_or("/");
    let target = match forwarded {
        Some(_) => format!("http://{}{path}", uri.authority().map(|authority| authority.as_str()).unwrap_or_default()),
        None => path.to_string(),
    };
    let mut request = Request::builder().method(outbound.method.clone()).uri(target);
    let given = |wanted: &str| outbound.headers.iter().any(|(name, _)| name.eq_ignore_ascii_case(wanted));
    if !given("host") {
        request = request.header(hyper::header::HOST, place.authority.as_str());
    }
    if let Some(authorization) = forwarded.and_then(|proxy| proxy.authorization.as_ref()).filter(|_| !given("proxy-authorization")) {
        request = request.header(hyper::header::PROXY_AUTHORIZATION, authorization.as_str());
    }
    let sends_body = !outbound.body.is_empty() || matches!(outbound.method, Method::POST | Method::PUT | Method::PATCH);
    if sends_body && !given("content-length") {
        request = request.header(hyper::header::CONTENT_LENGTH, outbound.body.len());
    }
    for (name, value) in &outbound.headers {
        let name = HeaderName::from_bytes(name.as_bytes()).map_err(|_| format!("{name:?} isn't a header's name"))?;
        let value = HeaderValue::from_str(value).map_err(|_| format!("{name}: {value:?} isn't a header's value"))?;
        request = request.header(name, value);
    }
    request.body(Full::new(outbound.body.clone())).map_err(|error| format!("{}: {error}", outbound.url))
}

/// A new connection to `place`, or through `proxy` to it, its HTTP driven on a task of its own for
/// as long as it is open.
async fn connect(place: &Place, proxy: Option<&Proxy>) -> Result<Sender, String> {
    let io: Box<dyn Io> = match proxy {
        None => {
            let tcp = tcp(&place.host, place.port).await?;
            if place.https { tls(Box::new(tcp), &place.host).await? } else { Box::new(tcp) }
        }
        Some(proxy) => {
            let tcp = tcp(&proxy.host, proxy.port).await.map_err(|why| format!("the proxy {}: {why}", proxy.shown))?;
            let to_proxy: Box<dyn Io> = if proxy.tls { tls(Box::new(tcp), &proxy.host).await.map_err(|why| format!("the proxy {}: {why}", proxy.shown))? } else { Box::new(tcp) };
            if place.https { tls(tunnel(to_proxy, place, proxy).await?, &place.host).await? } else { to_proxy }
        }
    };
    let (sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(io)).await.map_err(|error| format!("{}: {}", place.host_port(), described(&error)))?;
    tokio::spawn(async move {
        let _ = connection.await;
    });
    Ok(sender)
}

async fn tcp(host: &str, port: u16) -> Result<TcpStream, String> {
    let tcp = TcpStream::connect((host, port)).await.map_err(|error| format!("{host}:{port}: {error}"))?;
    tcp.set_nodelay(true).ok();
    Ok(tcp)
}

/// TLS over `io` with `host`, its certificate checked against the web's authorities.
async fn tls(io: Box<dyn Io>, host: &str) -> Result<Box<dyn Io>, String> {
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|error| format!("{host}: {error}"))?;
    let connector = tokio_rustls::TlsConnector::from(crate::tls::http_config());
    Ok(Box::new(connector.connect(name, io).await.map_err(|error| format!("TLS with {host}: {}", described(&error)))?))
}

/// A tunnel through `proxy` to `place` (`CONNECT host:port`): what is sent on it after a 2xx reaches
/// `place` as it is.
async fn tunnel(mut io: Box<dyn Io>, place: &Place, proxy: &Proxy) -> Result<Box<dyn Io>, String> {
    let to = place.host_port();
    let failed = |error: std::io::Error| format!("the proxy {}: {error}", proxy.shown);
    let mut asked = format!("CONNECT {to} HTTP/1.1\r\nhost: {to}\r\n");
    if let Some(authorization) = &proxy.authorization {
        asked.push_str(&format!("proxy-authorization: {authorization}\r\n"));
    }
    asked.push_str("\r\n");
    io.write_all(asked.as_bytes()).await.map_err(failed)?;
    // Its answer's head, a byte at a time: nothing after it may be read here, it is TLS's.
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() > 16 * 1024 {
            return Err(format!("the proxy {}: an answer to CONNECT whose head doesn't end", proxy.shown));
        }
        head.push(io.read_u8().await.map_err(failed)?);
    }
    let head = String::from_utf8_lossy(&head);
    let status = head.lines().next().unwrap_or_default().trim();
    match status.split_whitespace().nth(1).and_then(|code| code.parse::<u16>().ok()) {
        Some(200..=299) => Ok(io),
        _ => Err(format!("the proxy {} refused a tunnel to {to}: {status}", proxy.shown)),
    }
}

/// An error and what caused it, as one line.
fn described(error: &(dyn Error + 'static)) -> String {
    let mut said = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        let more = cause.to_string();
        if !said.contains(&more) {
            said = format!("{said}: {more}");
        }
        source = cause.source();
    }
    said
}
