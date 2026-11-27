//! `Host.ws_*`: a WebSocket client (RFC 6455) for a server on this machine, which is how
//! packages/headless drives a browser (Chromium's DevTools protocol). `std::net` alone: plain
//! `ws://`, no TLS, no extensions (no compression asked for).
//!
//! A thread of each socket's reads its frames, answers pings, and keeps each message (a binary one
//! as text, its bytes that aren't UTF-8 replaced) until Roc takes it. Roc takes a message two ways.
//! `request` sends a JSON object with an `id` the socket numbers (1, 2, 3…) and takes the message
//! answering it (a JSON object whose top-level `id` is that number, as the DevTools protocol,
//! WebDriver BiDi and JSON-RPC answer), wherever it is among those waiting. `receive` takes the
//! oldest message still waiting (a protocol's events). So a program that asks and waits keeps the
//! events that came first for later, and needs no counter or queue of its own.

use std::collections::{HashMap, VecDeque};
use std::io::{BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// What `request` and `receive` found: a message, nothing in the time given, the socket closed, or
/// (`request`) a request that wasn't a JSON object, so no `id` could be put in it.
pub enum Taken {
    Message(String),
    Timeout,
    Closed(String),
    NotAnObject,
}

/// The most messages kept that answer no request: past it, the oldest of them is dropped, so a
/// program that never takes its events doesn't grow without end.
const KEPT_EVENTS: usize = 10_000;

/// The largest message read (a page's screenshot, in Base64, is a few megabytes).
const LARGEST: u64 = 512 << 20;

struct Socket {
    /// The last request's `id`.
    requests: AtomicU64,
    writer: Mutex<TcpStream>,
    state: Mutex<State>,
    ready: Condvar,
}

#[derive(Default)]
struct State {
    /// Each message with its top-level `id`, when it has one, oldest first.
    messages: VecDeque<(Option<u64>, String)>,
    /// How many of them have no `id` (events).
    events: usize,
    /// Why it closed, once it has.
    closed: Option<String>,
}

fn sockets() -> &'static Mutex<HashMap<u64, Arc<Socket>>> {
    static SOCKETS: OnceLock<Mutex<HashMap<u64, Arc<Socket>>>> = OnceLock::new();
    SOCKETS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn socket(id: u64) -> Option<Arc<Socket>> {
    sockets().lock().unwrap().get(&id).cloned()
}

/// A socket opened to `url` (`ws://127.0.0.1:9222/devtools/browser/…`): its id.
pub fn connect(url: &str) -> Result<u64, String> {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let rest = url.strip_prefix("ws://").ok_or_else(|| format!("not a plain ws:// URL: {url}"))?;
    let (authority, target) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, "/"),
    };
    if authority.is_empty() {
        return Err(format!("no host in {url}"));
    }
    let address = if authority.contains(':') { authority.to_string() } else { format!("{authority}:80") };
    let resolved = address.to_socket_addrs().map_err(|error| format!("{address}: {error}"))?.next().ok_or_else(|| format!("{address}: no address"))?;
    let stream = TcpStream::connect_timeout(&resolved, Duration::from_secs(10)).map_err(|error| format!("{address}: {error}"))?;
    let _ = stream.set_nodelay(true);
    let mut reader = stream.try_clone().map_err(|error| error.to_string())?;
    let mut writer = stream;
    let key = handshake_key();
    let request = format!("GET {target} HTTP/1.1\r\nHost: {authority}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n");
    writer.write_all(request.as_bytes()).map_err(|error| error.to_string())?;
    // The answer's head, read a byte at a time, so nothing after it (a first frame) is read here.
    reader.set_read_timeout(Some(Duration::from_secs(10))).map_err(|error| error.to_string())?;
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() > 16 << 10 {
            return Err(format!("{url}: the answer's head is too long"));
        }
        match reader.read(&mut byte) {
            Ok(0) => return Err(format!("{url}: closed before it answered")),
            Ok(_) => head.push(byte[0]),
            Err(error) => return Err(format!("{url}: {error}")),
        }
    }
    let head = String::from_utf8_lossy(&head);
    let status = head.lines().next().unwrap_or("");
    if status.split(' ').nth(1) != Some("101") {
        return Err(format!("{url} answered {status}, not 101 Switching Protocols"));
    }
    let upgraded = head.lines().any(|line| line.split_once(':').is_some_and(|(name, value)| name.trim().eq_ignore_ascii_case("upgrade") && value.trim().eq_ignore_ascii_case("websocket")));
    if !upgraded {
        return Err(format!("{url} switched to something other than a WebSocket"));
    }
    reader.set_read_timeout(None).map_err(|error| error.to_string())?;
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let socket = Arc::new(Socket { requests: AtomicU64::new(0), writer: Mutex::new(writer), state: Mutex::new(State::default()), ready: Condvar::new() });
    sockets().lock().unwrap().insert(id, socket.clone());
    std::thread::spawn(move || {
        let why = read_messages(BufReader::with_capacity(1 << 16, reader), &socket);
        let mut state = socket.state.lock().unwrap();
        state.closed.get_or_insert(why);
        socket.ready.notify_all();
    });
    Ok(id)
}

