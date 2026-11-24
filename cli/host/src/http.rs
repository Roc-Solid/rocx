//! `Host.http_get!`: a GET over plain HTTP/1.1, for a server on this machine (`rocx build --static`
//! asks the app's server for its pages, D-073). `std::net` alone: one connection a request
//! (`Connection: close`), the answer read to its end, a chunked body put together. No TLS, no
//! redirects followed, no compression asked for (`Accept-Encoding: identity`).

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

pub struct Answer {
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
}

/// A GET of `url` (`http://host:port/path?query`), with `headers` (`name: value`) besides `Host`.
pub fn get(url: &str, headers: &[String]) -> Result<Answer, String> {
    let rest = url.strip_prefix("http://").ok_or_else(|| format!("not a plain http:// URL: {url}"))?;
    let (authority, target) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, "/"),
    };
    if authority.is_empty() {
        return Err(format!("no host in {url}"));
    }
    let address = if authority.contains(':') { authority.to_string() } else { format!("{authority}:80") };
    let mut stream = TcpStream::connect(&address).map_err(|error| error.to_string())?;
    let minute = Some(Duration::from_secs(60));
    stream.set_read_timeout(minute).map_err(|error| error.to_string())?;
    stream.set_write_timeout(minute).map_err(|error| error.to_string())?;
    let mut request = format!("GET {target} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\nAccept-Encoding: identity\r\n");
    for header in headers {
        request.push_str(header.trim());
        request.push_str("\r\n");
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).map_err(|error| error.to_string())?;
    let mut answer = Vec::new();
    stream.read_to_end(&mut answer).map_err(|error| error.to_string())?;
    parse(&answer)
}

/// An answer's status line, headers and body.
fn parse(answer: &[u8]) -> Result<Answer, String> {
    let end = answer.windows(4).position(|window| window == b"\r\n\r\n").ok_or("the answer ended before its headers did")?;
    let head = String::from_utf8_lossy(&answer[..end]);
    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or("");
    let status = status_line.split(' ').nth(1).and_then(|code| code.parse::<u16>().ok()).ok_or_else(|| format!("not an HTTP status line: {status_line}"))?;
    let mut content_type = String::new();
    let mut chunked = false;
    let mut length = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            let value = value.trim();
            match name.trim().to_ascii_lowercase().as_str() {
                "content-type" => content_type = value.to_string(),
                "transfer-encoding" => chunked = value.to_ascii_lowercase().contains("chunked"),
                "content-length" => length = value.parse::<usize>().ok(),
                _ => {}
            }
        }
    }
    let rest = &answer[end + 4..];
    let body = if chunked {
        dechunk(rest)?
    } else {
        match length {
            Some(length) if length <= rest.len() => rest[..length].to_vec(),
            Some(length) => return Err(format!("the body ended after {} of its {length} bytes", rest.len())),
            None => rest.to_vec(),
        }
    };
    Ok(Answer { status, content_type, body })
}

/// A chunked body put together: each chunk's size in hex on a line, the chunk, a line's end; a
/// chunk of 0 ends it (trailers after it are left out).
fn dechunk(mut rest: &[u8]) -> Result<Vec<u8>, String> {
    let mut body = Vec::new();
    loop {
        let line_end = rest.windows(2).position(|window| window == b"\r\n").ok_or("a chunk's size line didn't end")?;
        let line = String::from_utf8_lossy(&rest[..line_end]);
        let size = usize::from_str_radix(line.split(';').next().unwrap_or("").trim(), 16).map_err(|_| format!("not a chunk's size: {line}"))?;
        rest = &rest[line_end + 2..];
        if size == 0 {
            return Ok(body);
        }
        if rest.len() < size + 2 {
            return Err("the body ended inside a chunk".to_string());
        }
        body.extend_from_slice(&rest[..size]);
        rest = &rest[size + 2..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_body_by_its_length() {
        let answer = parse(b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 5\r\n\r\nhello").unwrap();
        assert_eq!((answer.status, answer.content_type.as_str(), answer.body.as_slice()), (200, "text/html; charset=utf-8", &b"hello"[..]));
    }

    #[test]
    fn a_chunked_body_put_together() {
        let answer = parse(b"HTTP/1.1 404 Not Found\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\n\r\n").unwrap();
        assert_eq!((answer.status, answer.body.as_slice()), (404, &b"abcde"[..]));
    }

    #[test]
    fn a_body_to_the_end() {
        let answer = parse(b"HTTP/1.1 200 OK\r\n\r\n\x00\xff").unwrap();
        assert_eq!((answer.content_type.as_str(), answer.body.as_slice()), ("", &b"\x00\xff"[..]));
    }

    #[test]
    fn a_cut_answer_is_an_error() {
        assert!(parse(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort").is_err());
        assert!(parse(b"HTTP/1.1 200 OK\r\n").is_err());
        assert!(get("https://example.com/", &[]).is_err());
    }
}
