//! Which proxy a request to another server goes through (`client`, `Http.fetch!`'s `proxy`): the
//! environment's (`HTTP_PROXY` for `http://` URLs, `HTTPS_PROXY` for `https://` ones, either in
//! lower case too, `NO_PROXY` for the hosts that go direct), one the request names, or none.
//!
//! As Go's `ProxyFromEnvironment` reads them: an upper-case variable before its lower-case one, an
//! empty one unset; a proxy without a scheme is `http://`; `localhost` and loopback addresses never
//! go through the environment's proxy (a server's own sidecar, its tests' servers). `NO_PROXY` is a
//! list, by commas: `*` (every host), an IP address, a CIDR range (`10.0.0.0/8`), a domain
//! (`example.com`: it and every name under it; `.example.com` or `*.example.com`: only the names
//! under it), each with a `:port` if it names only that port.
//!
//! Plain Rust, with no dependency: its tests compile alone (`rustc --test src/proxy.rs`).

use std::net::IpAddr;
use std::sync::OnceLock;

/// A proxy: where it is, and what a request through it says to it.
#[derive(Clone, Debug, PartialEq)]
pub struct Proxy {
    /// TLS to the proxy itself (`https://`), before anything is said through it.
    pub tls: bool,
    pub host: String,
    pub port: u16,
    /// `Basic …`, from the URL's user and password: sent as `proxy-authorization`.
    pub authorization: Option<String>,
    /// The proxy as a message names it: its scheme, host and port, never its credentials.
    pub shown: String,
    /// The URL as given, credentials and all: connections are kept a proxy (and credentials) each.
    pub key: String,
}

/// A proxy's URL: `http://host:port`, `https://…`, `user:password@host:port`, or `host:port` (as
/// `http://`). `name` is where it came from, for a message (`HTTPS_PROXY`, `proxy`).
pub fn parse(url: &str, name: &str) -> Result<Proxy, String> {
    let given = url.trim();
    let (scheme, rest) = match given.split_once("://") {
        Some((scheme, rest)) => (scheme.to_ascii_lowercase(), rest),
        None => ("http".to_string(), given),
    };
    let tls = match scheme.as_str() {
        "http" => false,
        "https" => true,
        other => return Err(format!("{name}: a proxy is http:// or https://, not {other}://")),
    };
    // What follows the authority (a `/`, the path a proxy URL may end in) says nothing.
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let (credentials, hostport) = match authority.rsplit_once('@') {
        Some((credentials, hostport)) => (Some(credentials), hostport),
        None => (None, authority),
    };
    let (host, port) = if let Some(bracketed) = hostport.strip_prefix('[') {
        let (host, after) = bracketed.split_once(']').ok_or_else(|| format!("{name}: no ] after an IPv6 address"))?;
        (host.to_string(), after.strip_prefix(':'))
    } else {
        match hostport.rsplit_once(':') {
            Some((host, port)) => (host.to_string(), Some(port)),
            None => (hostport.to_string(), None),
        }
    };
    if host.is_empty() {
        return Err(format!("{name}: no host in the proxy's URL"));
    }
    let port = match port {
        Some(port) => port.parse::<u16>().map_err(|_| format!("{name}: {port:?} isn't a port"))?,
        None if tls => 443,
        None => 80,
    };
    let authorization = credentials.map(|credentials| {
        let (user, password) = credentials.split_once(':').unwrap_or((credentials, ""));
        format!("Basic {}", base64(format!("{}:{}", percent_decoded(user), percent_decoded(password)).as_bytes()))
    });
    let shown_host = if host.contains(':') { format!("[{host}]") } else { host.clone() };
    Ok(Proxy { tls, shown: format!("{}://{shown_host}:{port}", if tls { "https" } else { "http" }), host: host.to_ascii_lowercase(), port, authorization, key: given.to_string() })
}