/// A text message sent.
pub fn send(id: u64, text: &str) -> Result<(), String> {
    let socket = socket(id).ok_or("no such socket")?;
    if let Some(why) = &socket.state.lock().unwrap().closed {
        return Err(format!("closed: {why}"));
    }
    let mut writer = socket.writer.lock().unwrap();
    write_frame(&mut *writer, 0x1, text.as_bytes()).map_err(|error| error.to_string())
}

/// `object` (a JSON object, `{"method":…}`) sent with the socket's next `id` put first in it, and
/// the message answering it, as soon as it is there (up to `timeout_ms`; 0: as long as it takes).
/// Messages that came before it stay, in their order.
pub fn request(id: u64, object: &str, timeout_ms: u64) -> Taken {
    let Some(socket) = socket(id) else { return Taken::Closed("no such socket".to_string()) };
    let body = object.trim_start();
    let Some(rest) = body.strip_prefix('{') else { return Taken::NotAnObject };
    let number = socket.requests.fetch_add(1, Ordering::Relaxed) + 1;
    let comma = if rest.trim_start().starts_with('}') { "" } else { "," };
    let text = format!("{{\"id\":{number}{comma}{rest}");
    if let Err(why) = send(id, &text) {
        return Taken::Closed(why);
    }
    take(id, timeout_ms, true, |messages| messages.iter().position(|(answers, _)| *answers == Some(number)))
}

/// The oldest message still waiting, as soon as there is one, up to `timeout_ms` (0: only one
/// already there).
pub fn receive(id: u64, timeout_ms: u64) -> Taken {
    take(id, timeout_ms, false, |messages| if messages.is_empty() { None } else { Some(0) })
}

fn take(id: u64, timeout_ms: u64, zero_is_forever: bool, find: impl Fn(&VecDeque<(Option<u64>, String)>) -> Option<usize>) -> Taken {
    let Some(socket) = socket(id) else { return Taken::Closed("no such socket".to_string()) };
    let deadline = (timeout_ms > 0 || !zero_is_forever).then(|| Instant::now() + Duration::from_millis(timeout_ms));
    let mut state = socket.state.lock().unwrap();
    loop {
        if let Some(at) = find(&state.messages) {
            let (answers, text) = state.messages.remove(at).unwrap_or_default();
            if answers.is_none() {
                state.events -= 1;
            }
            return Taken::Message(text);
        }
        if let Some(why) = &state.closed {
            return Taken::Closed(why.clone());
        }
        match deadline {
            None => state = socket.ready.wait(state).unwrap(),
            Some(deadline) => {
                let now = Instant::now();
                if now >= deadline {
                    return Taken::Timeout;
                }
                state = socket.ready.wait_timeout(state, deadline - now).unwrap().0;
            }
        }
    }
}

/// The socket closed (a close frame sent, the connection shut) and forgotten; nothing when it is
/// gone already.
pub fn close(id: u64) {
    let Some(socket) = sockets().lock().unwrap().remove(&id) else { return };
    let mut writer = socket.writer.lock().unwrap();
    let _ = write_frame(&mut *writer, 0x8, &1000u16.to_be_bytes());
    let _ = writer.shutdown(std::net::Shutdown::Both);
}

