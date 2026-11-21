//! `Tcp` (`server/platform/Tcp.roc`): connections to other servers (an SMTP server; Postgres, for a
//! client written in Roc), plain or over TLS. Each read and write blocks the thread of the call that
//! asked, as the host's other effects do. A connection belongs to the call that opened it: the host
//! closes what a call left open when it ends. A call with a deadline (a job's time limit) waits no
//! longer than that for any of it.
//!
//! Nothing here is locked or shared: a call runs on one thread from its start to its end (and the
//! calls it runs inside it, too), so the connections it opens are kept in that thread's own table.
//! An id another thread opened is, here, a connection that is closed. Ids are unique across threads
//! (one atomic counter), so one is never taken for another.

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// How long a connection may take to be made, and a read or a write to make progress.
const CONNECT: Duration = Duration::from_secs(10);
const IO: Duration = Duration::from_secs(60);

enum Stream {
    Plain(TcpStream),
    Tls(Box<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>),
    /// While going over to TLS.
    Gone,
}

impl Stream {
    /// The socket under it.
    fn socket(&self) -> Option<&TcpStream> {
        match self {
            Stream::Plain(stream) => Some(stream),
            Stream::Tls(stream) => Some(&stream.sock),
            Stream::Gone => None,
        }
    }

    /// Reads and writes wait `IO` at most, or until `deadline`.
    fn bound(&self, deadline: Option<Instant>) {
        if let Some(socket) = self.socket() {
            let wait = bounded(IO, deadline);
            socket.set_read_timeout(Some(wait)).ok();
            socket.set_write_timeout(Some(wait)).ok();
        }
    }

    fn read(&mut self, into: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Stream::Plain(stream) => stream.read(into),
            Stream::Tls(stream) => stream.read(into),
            Stream::Gone => Err(std::io::Error::other("the connection is closed")),
        }
    }

    fn write_all(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        match self {
            Stream::Plain(stream) => stream.write_all(bytes).and_then(|()| stream.flush()),
            Stream::Tls(stream) => stream.write_all(bytes).and_then(|()| stream.flush()),
            Stream::Gone => Err(std::io::Error::other("the connection is closed")),
        }
    }
}

/// `limit`, or less if `deadline` comes sooner (a millisecond at least: a socket takes no zero).
fn bounded(limit: Duration, deadline: Option<Instant>) -> Duration {
    let left = deadline.map_or(limit, |at| at.saturating_duration_since(Instant::now()));
    limit.min(left).max(Duration::from_millis(1))
}

/// A connection, and what has been read from it but not yet asked for.
struct Connection {
    stream: Stream,
    buffered: Vec<u8>,
}

thread_local! {
    /// The connections the calls on this thread have open, by id.
    static CONNECTIONS: RefCell<HashMap<u64, Connection>> = RefCell::new(HashMap::new());
}

static NEXT: AtomicU64 = AtomicU64::new(1);

/// Does `act` with the connection `id`, which this thread's call opened.
fn with<T>(id: u64, act: impl FnOnce(&mut Connection) -> Result<T, String>) -> Result<T, String> {
    CONNECTIONS.with(|connections| match connections.borrow_mut().get_mut(&id) {
        Some(connection) => act(connection),
        None => Err("the connection is closed".to_string()),
    })
}

fn tls_over(stream: TcpStream, host: &str, deadline: Option<Instant>) -> Result<Stream, String> {
    let wait = bounded(IO, deadline);
    stream.set_read_timeout(Some(wait)).ok();
    stream.set_write_timeout(Some(wait)).ok();
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|error| format!("{host}: {error}"))?;
    let connection = rustls::ClientConnection::new(crate::tls::client_config(), name).map_err(|error| format!("TLS: {error}"))?;
    let mut tls = rustls::StreamOwned::new(connection, stream);
    // The handshake now, so a certificate that isn't right is the connect's error.
    while tls.conn.is_handshaking() {
        tls.conn.complete_io(&mut tls.sock).map_err(|error| format!("TLS with {host}: {error}"))?;
    }
    Ok(Stream::Tls(Box::new(tls)))
}

