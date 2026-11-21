//! `Tcp` (`server/platform/Tcp.roc`): connections to other servers (an SMTP server; Postgres, for a
//! client written in Roc), plain or over TLS: tokio's sockets and tokio-rustls. Each connect, read
//! and write waits through `hosted::wait`, so the call that asked pauses meanwhile, and its thread
//! runs other calls. A connection belongs to the call that opened it: the host closes what a call
//! left open when it ends. A connection, a read or a write waits `CONNECT` or `IO` at most, and a
//! call with a deadline (a job's time limit) no longer than that.
//!
//! Nothing here is locked or shared: a call runs on one thread from its start to its end (and the
//! calls it runs inside it, too), so the connections it opens are kept in that thread's own table,
//! which a call that pauses takes out (`stash`) while other calls run there, and puts back when it
//! resumes. While one of its effects waits, the connection is out of the table, in that effect. An
//! id another call opened is, here, a connection that is closed. Ids are unique across threads (one
//! atomic counter), so one is never taken for another.

use crate::hosted::wait;
use std::cell::RefCell;
use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;

/// How long a connection may take to be made, and a read or a write to make progress.
const CONNECT: Duration = Duration::from_secs(10);
const IO: Duration = Duration::from_secs(60);

enum Stream {
    Plain(TcpStream),
    Tls(Box<TlsStream<TcpStream>>),
    /// While going over to TLS, and after that failed.
    Gone,
}

impl Stream {
    async fn read(&mut self, into: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Stream::Plain(stream) => stream.read(into).await,
            Stream::Tls(stream) => stream.read(into).await,
            Stream::Gone => Err(std::io::Error::other("the connection is closed")),
        }
    }

    async fn write_all(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        match self {
            Stream::Plain(stream) => {
                stream.write_all(bytes).await?;
                stream.flush().await
            }
            Stream::Tls(stream) => {
                stream.write_all(bytes).await?;
                stream.flush().await
            }
            Stream::Gone => Err(std::io::Error::other("the connection is closed")),
        }
    }
}

/// `limit`, or less if `deadline` comes sooner (a millisecond at least).
fn bounded(limit: Duration, deadline: Option<Instant>) -> Duration {
    let left = deadline.map_or(limit, |at| at.saturating_duration_since(Instant::now()));
    limit.min(left).max(Duration::from_millis(1))
}

/// `act`, given `IO` (or until `deadline`) to make progress: "timed out" after that.
async fn in_time<T>(deadline: Option<Instant>, act: impl Future<Output = std::io::Result<T>>) -> Result<T, String> {
    match tokio::time::timeout(bounded(IO, deadline), act).await {
        Ok(done) => done.map_err(|error| error.to_string()),
        Err(_) => Err("timed out".into()),
    }
}

/// A connection, and what has been read from it but not yet asked for.
struct Connection {
    stream: Stream,
    buffered: Vec<u8>,
}

impl Connection {
    /// Reads more into the buffer: false once the other end has closed.
    async fn fill(&mut self, deadline: Option<Instant>) -> Result<bool, String> {
        let mut chunk = [0u8; 8192];
        let read = in_time(deadline, self.stream.read(&mut chunk)).await?;
        self.buffered.extend_from_slice(&chunk[..read]);
        Ok(read > 0)
    }
}

thread_local! {
    /// The connections the call running on this thread has open, by id.
    static CONNECTIONS: RefCell<HashMap<u64, Connection>> = RefCell::new(HashMap::new());
}

/// The running call's connections, taken out while it is paused (`coroutine`).
pub struct Stash(HashMap<u64, Connection>);

pub fn stash() -> Stash {
    Stash(CONNECTIONS.with(|connections| std::mem::take(&mut *connections.borrow_mut())))
}

pub fn unstash(stash: Stash) {
    CONNECTIONS.with(|connections| *connections.borrow_mut() = stash.0);
}

static NEXT: AtomicU64 = AtomicU64::new(1);

/// Does `act` with the connection `id`, which this call opened: taken out of the table while it
/// waits, and put back after.
fn with<T>(id: u64, act: impl AsyncFnOnce(&mut Connection) -> Result<T, String>) -> Result<T, String> {
    let Some(mut connection) = CONNECTIONS.with(|connections| connections.borrow_mut().remove(&id)) else {
        return Err("the connection is closed".to_string());
    };
    let done = wait(act(&mut connection));
    CONNECTIONS.with(|connections| connections.borrow_mut().insert(id, connection));
    done
}