/// Frames read until the socket closes, each message kept: why it closed.
fn read_messages(mut reader: impl Read, socket: &Socket) -> String {
    let mut message: Option<Vec<u8>> = None;
    loop {
        let (fin, opcode, payload) = match read_frame(&mut reader) {
            Ok(frame) => frame,
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return "the server closed the connection".to_string(),
            Err(error) => return error.to_string(),
        };
        match opcode {
            0x1 | 0x2 => message = Some(payload),
            0x0 => match &mut message {
                Some(so_far) => so_far.extend_from_slice(&payload),
                None => return "a continuation frame with no message to continue".to_string(),
            },
            0x8 => {
                let mut writer = socket.writer.lock().unwrap();
                let _ = write_frame(&mut *writer, 0x8, payload.get(..2).unwrap_or(&[]));
                let code = payload.get(..2).map(|code| u16::from_be_bytes([code[0], code[1]]));
                let reason = String::from_utf8_lossy(payload.get(2..).unwrap_or(&[])).into_owned();
                return match code {
                    Some(code) if reason.is_empty() => format!("the server closed it ({code})"),
                    Some(code) => format!("the server closed it ({code}: {reason})"),
                    None => "the server closed it".to_string(),
                };
            }
            0x9 => {
                let mut writer = socket.writer.lock().unwrap();
                let _ = write_frame(&mut *writer, 0xA, &payload);
                continue;
            }
            0xA => continue,
            other => return format!("a frame of an unknown kind ({other})"),
        }
        if fin && let Some(whole) = message.take() {
            let text = String::from_utf8(whole).unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned());
            let answers = top_level_id(&text);
            let mut state = socket.state.lock().unwrap();
            state.messages.push_back((answers, text));
            if answers.is_none() {
                state.events += 1;
            }
            if state.events > KEPT_EVENTS
                && let Some(oldest) = state.messages.iter().position(|(answers, _)| answers.is_none())
            {
                state.messages.remove(oldest);
                state.events -= 1;
            }
            socket.ready.notify_all();
        }
    }
}

/// One frame: whether it ends its message, its opcode, and its payload (unmasked).
fn read_frame(reader: &mut impl Read) -> std::io::Result<(bool, u8, Vec<u8>)> {
    let mut head = [0u8; 2];
    reader.read_exact(&mut head)?;
    let fin = head[0] & 0x80 != 0;
    let opcode = head[0] & 0x0F;
    let masked = head[1] & 0x80 != 0;
    let length = match head[1] & 0x7F {
        126 => {
            let mut bytes = [0u8; 2];
            reader.read_exact(&mut bytes)?;
            u16::from_be_bytes(bytes) as u64
        }
        127 => {
            let mut bytes = [0u8; 8];
            reader.read_exact(&mut bytes)?;
            u64::from_be_bytes(bytes)
        }
        short => short as u64,
    };
    if length > LARGEST {
        return Err(std::io::Error::other(format!("a frame of {length} bytes, more than the {LARGEST} read")));
    }
    let mask = if masked {
        let mut key = [0u8; 4];
        reader.read_exact(&mut key)?;
        Some(key)
    } else {
        None
    };
    let mut payload = vec![0u8; length as usize];
    reader.read_exact(&mut payload)?;
    if let Some(key) = mask {
        for (i, byte) in payload.iter_mut().enumerate() {
            *byte ^= key[i % 4];
        }
    }
    Ok((fin, opcode, payload))
}

/// One frame, whole (FIN), masked as a client's must be.
fn write_frame(writer: &mut impl Write, opcode: u8, payload: &[u8]) -> std::io::Result<()> {
    let mut frame = Vec::with_capacity(payload.len() + 14);
    frame.push(0x80 | opcode);
    match payload.len() {
        short if short < 126 => frame.push(0x80 | short as u8),
        medium if medium <= u16::MAX as usize => {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(medium as u16).to_be_bytes());
        }
        long => {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(long as u64).to_be_bytes());
        }
    }
    let key = random_u64().to_be_bytes();
    let key = [key[0], key[1], key[2], key[3]];
    frame.extend_from_slice(&key);
    frame.extend(payload.iter().enumerate().map(|(i, byte)| byte ^ key[i % 4]));
    writer.write_all(&frame)?;
    writer.flush()
}

/// Bytes nobody can guess ahead, for a frame's mask and the handshake's key: the clock and a count,
/// mixed (SplitMix64). A client's mask only keeps proxies from reading frames as HTTP; it guards no
/// secret.
fn random_u64() -> u64 {
    static COUNT: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_nanos() as u64).unwrap_or(0);
    let mut z = nanos ^ COUNT.fetch_add(0x9E37_79B9_7F4A_7C15, Ordering::Relaxed) ^ ((std::process::id() as u64) << 32);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// The handshake's `Sec-WebSocket-Key`: 16 bytes in Base64.