/// What the environment says: a proxy for each scheme (or why its URL can't be read), and the
/// hosts that go direct.
#[derive(Debug, Default)]
pub struct Environment {
    http: Option<Result<Proxy, String>>,
    https: Option<Result<Proxy, String>>,
    direct: NoProxy,
}

impl Environment {
    /// The environment's settings, as `lookup` reads a variable (an empty one is unset).
    pub fn read(lookup: impl Fn(&str) -> Option<String>) -> Environment {
        let any = |names: [&'static str; 2]| names.into_iter().find_map(|name| lookup(name).filter(|value| !value.trim().is_empty()).map(|value| (name, value)));
        let proxy = |names| any(names).map(|(name, value)| parse(&value, name));
        Environment {
            http: proxy(["HTTP_PROXY", "http_proxy"]),
            https: proxy(["HTTPS_PROXY", "https_proxy"]),
            direct: any(["NO_PROXY", "no_proxy"]).map(|(_, value)| NoProxy::parse(&value)).unwrap_or_default(),
        }
    }

    /// The proxy a request to `host` (lower case, an IPv6 address without its brackets) at `port`
    /// goes through: `None`, direct; an `Err`, a proxy the environment names but whose URL can't be
    /// read (the request fails rather than go around the proxy it was meant to take).
    pub fn proxy_for(&self, https: bool, host: &str, port: u16) -> Option<Result<&Proxy, String>> {
        let named = if https { self.https.as_ref() } else { self.http.as_ref() }?;
        if loopback(host) || self.direct.matches(host, port) {
            return None;
        }
        Some(named.as_ref().map_err(Clone::clone))
    }
}

/// The process's environment, read once (it doesn't change while the server runs).
pub fn environment() -> &'static Environment {
    static ENVIRONMENT: OnceLock<Environment> = OnceLock::new();
    ENVIRONMENT.get_or_init(|| Environment::read(|name| std::env::var(name).ok()))
}

/// `localhost`, or a loopback address: never the environment's proxy's to reach.
fn loopback(host: &str) -> bool {
    let host = host.trim_end_matches('.');
    host == "localhost" || host.parse::<IpAddr>().is_ok_and(|ip| ip.to_canonical().is_loopback())
}

/// `NO_PROXY`: the hosts that go direct.
#[derive(Debug, Default)]
struct NoProxy {
    every: bool,
    entries: Vec<Entry>,
}

#[derive(Debug)]
enum Entry {
    /// An address, or a range of them (`10.0.0.0/8`): `bits` of it compared.
    Ip { ip: IpAddr, bits: u8, port: Option<u16> },
    /// A domain, and the names under it, or (`.example.com`) only those.
    Domain { name: String, under_only: bool, port: Option<u16> },
}

impl NoProxy {
    fn parse(list: &str) -> NoProxy {
        let mut direct = NoProxy::default();
        for each in list.split(',').map(|each| each.trim().to_ascii_lowercase()).filter(|each| !each.is_empty()) {
            if each == "*" {
                direct.every = true;
                continue;
            }
            if let Some((ip, bits)) = each.split_once('/') {
                if let (Ok(ip), Ok(bits)) = (ip.parse::<IpAddr>(), bits.parse::<u8>()) {
                    direct.entries.push(Entry::Ip { ip, bits, port: None });
                }
                continue;
            }
            // An address alone, `[v6]:port`, `v4:port`, a domain, `domain:port`.
            let (host, port) = if let Some(bracketed) = each.strip_prefix('[') {
                match bracketed.split_once(']') {
                    Some((host, after)) => (host.to_string(), after.strip_prefix(':').and_then(|port| port.parse().ok())),
                    None => continue,
                }
            } else if each.parse::<IpAddr>().is_ok() {
                (each.clone(), None)
            } else {
                match each.rsplit_once(':') {
                    Some((host, port)) if port.parse::<u16>().is_ok() => (host.to_string(), port.parse().ok()),
                    _ => (each.clone(), None),
                }
            };
            match host.parse::<IpAddr>() {
                Ok(ip) => direct.entries.push(Entry::Ip { bits: if ip.is_ipv4() { 32 } else { 128 }, ip, port }),
                Err(_) => {
                    let under_only = host.starts_with('.') || host.starts_with("*.");
                    let name = host.trim_start_matches('*').trim_start_matches('.').trim_end_matches('.').to_string();
                    if !name.is_empty() {
                        direct.entries.push(Entry::Domain { name, under_only, port });
                    }
                }
            }
        }
        direct
    }

