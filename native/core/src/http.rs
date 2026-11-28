//! The phone's requests to the server (D-138): HTTP/1.1 over TCP, each request on a thread of its
//! own, its answer posted to the main thread (`crate::post`), which runs what waited for it.
//!
//! As a browser's `fetch` does it:
//! - **Redirects are followed** (301, 302, 303, 307 and 308, at most 20): a 303, and a 301 or 302 to
//!   a POST, go on as a GET without the body; a 307 or 308 as they were. The answer says where it
//!   ended (`url`) and whether it was redirected, as `Response.url` and `redirected` do. One to
//!   another site isn't followed: the answer is the redirect, its `url` where it goes.
//! - **Cookies** (`cookies.rs`): the jar's `cookie` header goes with every request, and every
//!   answer's `set-cookie`s are kept, a redirect's too (a sign-in's 303 sets the session).
//! - **Connections are kept alive**: one whose answer was read whole goes back to a small pool for its
//!   host, and the next request to it takes it; one the server closed meanwhile is found on the first
//!   read and the request sent again on a new one.
//! - **Timeouts**: 10 s to connect, 30 s for an answer to begin or go on.
//! - **Streams** (`stream`): an answer read as it comes (server-sent events, `text/event-stream`),
//!   for `listen!` and the channels' `/rocx/live` (D-140), each event posted as it is read.
//!
//! Plain `http://` only: the emulator and `adb reverse` reach the dev server so. HTTPS (rustls with
//! the platform's roots) and gzip (the rocx server sends neither compressed) aren't here yet.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::url::Url;

/// An answer: its status, headers (names lowercase), body, where it ended, and whether a redirect
/// took it there.
#[derive(Clone, Debug, Default)]
pub struct Answered {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub url: String,
    pub redirected: bool,
}

impl Answered {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(each, _)| each.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
    }
}

const CONNECT: Duration = Duration::from_secs(10);
const ANSWER: Duration = Duration::from_secs(30);
/// How long a kept connection may wait for its next request (below the server's own keep-alive).
const IDLE: Duration = Duration::from_secs(20);
const POOLED: usize = 6;

/// Sends a request on a thread of its own; its answer or why there is none comes back as
/// `Message::Answer(id, …)`. `retry`: a refused connection is tried again for a while (`connect`).
pub fn send(id: u64, method: String, url: String, headers: Vec<(String, String)>, body: String, retry: bool) {
    let made = crate::generation();
    std::thread::spawn(move || {
        // A form's files are read now, off the main thread (D-139: `controls::expand`).
        let content_type = headers.iter().find(|(name, _)| name.eq_ignore_ascii_case("content-type")).map(|(_, value)| value.as_str());
        let result = crate::controls::expand(content_type, &body)
            .and_then(|bytes| fetch_bytes(&method, &url, &headers, &bytes, retry))
            .map(|raw| Answered { status: raw.status, headers: raw.headers, body: String::from_utf8_lossy(&raw.body).into_owned(), url: raw.url, redirected: raw.redirected })
            .map_err(|why| format!("{method} {url}: {why}"));
        crate::post(crate::Message::Answer(made, id, result));
    });
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_millis() as u64).unwrap_or(0)
}

/// A request, its redirects followed and its cookies kept, as `fetch` makes one: the answer at the
/// end.
pub fn fetch(method: &str, url: &str, headers: &[(String, String)], body: &str, retry: bool) -> Result<Answered, String> {
    let raw = fetch_bytes(method, url, headers, body.as_bytes(), retry)?;
    Ok(Answered { status: raw.status, headers: raw.headers, body: String::from_utf8_lossy(&raw.body).into_owned(), url: raw.url, redirected: raw.redirected })
}

/// An answer as bytes (an image's, a video's part: D-139), with what `Answered` says beside it.
#[derive(Clone, Debug, Default)]
pub struct Bytes {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub url: String,
    pub redirected: bool,
}

impl Bytes {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(each, _)| each.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
    }
}