fn handshake_key() -> String {
    let mut bytes = random_u64().to_be_bytes().to_vec();
    bytes.extend_from_slice(&random_u64().to_be_bytes());
    base64(&bytes)
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// The top-level `id` of a JSON object, when it is a whole number: `{"id":7,"result":{…}}` is 7,
/// and an `id` inside another value (`{"method":…,"params":{"id":3}}`) isn't one. Only as much of
/// the text is read as finding it takes; text that isn't JSON has none.
fn top_level_id(text: &str) -> Option<u64> {
    let bytes = text.as_bytes();
    let mut at = skip_space(bytes, 0);
    if bytes.get(at) != Some(&b'{') {
        return None;
    }
    at += 1;
    loop {
        at = skip_space(bytes, at);
        if bytes.get(at) != Some(&b'"') {
            return None;
        }
        let key_end = string_end(bytes, at)?;
        let key = &bytes[at + 1..key_end - 1];
        at = skip_space(bytes, key_end);
        if bytes.get(at) != Some(&b':') {
            return None;
        }
        at = skip_space(bytes, at + 1);
        if key == b"id" {
            let digits = bytes[at..].iter().take_while(|byte| byte.is_ascii_digit()).count();
            let after = bytes.get(at + digits).copied();
            if digits == 0 || !matches!(after, Some(b',' | b'}' | b' ' | b'\t' | b'\r' | b'\n')) {
                return None;
            }
            return std::str::from_utf8(&bytes[at..at + digits]).ok()?.parse().ok();
        }
        at = skip_space(bytes, value_end(bytes, at)?);
        match bytes.get(at) {
            Some(b',') => at += 1,
            _ => return None,
        }
    }
}

fn skip_space(bytes: &[u8], mut at: usize) -> usize {
    while matches!(bytes.get(at), Some(b' ' | b'\t' | b'\r' | b'\n')) {
        at += 1;
    }
    at
}

/// Just past the string starting at `at` (its opening quote).
fn string_end(bytes: &[u8], at: usize) -> Option<usize> {
    let mut i = at + 1;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            b'"' => return Some(i + 1),
            _ => i += 1,
        }
    }
    None
}