    fn matches(&self, host: &str, port: u16) -> bool {
        if self.every {
            return true;
        }
        let host = host.trim_end_matches('.');
        let ip = host.parse::<IpAddr>().ok().map(|ip| ip.to_canonical());
        self.entries.iter().any(|entry| match entry {
            Entry::Ip { ip: range, bits, port: wanted } => wanted.is_none_or(|wanted| wanted == port) && ip.is_some_and(|ip| within(ip, *range, *bits)),
            Entry::Domain { name, under_only, port: wanted } => {
                let under = host.len() > name.len() && host.ends_with(name.as_str()) && host.as_bytes()[host.len() - name.len() - 1] == b'.';
                wanted.is_none_or(|wanted| wanted == port) && (under || (!under_only && host == name))
            }
        })
    }
}

/// Whether `ip` is in the range of `bits` of `range`.
fn within(ip: IpAddr, range: IpAddr, bits: u8) -> bool {
    match (ip, range.to_canonical()) {
        (IpAddr::V4(ip), IpAddr::V4(range)) => {
            let bits = bits.min(32);
            let mask = if bits == 0 { 0 } else { u32::MAX << (32 - bits) };
            u32::from(ip) & mask == u32::from(range) & mask
        }
        (IpAddr::V6(ip), IpAddr::V6(range)) => {
            let bits = bits.min(128);
            let mask = if bits == 0 { 0 } else { u128::MAX << (128 - bits) };
            u128::from(ip) & mask == u128::from(range) & mask
        }
        _ => false,
    }
}