/// `fetch` with a body of bytes and the answer's as bytes (D-139: a file's upload, an image).
pub fn fetch_bytes(method: &str, url: &str, headers: &[(String, String)], body: &[u8], retry: bool) -> Result<Bytes, String> {
    let mut method = method.to_string();
    let mut url = url.to_string();
    let mut headers = headers.to_vec();
    let mut body = body.to_vec();
    let mut redirected = false;
    for _ in 0..=20 {
        let mut sent = headers.clone();
        if let Some(cookie) = crate::cookies::for_request(&url, now_ms()) {
            sent.push(("cookie".into(), cookie));
        }
        let (status, answer_headers, answer_body) = once(&method, &url, &sent, &body, retry)?;
        crate::cookies::from_answer(&url, &answer_headers, now_ms());
        let location = answer_headers.iter().find(|(name, _)| name == "location").map(|(_, value)| value.clone());
        if let (301 | 302 | 303 | 307 | 308, Some(location)) = (status, location) {
            let at = Url::parse(&url);
            let next = at.as_ref().and_then(|at| at.join(&location)).ok_or_else(|| format!("a redirect to {location}, which isn't an HTTP URL"))?;
            // Another site's (a sign-in with a provider): not followed, but said, as where the answer
            // ended, for a navigation to open it in the system's browser (a page's fetch would be
            // refused there by CORS, and the browser would load it).
            if at.is_some_and(|at| at.origin != next.origin) {
                return Ok(Bytes { status, headers: answer_headers, body: answer_body, url: next.href(), redirected: true });
            }
            if (status == 303 && method != "HEAD") || (matches!(status, 301 | 302) && method == "POST") {
                method = "GET".into();
                body.clear();
                headers.retain(|(name, _)| !["content-type", "content-length", "content-encoding", "content-language", "content-location"].iter().any(|each| name.eq_ignore_ascii_case(each)));
            }
            url = next.without_hash();
            redirected = true;
            continue;
        }
        return Ok(Bytes { status, headers: answer_headers, body: answer_body, url, redirected });
    }
    Err("too many redirects".into())
}

/// Where a URL's request goes: its host and port (`host:port`), and the path and query to ask for.
fn place(url: &str) -> Result<(String, String, String), String> {
    let rest = url.strip_prefix("http://").ok_or_else(|| {
        if url.starts_with("https://") { "https:// isn't on phones yet (D-138: plain http:// only)".to_string() } else { format!("not an http:// URL: {url}") }
    })?;
    let (authority, path) = match rest.find(['/', '?']) {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, "/"),
    };
    let path = path.split('#').next().unwrap_or("/");
    let path = if path.starts_with('?') { format!("/{path}") } else { path.to_string() };
    let address = if authority.rsplit_once(':').is_some_and(|(_, port)| port.chars().all(|c| c.is_ascii_digit())) && !authority.ends_with(']') { authority.to_string() } else { format!("{authority}:80") };
    Ok((authority.to_string(), address, path))
}

/// One request and its answer, on a kept connection when there is one (sent again on a new one if
/// the server had closed it).
fn once(method: &str, url: &str, headers: &[(String, String)], body: &[u8], retry: bool) -> Result<Answer, String> {
    let (authority, address, path) = place(url)?;
    let request = request_bytes(method, &authority, &path, headers, body, true);
    if let Some(stream) = pooled(&address) {
        match exchange(stream, &request, method) {
            Ok((answer, reusable)) => {
                if let Some(stream) = reusable {
                    give_back(&address, stream);
                }
                return Ok(answer);
            }
            // Closed by the server while it was kept: nothing of the answer came, so it is sent again.
            Err(Exchange::Stale) => {}
            Err(Exchange::Failed(why)) => return Err(why),
        }
    }
    let stream = connect(&address, retry)?;
    match exchange(stream, &request, method) {
        Ok((answer, reusable)) => {
            if let Some(stream) = reusable {
                give_back(&address, stream);
            }
            Ok(answer)
        }
        Err(Exchange::Stale) => Err("the server closed the connection without an answer".into()),
        Err(Exchange::Failed(why)) => Err(why),
    }
}

