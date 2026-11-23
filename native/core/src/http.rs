//! The phone's requests to the server: HTTP/1.1 over a plain TCP connection, one thread a request,
//! its answer posted to the main thread (`crate::post`), which runs what waited for it.
//!
//! The spike's: plain `http://` only (the emulator reaches the Mac's dev server at 10.0.2.2), no
//! TLS, no keep-alive, no cookies. The design's client (rustls with the platform's roots, a cookie
//! jar in the app's files, streaming for `listen!` and channels) is the next step.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

/// Sends a request on a thread of its own; its answer (status, headers, body) or why there is
/// none comes back as `Message::Answer(id, …)`.
pub fn send(id: u64, method: String, url: String, headers: Vec<(String, String)>, body: String) {
    std::thread::spawn(move || {
        let result = request(&method, &url, &headers, &body).map_err(|why| format!("{method} {url}: {why}"));
        crate::post(crate::Message::Answer(id, result));
    });
}

type Answered = (u16, Vec<(String, String)>, String);

fn request(method: &str, url: &str, headers: &[(String, String)], body: &str) -> Result<Answered, String> {
    let rest = url.strip_prefix("http://").ok_or_else(|| "only http:// URLs on phones yet (D-063's spike)".to_string())?;
    let (authority, path) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, "/"),
    };
    let address = if authority.contains(':') { authority.to_string() } else { format!("{authority}:80") };
    let mut stream = TcpStream::connect(&address).map_err(|why| why.to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(30))).ok();
    let mut text = format!("{method} {path} HTTP/1.1\r\nhost: {authority}\r\nconnection: close\r\nuser-agent: rocx-native\r\n");
    for (name, value) in headers {
        text.push_str(&format!("{name}: {value}\r\n"));
    }
    if !body.is_empty() || matches!(method, "POST" | "PUT" | "PATCH") {
        text.push_str(&format!("content-length: {}\r\n", body.len()));
    }
    text.push_str("\r\n");
    text.push_str(body);
    stream.write_all(text.as_bytes()).map_err(|why| why.to_string())?;
    let mut bytes = Vec::new();
    stream.read_to_end(&mut bytes).map_err(|why| why.to_string())?;
    parse(&bytes)
}

fn parse(bytes: &[u8]) -> Result<Answered, String> {
    let end = bytes.windows(4).position(|window| window == b"\r\n\r\n").ok_or("an answer without its headers' end")?;
    let head = String::from_utf8_lossy(&bytes[..end]);
    let mut lines = head.split("\r\n");
    let status = lines.next().and_then(|line| line.split_whitespace().nth(1)).and_then(|code| code.parse().ok()).ok_or("an answer without a status")?;
    let headers: Vec<(String, String)> = lines.filter_map(|line| line.split_once(':')).map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().to_string())).collect();
    let raw = &bytes[end + 4..];
    let chunked = headers.iter().any(|(name, value)| name == "transfer-encoding" && value.to_ascii_lowercase().contains("chunked"));
    let body = if chunked { dechunk(raw)? } else { raw.to_vec() };
    Ok((status, headers, String::from_utf8_lossy(&body).into_owned()))
}

fn dechunk(mut raw: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    loop {
        let line_end = raw.windows(2).position(|window| window == b"\r\n").ok_or("a chunk without its size")?;
        let size_text = String::from_utf8_lossy(&raw[..line_end]);
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16).map_err(|_| "a chunk's size isn't a number")?;
        raw = &raw[line_end + 2..];
        if size == 0 {
            return Ok(out);
        }
        if raw.len() < size {
            return Err("a chunk cut off".into());
        }
        out.extend_from_slice(&raw[..size]);
        raw = raw.get(size + 2..).unwrap_or(&[]);
    }
}