async fn tls_over(stream: TcpStream, host: &str, deadline: Option<Instant>) -> Result<Stream, String> {
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|error| format!("{host}: {error}"))?;
    let connector = tokio_rustls::TlsConnector::from(crate::tls::client_config());
    // The handshake now, so a certificate that isn't right is the connect's error.
    match tokio::time::timeout(bounded(IO, deadline), connector.connect(name, stream)).await {
        Ok(Ok(tls)) => Ok(Stream::Tls(Box::new(tls))),
        Ok(Err(error)) => Err(format!("TLS with {host}: {error}")),
        Err(_) => Err(format!("TLS with {host}: timed out")),
    }
}

/// A connection to `host` at `port`; its id.
pub fn connect(host: &str, port: u16, tls: bool, deadline: Option<Instant>) -> Result<u64, String> {
    let stream = wait(async {
        let addresses = match tokio::time::timeout(bounded(CONNECT, deadline), tokio::net::lookup_host((host, port))).await {
            Ok(Ok(addresses)) => addresses,
            Ok(Err(error)) => return Err(format!("{host}:{port}: {error}")),
            Err(_) => return Err(format!("{host}:{port}: timed out looking it up")),
        };
        let mut last = format!("{host}:{port}: no address");
        for address in addresses {
            match tokio::time::timeout(bounded(CONNECT, deadline), TcpStream::connect(address)).await {
                Ok(Ok(stream)) => {
                    stream.set_nodelay(true).ok();
                    return if tls { tls_over(stream, host, deadline).await } else { Ok(Stream::Plain(stream)) };
                }
                Ok(Err(error)) => last = format!("{host}:{port}: {error}"),
                Err(_) => last = format!("{host}:{port}: timed out connecting"),
            }
        }
        Err(last)
    })?;
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    CONNECTIONS.with(|connections| connections.borrow_mut().insert(id, Connection { stream, buffered: Vec::new() }));
    Ok(id)
}

/// Goes on over TLS (STARTTLS).
pub fn start_tls(id: u64, host: &str, deadline: Option<Instant>) -> Result<(), String> {
    with(id, async |connection| {
        if !connection.buffered.is_empty() {
            return Err("the server sent more before TLS began".into());
        }
        match std::mem::replace(&mut connection.stream, Stream::Gone) {
            Stream::Plain(stream) => {
                connection.stream = tls_over(stream, host, deadline).await?;
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
    with(id, async |connection| in_time(deadline, connection.stream.write_all(bytes)).await)
}

/// Exactly `count` bytes; `Err("eof")` if the connection ends first.
pub fn read_exactly(id: u64, count: usize, deadline: Option<Instant>) -> Result<Vec<u8>, String> {
    with(id, async |connection| {
        while connection.buffered.len() < count {
            if !connection.fill(deadline).await? {
                return Err("eof".into());
            }
        }
        Ok(connection.buffered.drain(..count).collect())
    })
}

/// What there is, up to `count` bytes, waiting for some; nothing once the connection has ended.
pub fn read_up_to(id: u64, count: usize, deadline: Option<Instant>) -> Result<Vec<u8>, String> {
    with(id, async |connection| {
        if connection.buffered.is_empty() {
            connection.fill(deadline).await?;
        }
        let take = count.min(connection.buffered.len());
        Ok(connection.buffered.drain(..take).collect())
    })
}

/// Up to and including the next `byte`; `Err("eof")` if the connection ends first.
pub fn read_until(id: u64, byte: u8, deadline: Option<Instant>) -> Result<Vec<u8>, String> {
    with(id, async |connection| {
        let mut searched = 0;
        loop {
            if let Some(at) = connection.buffered[searched..].iter().position(|each| *each == byte) {
                return Ok(connection.buffered.drain(..searched + at + 1).collect());
            }
            searched = connection.buffered.len();
            if !connection.fill(deadline).await? {
                return Err("eof".into());
            }
        }
    })
}

/// Closes the connection `id` (one this call opened; any other is nothing to close).
pub fn close(id: u64) {
    let closed = CONNECTIONS.with(|connections| connections.borrow_mut().remove(&id));
    drop(closed);
}