fn request_text(method: &str, authority: &str, path: &str, headers: &[(String, String)], body: &str, keep: bool) -> String {
    String::from_utf8_lossy(&request_bytes(method, authority, path, headers, body.as_bytes(), keep)).into_owned()
}

fn request_bytes(method: &str, authority: &str, path: &str, headers: &[(String, String)], body: &[u8], keep: bool) -> Vec<u8> {
    let mut text = format!("{method} {path} HTTP/1.1\r\nhost: {authority}\r\nuser-agent: rocx-native\r\n");
    if !keep {
        text.push_str("connection: close\r\n");
    }
    for (name, value) in headers {
        if name.eq_ignore_ascii_case("host") || name.eq_ignore_ascii_case("content-length") || name.eq_ignore_ascii_case("connection") {
            continue;
        }
        text.push_str(&format!("{name}: {}\r\n", value.replace(['\r', '\n'], " ")));
    }
    if !body.is_empty() || matches!(method, "POST" | "PUT" | "PATCH" | "DELETE") {
        text.push_str(&format!("content-length: {}\r\n", body.len()));
    }
    text.push_str("\r\n");
    let mut bytes = text.into_bytes();
    bytes.extend_from_slice(body);
    bytes
}

enum Exchange {
    /// Nothing came back: a kept connection the server had closed.
    Stale,
    Failed(String),
}

type Answer = (u16, Vec<(String, String)>, Vec<u8>);

/// Sends a request and reads its answer whole; the connection back if another request may use it.
fn exchange(mut stream: TcpStream, request: &[u8], method: &str) -> Result<(Answer, Option<TcpStream>), Exchange> {
    stream.set_read_timeout(Some(ANSWER)).ok();
    stream.set_write_timeout(Some(ANSWER)).ok();
    if let Err(why) = stream.write_all(request) {
        return Err(if matches!(why.kind(), std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted) { Exchange::Stale } else { Exchange::Failed(why.to_string()) });
    }
    let mut reader = BufReader::new(stream);
    let head = match read_head(&mut reader) {
        Ok(Some(head)) => head,
        Ok(None) => return Err(Exchange::Stale),
        Err(why) if why.kind() == std::io::ErrorKind::ConnectionReset => return Err(Exchange::Stale),
        Err(why) => return Err(Exchange::Failed(why.to_string())),
    };
    let (version, status, headers) = head;
    let framing = Framing::of(status, &headers, method);
    let body = read_body(&mut reader, &framing).map_err(|why| Exchange::Failed(why.to_string()))?;
    let closes = version == "HTTP/1.0" || headers.iter().any(|(name, value)| name == "connection" && value.to_ascii_lowercase().contains("close"));
    let reusable = (!closes && !matches!(framing, Framing::UntilClosed) && reader.buffer().is_empty()).then(|| reader.into_inner());
    Ok(((status, headers, body), reusable))
}

/// An answer's status line and headers; none if the connection closed before any of it came.
fn read_head(reader: &mut BufReader<TcpStream>) -> std::io::Result<Option<(String, u16, Vec<(String, String)>)>> {
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let mut parts = line.split_whitespace();
        let version = parts.next().unwrap_or("").to_string();
        let status: u16 = parts.next().and_then(|code| code.parse().ok()).ok_or_else(|| std::io::Error::other(format!("an answer without a status: {}", line.trim())))?;
        let mut headers = Vec::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line)? == 0 {
                return Err(std::io::Error::other("an answer cut off in its headers"));
            }
            let line = line.trim_end_matches(['\r', '\n']);
            if line.is_empty() {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
            }
        }
        // A 1xx (100 Continue) is followed by the answer itself.
        if (100..200).contains(&status) && status != 101 {
            continue;
        }
        return Ok(Some((version, status, headers)));
    }
}

/// How an answer's body ends.
enum Framing {
    None,
    Length(usize),
    Chunked,
    UntilClosed,
}