/// `%xx` in a URL's user or password, as the bytes they stand for.
fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let hex = |at: usize| bytes.get(at).and_then(|byte| (*byte as char).to_digit(16));
        match (bytes[at], hex(at + 1), hex(at + 2)) {
            (b'%', Some(high), Some(low)) => {
                out.push((high * 16 + low) as u8);
                at += 3;
            }
            (byte, _, _) => {
                out.push(byte);
                at += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Standard Base64, padded: what `Basic` credentials are written in.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * index) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn environment(pairs: &[(&str, &str)]) -> Environment {
        let vars: HashMap<String, String> = pairs.iter().map(|(name, value)| (name.to_string(), value.to_string())).collect();
        Environment::read(|name| vars.get(name).cloned())
    }

    fn via(env: &Environment, https: bool, host: &str, port: u16) -> Option<String> {
        env.proxy_for(https, host, port).map(|proxy| proxy.map(|proxy| proxy.shown.clone()).unwrap_or_else(|why| why))
    }

    #[test]
    fn a_proxy_url() {
        let proxy = parse("http://ada:se%3Asame@proxy.example:3128/", "HTTP_PROXY").unwrap();
        assert_eq!((proxy.tls, proxy.host.as_str(), proxy.port), (false, "proxy.example", 3128));
        assert_eq!(proxy.authorization.as_deref(), Some("Basic YWRhOnNlOnNhbWU="), "ada:se:same");
        assert_eq!(proxy.shown, "http://proxy.example:3128", "no credentials in a message");
        assert_eq!(parse("proxy.example:8080", "x").unwrap().shown, "http://proxy.example:8080", "no scheme: http");
        assert_eq!(parse("https://proxy.example", "x").unwrap().port, 443);
        assert_eq!(parse("HTTP://Proxy.Example", "x").unwrap().port, 80);
        assert_eq!(parse("http://[::1]:3128", "x").unwrap().host, "::1");
        assert_eq!(parse("http://[::1]:3128", "x").unwrap().shown, "http://[::1]:3128");
        assert_eq!(parse("socks5://proxy:1080", "ALL").unwrap_err(), "ALL: a proxy is http:// or https://, not socks5://");
        assert!(parse("http://proxy:port", "x").is_err());
        assert!(parse("http://:3128", "x").is_err());
        assert_eq!(parse("http://u@p:1", "x").unwrap().authorization.as_deref(), Some("Basic dTo="), "a user without a password");
    }

    #[test]
    fn base64_as_the_rfc_writes_it() {
        for (plain, encoded) in [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="), ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy")] {
            assert_eq!(base64(plain.as_bytes()), encoded);
        }
    }

    #[test]
    fn each_scheme_its_own_proxy_upper_case_first_an_empty_one_unset() {
        let env = environment(&[("HTTP_PROXY", "http://plain:1"), ("https_proxy", "http://secure:2"), ("HTTPS_PROXY", "")]);
        assert_eq!(via(&env, false, "api.example", 80).as_deref(), Some("http://plain:1"));
        assert_eq!(via(&env, true, "api.example", 443).as_deref(), Some("http://secure:2"), "HTTPS_PROXY empty: https_proxy");
        let upper = environment(&[("HTTP_PROXY", "http://upper:1"), ("http_proxy", "http://lower:2")]);
        assert_eq!(via(&upper, false, "api.example", 80).as_deref(), Some("http://upper:1"));
        assert_eq!(via(&upper, true, "api.example", 443), None, "no HTTPS_PROXY: https goes direct");
        assert_eq!(via(&environment(&[]), false, "api.example", 80), None);
    }

    #[test]
    fn loopback_never_through_the_environments_proxy() {
        let env = environment(&[("HTTP_PROXY", "http://p:1"), ("HTTPS_PROXY", "http://p:1")]);
        for host in ["localhost", "localhost.", "127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1"] {
            assert_eq!(via(&env, false, host, 80), None, "{host}");
        }
        assert!(via(&env, false, "localhost.example", 80).is_some());
        assert!(via(&env, false, "10.0.0.1", 80).is_some());
    }

    #[test]
    fn no_proxy() {
        let env = environment(&[
            ("HTTPS_PROXY", "http://p:1"),
            ("NO_PROXY", " Internal.Example , .corp.example,*.svc.example, 10.0.0.0/8, 192.168.1.7, [2001:db8::1], api.example:8443, fd00::/8 "),
        ]);
        let direct = |host: &str, port: u16| via(&env, true, host, port).is_none();
        assert!(direct("internal.example", 443), "a domain");
        assert!(direct("a.b.internal.example", 443), "and every name under it");
        assert!(!direct("notinternal.example", 443), "not a name that merely ends the same");
        assert!(!direct("corp.example", 443), ".corp.example: only the names under it");
        assert!(direct("x.corp.example", 443));
        assert!(!direct("svc.example", 443) && direct("db.svc.example", 443), "*.svc.example as .svc.example");
        assert!(direct("10.1.2.3", 443) && !direct("11.1.2.3", 443), "a CIDR range");
        assert!(direct("192.168.1.7", 443) && !direct("192.168.1.8", 443), "an address");
        assert!(direct("2001:db8::1", 443), "an IPv6 address");
        assert!(direct("fd12::5", 443), "an IPv6 range");
        assert!(direct("api.example", 8443) && !direct("api.example", 443), "a port: only that port");
        assert!(!direct("example.com", 443));
        let every = environment(&[("HTTP_PROXY", "http://p:1"), ("no_proxy", "*")]);
        assert_eq!(via(&every, false, "anything.example", 80), None, "*: every host");
    }

    #[test]
    fn a_proxy_whose_url_cant_be_read_is_an_error_not_a_way_around_it() {
        let env = environment(&[("HTTPS_PROXY", "socks5://p:1080")]);
        assert_eq!(via(&env, true, "api.example", 443).as_deref(), Some("HTTPS_PROXY: a proxy is http:// or https://, not socks5://"));
    }
}