/// A connection to `host` at `port`; its id.
pub fn connect(host: &str, port: u16, tls: bool, deadline: Option<Instant>) -> Result<u64, String> {
    let addresses = (host, port).to_socket_addrs().map_err(|error| format!("{host}:{port}: {error}"))?;
    let mut last = format!("{host}:{port}: no address");
    let mut made = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, bounded(CONNECT, deadline)) {
            Ok(stream) => {
                made = Some(stream);
                break;
            }
            Err(error) => last = format!("{host}:{port}: {error}"),
        }
    }
    let stream = made.ok_or(last)?;
    stream.set_nodelay(true).ok();
    let stream = if tls { tls_over(stream, host, deadline)? } else { Stream::Plain(stream) };
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    CONNECTIONS.with(|connections| connections.borrow_mut().insert(id, Connection { stream, buffered: Vec::new() }));
    Ok(id)
}

/// Goes on over TLS (STARTTLS).
pub fn start_tls(id: u64, host: &str, deadline: Option<Instant>) -> Result<(), String> {
    with(id, |connection| {
        if !connection.buffered.is_empty() {
            return Err("the server sent more before TLS began".into());
        }
        match std::mem::replace(&mut connection.stream, Stream::Gone) {
            Stream::Plain(stream) => {
                connection.stream = tls_over(stream, host, deadline)?;
                Ok(())
            }
            other => {
                connection.stream = other;
                Err("the connection is over TLS already".into())
            }
        }
    })
}

pub fn write(id: u64, bytes: &[u8], deadline: Option<Instant>) -> Result<(), String> {
    with(id, |connection| {
        connection.stream.bound(deadline);
        connection.stream.write_all(bytes).map_err(|error| error.to_string())
    })
}

/// Reads more into the buffer: false once the other end has closed.
fn fill(connection: &mut Connection) -> Result<bool, String> {
    let mut chunk = [0u8; 8192];
    let read = connection.stream.read(&mut chunk).map_err(|error| error.to_string())?;
    connection.buffered.extend_from_slice(&chunk[..read]);
    Ok(read > 0)
}

/// Exactly `count` bytes; `Err("eof")` if the connection ends first.
pub fn read_exactly(id: u64, count: usize, deadline: Option<Instant>) -> Result<Vec<u8>, String> {
    with(id, |connection| {
        connection.stream.bound(deadline);
        while connection.buffered.len() < count {
            if !fill(connection)? {
                return Err("eof".into());
            }
        }
        Ok(connection.buffered.drain(..count).collect())
    })
}

/// What there is, up to `count` bytes, waiting for some; nothing once the connection has ended.
pub fn read_up_to(id: u64, count: usize, deadline: Option<Instant>) -> Result<Vec<u8>, String> {
    with(id, |connection| {
        connection.stream.bound(deadline);
        if connection.buffered.is_empty() {
            fill(connection)?;
        }
        let take = count.min(connection.buffered.len());
        Ok(connection.buffered.drain(..take).collect())
    })
}

/// Up to and including the next `byte`; `Err("eof")` if the connection ends first.
pub fn read_until(id: u64, byte: u8, deadline: Option<Instant>) -> Result<Vec<u8>, String> {
    with(id, |connection| {
        connection.stream.bound(deadline);
        let mut searched = 0;
        loop {
            if let Some(at) = connection.buffered[searched..].iter().position(|each| *each == byte) {
                return Ok(connection.buffered.drain(..searched + at + 1).collect());
            }
            searched = connection.buffered.len();
            if !fill(connection)? {
                return Err("eof".into());
            }
        }
    })
}

/// Closes the connection `id` (one this thread's call opened; any other is nothing to close).
pub fn close(id: u64) {
    let closed = CONNECTIONS.with(|connections| connections.borrow_mut().remove(&id));
    drop(closed);
}