impl Framing {
    fn of(status: u16, headers: &[(String, String)], method: &str) -> Framing {
        if method == "HEAD" || status == 204 || status == 304 {
            return Framing::None;
        }
        if headers.iter().any(|(name, value)| name == "transfer-encoding" && value.to_ascii_lowercase().contains("chunked")) {
            return Framing::Chunked;
        }
        match headers.iter().find(|(name, _)| name == "content-length").and_then(|(_, value)| value.parse().ok()) {
            Some(length) => Framing::Length(length),
            None => Framing::UntilClosed,
        }
    }
}

fn read_body(reader: &mut BufReader<TcpStream>, framing: &Framing) -> std::io::Result<Vec<u8>> {
    let mut body = Vec::new();
    match framing {
        Framing::None => {}
        Framing::Length(length) => {
            body.resize(*length, 0);
            reader.read_exact(&mut body)?;
        }
        Framing::UntilClosed => {
            reader.read_to_end(&mut body)?;
        }
        Framing::Chunked => {
            let mut chunks = Chunks::default();
            while let Some(chunk) = chunks.next(reader)? {
                body.extend_from_slice(&chunk);
            }
        }
    }
    Ok(body)
}

/// A chunked body, read a chunk at a time (a stream's events come in chunks as they are written).
#[derive(Default)]
struct Chunks {
    done: bool,
}

impl Chunks {
    fn next(&mut self, reader: &mut impl BufRead) -> std::io::Result<Option<Vec<u8>>> {
        if self.done {
            return Ok(None);
        }
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "a chunked answer cut off"));
        }
        let size = usize::from_str_radix(line.trim().split(';').next().unwrap_or("").trim(), 16).map_err(|_| std::io::Error::other("a chunk's size isn't a number"))?;
        if size == 0 {
            // The trailer, to its blank line.
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line)? == 0 || line.trim().is_empty() {
                    break;
                }
            }
            self.done = true;
            return Ok(None);
        }
        let mut chunk = vec![0; size];
        reader.read_exact(&mut chunk)?;
        let mut end = [0u8; 2];
        reader.read_exact(&mut end)?;
        Ok(Some(chunk))
    }
}

// ---- Connections ----

static POOL: Mutex<Vec<(String, TcpStream, Instant)>> = Mutex::new(Vec::new());

/// A kept connection to `address`, the most recent, if one hasn't waited too long.
fn pooled(address: &str) -> Option<TcpStream> {
    let mut pool = POOL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    pool.retain(|(_, _, at)| at.elapsed() < IDLE);
    let at = pool.iter().rposition(|(each, _, _)| each == address)?;
    Some(pool.remove(at).1)
}

fn give_back(address: &str, stream: TcpStream) {
    let mut pool = POOL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    pool.push((address.to_string(), stream, Instant::now()));
    while pool.len() > POOLED {
        pool.remove(0);
    }
}

/// How many connections are kept now (the tests').
pub fn kept() -> usize {
    POOL.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).len()
}

/// A connection to the server; refused, tried again for up to 3 s when `retry` (nothing was sent
/// yet), as a server being restarted (`rocx dev`, a deploy) is back within that.
fn connect(address: &str, retry: bool) -> Result<TcpStream, String> {
    let addresses: Vec<SocketAddr> = address.to_socket_addrs().map_err(|why| format!("{address}: {why}"))?.collect();
    let mut tries = 0;
    loop {
        let mut last = None;
        for each in &addresses {
            match TcpStream::connect_timeout(each, CONNECT) {
                Ok(stream) => {
                    stream.set_nodelay(true).ok();
                    return Ok(stream);
                }
                Err(why) => last = Some(why),
            }
        }
        match last {
            Some(why) if retry && why.kind() == std::io::ErrorKind::ConnectionRefused && tries < 20 => {
                tries += 1;
                std::thread::sleep(Duration::from_millis(150));
            }
            Some(why) => return Err(why.to_string()),
            None => return Err(format!("{address}: no address")),
        }
    }
}

// ---- Streams (D-140) ----

