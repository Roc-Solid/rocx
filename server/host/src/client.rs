//! `Http` (`server/platform/Http.roc`): requests to other servers, over HTTP/1.1, plain or over TLS
//! (rustls, checked against the web's certificate authorities: `tls`). hyper's client makes each
//! exchange on a connection of its own; redirects are followed here, as `fetch` follows them.
//!
//! `open` makes a request and gives back the answer with its body still to come, so a body may be
//! streamed somewhere else as it arrives, never held whole (a `Forward` answer: `http::forwarded`).
//! `fetch` reads it whole, within a time limit and a size limit: what Roc gets.

use bytes::Bytes;
use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
use hyper::body::Incoming;
use hyper::header::{HeaderName, HeaderValue};
use hyper::{Method, Request, Response, StatusCode, Uri};
use hyper_util::rt::TokioIo;
use std::error::Error;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;

/// How many redirects are followed before giving up, as `fetch`'s.
const MAX_REDIRECTS: usize = 20;

/// A request to make.
#[derive(Clone)]
pub struct Outbound {
    pub method: Method,
    pub url: String,
    /// Each name and value as given; `host` is added unless given.
    pub headers: Vec<(String, String)>,
    pub body: Bytes,
}

impl Outbound {
    /// A request from what Roc gives: the method, the URL, a header a line (`name: value`), the body.
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
        Ok(Outbound { method, url: url.to_string(), headers, body: Bytes::from(body) })
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

/// One exchange, on a connection of its own: no redirect followed.
async fn once(outbound: &Outbound, uri: &Uri) -> Result<Response<Incoming>, String> {
    let host = uri.host().unwrap_or_default();
    // An IPv6 address is written in brackets in a URL, but not when connecting.
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    let port = port_of(uri);
    let tcp = TcpStream::connect((bare, port)).await.map_err(|error| format!("{bare}:{port}: {error}"))?;
    tcp.set_nodelay(true).ok();
    let io: Box<dyn Io> = if uri.scheme_str() == Some("https") {
        let name = rustls::pki_types::ServerName::try_from(bare.to_string()).map_err(|error| format!("{bare}: {error}"))?;
        let connector = tokio_rustls::TlsConnector::from(crate::tls::http_config());
        Box::new(connector.connect(name, tcp).await.map_err(|error| format!("TLS with {bare}: {}", described(&error)))?)
    } else {
        Box::new(tcp)
    };
    let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(io)).await.map_err(|error| format!("{}: {}", outbound.url, described(&error)))?;
    // The connection is driven on its own task, for as long as the answer's body is being read.
    tokio::spawn(async move {
        let _ = connection.await;
    });

    let target = uri.path_and_query().map(|path| path.as_str()).unwrap_or("/");
    let mut request = Request::builder().method(outbound.method.clone()).uri(target);
    let given = |wanted: &str| outbound.headers.iter().any(|(name, _)| name.eq_ignore_ascii_case(wanted));
    if !given("host") {
        let default = port_of(uri) == if uri.scheme_str() == Some("https") { 443 } else { 80 };
        request = request.header(hyper::header::HOST, if default || uri.port().is_none() { host.to_string() } else { format!("{host}:{port}") });
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
    let request = request.body(Full::new(outbound.body.clone())).map_err(|error| format!("{}: {error}", outbound.url))?;
    sender.send_request(request).await.map_err(|error| format!("{}: {}", outbound.url, described(&error)))
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