/// Just past the value starting at `at`: a string, an object or array (to its matching end), or a
/// word or number (to the next `,`, `}` or `]`).
fn value_end(bytes: &[u8], at: usize) -> Option<usize> {
    match bytes.get(at)? {
        b'"' => string_end(bytes, at),
        b'{' | b'[' => {
            let mut depth = 0usize;
            let mut i = at;
            while i < bytes.len() {
                match bytes[i] {
                    b'"' => {
                        i = string_end(bytes, i)?;
                        continue;
                    }
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' => {
                        depth -= 1;
                        if depth == 0 {
                            return Some(i + 1);
                        }
                    }
                    _ => {}
                }
                i += 1;
            }
            None
        }
        _ => Some(at + bytes[at..].iter().take_while(|byte| !matches!(byte, b',' | b'}' | b']')).count()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn a_top_level_id_alone() {
        assert_eq!(top_level_id(r#"{"id":7,"result":{"id":9}}"#), Some(7));
        assert_eq!(top_level_id(r#" { "method" : "Page.loadEventFired", "params": {"id": 3, "s": "\"id\":4"}, "id" : 12 } "#), Some(12));
        assert_eq!(top_level_id(r#"{"type":"success","id":5,"result":{}}"#), Some(5));
        assert_eq!(top_level_id(r#"{"method":"Runtime.consoleAPICalled","params":{"args":[{"id":1}]}}"#), None);
        assert_eq!(top_level_id(r#"{"id":"7"}"#), None);
        assert_eq!(top_level_id(r#"{"id":-1}"#), None);
        assert_eq!(top_level_id(r#"{"id":7.5}"#), None);
        assert_eq!(top_level_id("not json"), None);
        assert_eq!(top_level_id(r#"[{"id":1}]"#), None);
    }

    #[test]
    fn frames_written_are_read_back() {
        for length in [0, 5, 125, 126, 65_535, 65_536, 300_000] {
            let payload: Vec<u8> = (0..length).map(|i| (i % 251) as u8).collect();
            let mut wire = Vec::new();
            write_frame(&mut wire, 0x1, &payload).unwrap();
            assert_ne!(wire[1] & 0x80, 0, "a client's frames are masked");
            let (fin, opcode, read) = read_frame(&mut wire.as_slice()).unwrap();
            assert_eq!((fin, opcode, read.len()), (true, 0x1, length));
            assert_eq!(read, payload);
        }
    }

    #[test]
    fn base64_as_the_rfc_has_it() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(handshake_key().len(), 24);
    }

    /// A server's frame: unmasked, as a server sends it.
    fn server_frame(fin: bool, opcode: u8, payload: &[u8]) -> Vec<u8> {
        let mut frame = vec![if fin { 0x80 } else { 0 } | opcode];
        if payload.len() < 126 {
            frame.push(payload.len() as u8);
        } else {
            frame.push(126);
            frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        }
        frame.extend_from_slice(payload);
        frame
    }

    #[test]
    fn replies_by_id_and_events_in_order() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                head.push(byte[0]);
            }
            assert!(String::from_utf8_lossy(&head).contains("Sec-WebSocket-Version: 13"));
            stream.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n").unwrap();
            // The request, read and unmasked, numbered.
            let (_, opcode, request) = read_frame(&mut stream).unwrap();
            assert_eq!((opcode, request.as_slice()), (0x1, &br#"{"id":1,"method":"Page.navigate"}"#[..]));
            // An event, a ping, the answer in two frames, then another event.
            stream.write_all(&server_frame(true, 0x1, br#"{"method":"first"}"#)).unwrap();
            stream.write_all(&server_frame(true, 0x9, b"hi")).unwrap();
            stream.write_all(&server_frame(false, 0x1, br#"{"id":1,"#)).unwrap();
            stream.write_all(&server_frame(true, 0x0, br#""result":{}}"#)).unwrap();
            stream.write_all(&server_frame(true, 0x1, br#"{"method":"second"}"#)).unwrap();
            let (_, opcode, pong) = read_frame(&mut stream).unwrap();
            assert_eq!((opcode, pong.as_slice()), (0xA, &b"hi"[..]));
            // An empty object gets an id alone; it isn't answered.
            let (_, _, request) = read_frame(&mut stream).unwrap();
            assert_eq!(request.as_slice(), &br#"{"id":2}"#[..]);
            stream.write_all(&server_frame(true, 0x8, &[0x03, 0xE8, b'b', b'y', b'e'])).unwrap();
            let (_, opcode, _) = read_frame(&mut stream).unwrap();
            assert_eq!(opcode, 0x8);
        });
        let id = connect(&format!("ws://127.0.0.1:{port}/devtools/page/x")).unwrap();
        assert!(matches!(request(id, "[1]", 5000), Taken::NotAnObject));
        assert!(matches!(request(id, r#"{"method":"Page.navigate"}"#, 5000), Taken::Message(text) if text == r#"{"id":1,"result":{}}"#));
        assert!(matches!(receive(id, 5000), Taken::Message(text) if text == r#"{"method":"first"}"#));
        assert!(matches!(receive(id, 5000), Taken::Message(text) if text == r#"{"method":"second"}"#));
        assert!(matches!(request(id, " {}", 0), Taken::Closed(why) if why == "the server closed it (1000: bye)"));
        server.join().unwrap();
        assert!(matches!(receive(id, 5000), Taken::Closed(_)));
        assert!(send(id, "{}").is_err());
        close(id);
        assert!(matches!(receive(id, 0), Taken::Closed(why) if why == "no such socket"));
    }

    #[test]
    fn nothing_there_is_a_timeout() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                head.push(byte[0]);
            }
            stream.write_all(b"HTTP/1.1 101 Switching Protocols\r\nupgrade: WebSocket\r\n\r\n").unwrap();
            std::thread::sleep(Duration::from_millis(300));
        });
        let id = connect(&format!("ws://127.0.0.1:{port}")).unwrap();
        assert!(matches!(receive(id, 0), Taken::Timeout));
        let started = Instant::now();
        assert!(matches!(request(id, "{}", 50), Taken::Timeout));
        assert!(started.elapsed() >= Duration::from_millis(50));
        server.join().unwrap();
        close(id);
        assert!(connect("http://127.0.0.1:1/").is_err());
    }
}