/// What a stream says as it is read, posted to the main thread (`Message::Heard`).
#[derive(Clone, Debug, PartialEq)]
pub enum Heard {
    /// Its answer began: the status, and whether it is a stream of events (`text/event-stream`);
    /// an answer that isn't comes whole, with its body.
    Opened { status: u16, events: bool, body: String },
    /// An event: its name (`message` if it has none) and its data lines, joined by newlines.
    Event { name: String, data: String },
    /// It ended: the server closed it (none), or it failed (why).
    Closed(Option<String>),
}

/// Stops a stream from another thread: its socket shut, so the read waiting on it ends.
#[derive(Clone, Default)]
pub struct Stopper {
    stopped: Arc<AtomicBool>,
    socket: Arc<Mutex<Option<TcpStream>>>,
}

impl Stopper {
    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
        if let Some(socket) = self.socket.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take() {
            let _ = socket.shutdown(std::net::Shutdown::Both);
        }
    }

    pub fn stopped(&self) -> bool {
        self.stopped.load(Ordering::Relaxed)
    }
}

/// Opens a stream of events (a GET, `accept: text/event-stream`, its redirects followed, its
/// cookies sent) on a thread of its own, posting what it hears (`Message::Heard(id, …)`) until it
/// ends or is stopped (`Stopper::stop`; nothing is posted after that).
pub fn stream(id: u64, url: String, headers: Vec<(String, String)>, stopper: Stopper) {
    let made = crate::generation();
    std::thread::spawn(move || {
        let tell = |heard: Heard| {
            if !stopper.stopped() {
                crate::post(crate::Message::Heard(made, id, heard));
            }
        };
        let ended = read_stream(&url, &headers, &stopper, &tell);
        tell(Heard::Closed(ended.err()));
    });
}

fn read_stream(url: &str, headers: &[(String, String)], stopper: &Stopper, tell: &dyn Fn(Heard)) -> Result<(), String> {
    let mut url = url.to_string();
    for _ in 0..=20 {
        let (authority, address, path) = place(&url)?;
        let mut sent = headers.to_vec();
        if let Some(cookie) = crate::cookies::for_request(&url, now_ms()) {
            sent.push(("cookie".into(), cookie));
        }
        let request = request_text("GET", &authority, &path, &sent, "", false);
        let mut socket = connect(&address, true)?;
        *stopper.socket.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = socket.try_clone().ok();
        if stopper.stopped() {
            let _ = socket.shutdown(std::net::Shutdown::Both);
            return Ok(());
        }
        // The server says something at least every 15 s (`: beat`): a minute of nothing is a
        // connection that has gone.
        socket.set_read_timeout(Some(Duration::from_secs(60))).ok();
        socket.write_all(request.as_bytes()).map_err(|why| why.to_string())?;
        let mut reader = BufReader::new(socket);
        let (_, status, answer_headers) = read_head(&mut reader).map_err(|why| why.to_string())?.ok_or("the server closed the connection without an answer")?;
        crate::cookies::from_answer(&url, &answer_headers, now_ms());
        if let (301 | 302 | 303 | 307 | 308, Some(location)) = (status, answer_headers.iter().find(|(name, _)| name == "location").map(|(_, value)| value.clone())) {
            url = Url::parse(&url).and_then(|at| at.join(&location)).ok_or("a redirect that isn't an HTTP URL")?.without_hash();
            continue;
        }
        let events = answer_headers.iter().any(|(name, value)| name == "content-type" && value.to_ascii_lowercase().starts_with("text/event-stream"));
        let framing = Framing::of(status, &answer_headers, "GET");
        if !events {
            let body = read_body(&mut reader, &framing).map_err(|why| why.to_string())?;
            tell(Heard::Opened { status, events: false, body: String::from_utf8_lossy(&body).into_owned() });
            return Ok(());
        }
        tell(Heard::Opened { status, events: true, body: String::new() });
        let mut parser = Events::default();
        let mut chunks = Chunks::default();
        loop {
            let bytes = match framing {
                Framing::Chunked => match chunks.next(&mut reader) {
                    Ok(Some(chunk)) => chunk,
                    Ok(None) => return Ok(()),
                    Err(_) if stopper.stopped() => return Ok(()),
                    Err(why) => return Err(why.to_string()),
                },
                _ => {
                    let mut buffer = [0u8; 4096];
                    match reader.read(&mut buffer) {
                        Ok(0) => return Ok(()),
                        Ok(read) => buffer[..read].to_vec(),
                        Err(_) if stopper.stopped() => return Ok(()),
                        Err(why) => return Err(why.to_string()),
                    }
                }
            };
            for (name, data) in parser.feed(&bytes) {
                tell(Heard::Event { name, data });
            }
        }
    }
    Err("too many redirects".into())
}

/// Server-sent events, parsed as their bytes come (the HTML spec's event stream, as runtime.js
/// reads it): an event ends at a blank line; its `event:` name and its `data:` lines; a comment
/// (`: beat`) and an event without data are nothing.
#[derive(Default)]
pub struct Events {
    buffer: Vec<u8>,
}

impl Events {
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<(String, String)> {
        self.buffer.extend_from_slice(bytes);
        let mut out = Vec::new();
        loop {
            let text = String::from_utf8_lossy(&self.buffer).replace("\r\n", "\n");
            let Some(end) = text.find("\n\n") else {
                // Keep the bytes as they were (a character may be cut between two reads).
                return out;
            };
            let (event, rest) = (text[..end].to_string(), text[end + 2..].to_string());
            self.buffer = rest.into_bytes();
            let mut name = String::new();
            let mut data: Vec<&str> = Vec::new();
            for line in event.split('\n') {
                let (field, value) = match line.split_once(':') {
                    Some((field, value)) => (field, value.strip_prefix(' ').unwrap_or(value)),
                    None => (line, ""),
                };
                match field {
                    "event" => name = value.to_string(),
                    "data" => data.push(value),
                    _ => {}
                }
            }
            if !data.is_empty() {
                out.push((if name.is_empty() { "message".to_string() } else { name }, data.join("\n")));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    /// A server on a port of its own that answers each connection's requests as `answer` says,
    /// noting each request's head.
    fn serve(answers: Vec<&'static str>) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let heard = Arc::new(Mutex::new(Vec::new()));
        let noted = heard.clone();
        std::thread::spawn(move || {
            let mut answers = answers.into_iter();
            for (connection, stream) in listener.incoming().enumerate() {
                let Ok(stream) = stream else { return };
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut writer = stream;
                loop {
                    let mut head = String::new();
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 {
                            break;
                        }
                        if line == "\r\n" {
                            break;
                        }
                        head.push_str(&line);
                    }
                    if head.is_empty() {
                        break;
                    }
                    let length = head.lines().find_map(|line| line.strip_prefix("content-length: ")).and_then(|n| n.trim().parse().ok()).unwrap_or(0);
                    let mut body = vec![0; length];
                    reader.read_exact(&mut body).unwrap();
                    noted.lock().unwrap().push(format!("{head}{}#{connection}", String::from_utf8_lossy(&body)));
                    let Some(answer) = answers.next() else { return };
                    if answer == "CLOSE" {
                        break;
                    }
                    writer.write_all(answer.as_bytes()).unwrap();
                    if answer.contains("connection: close") {
                        break;
                    }
                }
            }
        });
        (origin, heard)
    }

    #[test]
    fn redirects_are_followed_as_fetch_follows_them() {
        let (origin, heard) = serve(vec![
            "HTTP/1.1 303 See Other\r\nlocation: /board?from=x\r\nset-cookie: session=s1; Path=/; Max-Age=60\r\ncontent-length: 0\r\n\r\n",
            "HTTP/1.1 308 Permanent Redirect\r\nlocation: /board/\r\ncontent-length: 0\r\n\r\n",
            "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\nhello",
        ]);
        let answer = fetch("POST", &format!("{origin}/auth/dev"), &[("content-type".into(), "application/x-www-form-urlencoded".into())], "email=a%40acme.example", false).unwrap();
        assert_eq!(answer.status, 200);
        assert_eq!(answer.body, "hello");
        assert!(answer.redirected);
        assert_eq!(answer.url, format!("{origin}/board/"));
        let heard = heard.lock().unwrap();
        assert!(heard[0].starts_with("POST /auth/dev HTTP/1.1"), "{}", heard[0]);
        assert!(heard[0].ends_with("email=a%40acme.example#0"));
        assert!(heard[1].starts_with("GET /board?from=x HTTP/1.1"), "a 303 goes on as a GET: {}", heard[1]);
        assert!(!heard[1].contains("content-type"), "without the body's headers");
        assert!(heard[1].contains("cookie: session=s1"), "the redirect's cookie is sent: {}", heard[1]);
        assert!(heard[2].starts_with("GET /board/ HTTP/1.1"));
        assert!(heard.iter().all(|each| each.ends_with("#0")), "one connection, kept alive for all three");
    }

    #[test]
    fn a_307_keeps_the_method_and_body() {
        let (origin, heard) = serve(vec!["HTTP/1.1 307 Temporary Redirect\r\nlocation: /two\r\ncontent-length: 0\r\n\r\n", "HTTP/1.1 201 Created\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"]);
        let answer = fetch("POST", &format!("{origin}/one"), &[("content-type".into(), "application/json".into())], "{\"a\":1}", false).unwrap();
        assert_eq!((answer.status, answer.body.as_str()), (201, "abcde"));
        let heard = heard.lock().unwrap();
        assert!(heard[1].starts_with("POST /two HTTP/1.1") && heard[1].ends_with("{\"a\":1}#0"), "{}", heard[1]);
    }

    #[test]
    fn a_connection_the_server_closed_is_replaced() {
        // The first answer keeps the connection; the server closes it before the second request.
        let (origin, heard) = serve(vec!["HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok", "CLOSE", "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nagain"]);
        assert_eq!(fetch("GET", &format!("{origin}/a"), &[], "", false).unwrap().body, "ok");
        assert_eq!(fetch("GET", &format!("{origin}/b"), &[], "", false).unwrap().body, "again");
        let heard = heard.lock().unwrap();
        assert_eq!(heard.len(), 3);
        assert!(heard[1].ends_with("#0") && heard[2].starts_with("GET /b ") && heard[2].ends_with("#1"), "the second request sent again on a new connection");
    }

    #[test]
    fn events_are_parsed_as_they_come() {
        let mut events = Events::default();
        assert_eq!(events.feed(b"event: hello\ndata: s1\n\n: beat\n\nevent: message\r\ndata: /api/live\r\ndata: {\"a\""), vec![("hello".to_string(), "s1".to_string())]);
        assert_eq!(events.feed(b":1}\r\n\r\ndata: plain\n\n"), vec![("message".to_string(), "/api/live\n{\"a\":1}".to_string()), ("message".to_string(), "plain".to_string())]);
        assert_eq!(events.feed("data: caf\u{e9}".as_bytes()[..10].as_ref()), vec![]);
        assert_eq!(events.feed(&"data: caf\u{e9}\n\n".as_bytes()[10..]), vec![("message".to_string(), "caf\u{e9}".to_string())], "a character cut between reads");
    }

    #[test]
    fn a_stream_is_read_as_it_comes() {
        let (origin, _) = serve(vec!["HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n12\r\nevent: a\ndata: 1\n\n\r\n0\r\n\r\n"]);
        let heard = Arc::new(Mutex::new(Vec::new()));
        let noted = heard.clone();
        let stopper = Stopper::default();
        let ended = read_stream(&format!("{origin}/events"), &[("accept".into(), "text/event-stream".into())], &stopper, &move |each| noted.lock().unwrap().push(each));
        assert_eq!(ended, Ok(()));
        assert_eq!(*heard.lock().unwrap(), vec![Heard::Opened { status: 200, events: true, body: String::new() }, Heard::Event { name: "a".into(), data: "1".into() }]);
    }
}
