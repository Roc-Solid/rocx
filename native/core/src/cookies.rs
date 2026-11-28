//! The phone's cookie jar (D-138): what a browser keeps of the server's `set-cookie`s and sends
//! back with every request to it, so sessions work on a phone as they do in a browser. RFC 6265's
//! storage model, the parts a rocx server uses: a cookie is kept by its name, domain and path;
//! `Domain` (one the host is under; none: the host alone), `Path` (none: the request's directory),
//! `Expires` and `Max-Age` (the second wins; one in the past deletes the cookie), `Secure` (sent over
//! HTTPS alone, and over `http://localhost`, as browsers treat it as secure), `HttpOnly` (kept: there
//! is no page script to hide it from), `SameSite` (every request a phone app makes is its own site's),
//! and the `__Secure-` and `__Host-` prefixes. Sent as one `cookie` header, the longest paths first.
//!
//! Cookies with an expiry are written to the app's files (`Jar::open`) after each change, so a
//! session outlives the app's process, as a browser keeps one across restarts; a session cookie (no
//! expiry) lives as long as the process.

use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Clone, Debug, PartialEq)]
pub struct Cookie {
    pub name: String,
    pub value: String,
    /// Lowercase, without a leading dot.
    pub domain: String,
    /// Sent to `domain` alone (no `Domain` attribute), not to hosts under it.
    pub host_only: bool,
    pub path: String,
    /// Seconds since the epoch; none for a session cookie.
    pub expires: Option<u64>,
    pub secure: bool,
    pub http_only: bool,
    /// When it was first set (ms since the epoch): the order among cookies of one path's length.
    pub created: u64,
}

/// What a request's URL says to a jar: its scheme's security, its host and its path.
#[derive(Clone, Debug)]
pub struct Place {
    pub secure: bool,
    pub host: String,
    pub path: String,
}

impl Place {
    /// `http://host:port/path?query`, as a jar sees it; none for a URL that isn't HTTP(S).
    pub fn of(url: &str) -> Option<Place> {
        let (scheme, rest) = url.split_once("://")?;
        let https = scheme.eq_ignore_ascii_case("https");
        if !https && !scheme.eq_ignore_ascii_case("http") {
            return None;
        }
        let (authority, path) = match rest.find(['/', '?', '#']) {
            Some(at) => (&rest[..at], &rest[at..]),
            None => (rest, "/"),
        };
        let authority = authority.rsplit('@').next().unwrap_or(authority);
        let host = if let Some(inner) = authority.strip_prefix('[') { format!("[{}]", inner.split(']').next().unwrap_or("")) } else { authority.split(':').next().unwrap_or("").to_string() };
        let host = host.to_ascii_lowercase();
        let path = path.split(['?', '#']).next().unwrap_or("");
        let path = if path.starts_with('/') { path.to_string() } else { "/".to_string() };
        // Browsers treat these as secure contexts: a `Secure` cookie is set and sent over plain HTTP.
        let local = host == "localhost" || host.ends_with(".localhost") || host == "127.0.0.1" || host == "[::1]";
        Some(Place { secure: https || local, host, path })
    }
}

#[derive(Default)]
pub struct Jar {
    cookies: Vec<Cookie>,
    file: Option<PathBuf>,
}

impl Jar {
    /// A jar kept in `file` (the app's files), with what was written there before.
    pub fn open(file: PathBuf, now_ms: u64) -> Jar {
        let mut jar = Jar { cookies: Vec::new(), file: Some(file.clone()) };
        if let Ok(text) = std::fs::read_to_string(&file) {
            jar.cookies = text.lines().filter_map(Cookie::read).filter(|cookie| !cookie.expired(now_ms)).collect();
        }
        jar
    }

    pub fn cookies(&self) -> &[Cookie] {
        &self.cookies
    }

    /// A `set-cookie` the server sent in answer to a request to `place`: kept, replacing one of the
    /// same name, domain and path, or deleting it when it has expired. Whether the jar changed.
    pub fn store(&mut self, place: &Place, line: &str, now_ms: u64) -> bool {
        let Some(cookie) = Cookie::parse(place, line, now_ms) else { return false };
        let same = |each: &Cookie| each.name == cookie.name && each.domain == cookie.domain && each.path == cookie.path;
        // A cookie that isn't `Secure` can't take the place of one that is, from an insecure place.
        if !place.secure && self.cookies.iter().any(|each| each.secure && each.name == cookie.name && domain_match(&each.domain, &cookie.domain) && path_match(&cookie.path, &each.path)) {
            return false;
        }
        let at = self.cookies.iter().position(same);
        if cookie.expired(now_ms) {
            return match at {
                Some(at) => {
                    self.cookies.remove(at);
                    true
                }
                None => false,
            };
        }
        match at {
            Some(at) => {
                let created = self.cookies[at].created;
                self.cookies[at] = Cookie { created, ..cookie };
            }
            None => self.cookies.push(cookie),
        }
        true
    }

    /// The `cookie` header for a request to `place`, if any cookie goes with it: the longest paths
    /// first, then the oldest.
    pub fn header(&mut self, place: &Place, now_ms: u64) -> Option<String> {
        self.cookies.retain(|cookie| !cookie.expired(now_ms));
        let mut sent: Vec<&Cookie> = self
            .cookies
            .iter()
            .filter(|cookie| (if cookie.host_only { cookie.domain == place.host } else { domain_match(&place.host, &cookie.domain) }) && path_match(&place.path, &cookie.path) && (!cookie.secure || place.secure))
            .collect();
        if sent.is_empty() {
            return None;
        }
        sent.sort_by(|a, b| b.path.len().cmp(&a.path.len()).then(a.created.cmp(&b.created)));
        Some(sent.iter().map(|cookie| if cookie.name.is_empty() { cookie.value.clone() } else { format!("{}={}", cookie.name, cookie.value) }).collect::<Vec<_>>().join("; "))
    }

    /// Writes the cookies that outlive the process to the jar's file (written whole, then renamed
    /// into place).
    pub fn save(&self) {
        let Some(file) = &self.file else { return };
        let text: String = self.cookies.iter().filter(|cookie| cookie.expires.is_some()).map(|cookie| cookie.line() + "\n").collect();
        let partial = file.with_extension("partial");
        if std::fs::write(&partial, text).is_ok() {
            let _ = std::fs::rename(&partial, file);
        }
    }
}

impl Cookie {
    /// A `set-cookie` line, as RFC 6265 §5.2 and §5.3 read it, from a request to `place`; none for
    /// one a browser would ignore.
    pub fn parse(place: &Place, line: &str, now_ms: u64) -> Option<Cookie> {
        let mut parts = line.split(';');
        let pair = parts.next()?;
        let (name, value) = match pair.split_once('=') {
            Some((name, value)) => (name.trim(), value.trim()),
            None => ("", pair.trim()),
        };
        if name.is_empty() && value.is_empty() {
            return None;
        }
        let mut expires = None;
        let mut max_age = None;
        let mut domain = None;
        let mut path = None;
        let mut secure = false;
        let mut http_only = false;
        for attribute in parts {
            let (key, given) = match attribute.split_once('=') {
                Some((key, given)) => (key.trim(), given.trim()),
                None => (attribute.trim(), ""),
            };
            match key.to_ascii_lowercase().as_str() {
                "expires" => {
                    if let Some(at) = http_date(given) {
                        expires = Some(at);
                    }
                }
                "max-age" => {
                    if let Ok(seconds) = given.parse::<i64>() {
                        max_age = Some(seconds);
                    }
                }
                "domain" if !given.is_empty() => domain = Some(given.trim_start_matches('.').to_ascii_lowercase()),
                "path" => path = given.starts_with('/').then(|| given.to_string()),
                "secure" => secure = true,
                "httponly" => http_only = true,
                _ => {}
            }
        }
        let now = now_ms / 1000;
        let expires = match max_age {
            // Zero or less: already gone.
            Some(seconds) if seconds <= 0 => Some(0),
            Some(seconds) => Some(now.saturating_add(seconds as u64)),
            None => expires,
        };
        let (domain, host_only) = match domain {
            Some(domain) => {
                if !domain_match(&place.host, &domain) {
                    return None;
                }
                (domain, false)
            }
            None => (place.host.clone(), true),
        };
        if secure && !place.secure {
            return None;
        }
        let path = path.unwrap_or_else(|| default_path(&place.path));
        if name.starts_with("__Secure-") && !secure {
            return None;
        }
        if name.starts_with("__Host-") && !(secure && host_only && path == "/") {
            return None;
        }
        Some(Cookie { name: name.to_string(), value: value.to_string(), domain, host_only, path, expires, secure, http_only, created: now_ms })
    }

    fn expired(&self, now_ms: u64) -> bool {
        self.expires.is_some_and(|at| at <= now_ms / 1000)
    }

    /// One line of the jar's file: its fields, tab-separated (a cookie's name and value hold no tab).
    fn line(&self) -> String {
        format!("{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}", self.name, self.value, self.domain, self.host_only as u8, self.path, self.expires.unwrap_or(0), self.secure as u8, self.http_only as u8, self.created)
    }

    fn read(line: &str) -> Option<Cookie> {
        let fields: Vec<&str> = line.split('\t').collect();
        let [name, value, domain, host_only, path, expires, secure, http_only, created] = fields[..] else { return None };
        Some(Cookie {
            name: name.to_string(),
            value: value.to_string(),
            domain: domain.to_string(),
            host_only: host_only == "1",
            path: path.to_string(),
            expires: Some(expires.parse().ok()?),
            secure: secure == "1",
            http_only: http_only == "1",
            created: created.parse().ok()?,
        })
    }
}

/// Whether `host` is `domain` or under it (RFC 6265 §5.1.3); an IP address only itself.
fn domain_match(host: &str, domain: &str) -> bool {
    if host == domain {
        return true;
    }
    let numeric = host.starts_with('[') || host.parse::<std::net::Ipv4Addr>().is_ok();
    !numeric && host.ends_with(domain) && host[..host.len() - domain.len()].ends_with('.')
}

/// Whether a request's `path` is under a cookie's (RFC 6265 §5.1.4).
fn path_match(path: &str, cookie: &str) -> bool {
    path == cookie || (path.starts_with(cookie) && (cookie.ends_with('/') || path[cookie.len()..].starts_with('/')))
}

/// A cookie's path when it says none: the request's directory (RFC 6265 §5.1.4).
fn default_path(path: &str) -> String {
    match path.rfind('/') {
        Some(0) | None => "/".into(),
        Some(at) => path[..at].to_string(),
    }
}

/// An `Expires` date (RFC 6265 §5.1.1, which takes any of the formats servers send): seconds since
/// the epoch, or none for a date it can't read.
pub fn http_date(text: &str) -> Option<u64> {
    let (mut day, mut month, mut year, mut time) = (None, None, None, None);
    for token in text.split(|c: char| !(c.is_ascii_alphanumeric() || c == ':')).filter(|token| !token.is_empty()) {
        if time.is_none() && token.contains(':') {
            let parts: Vec<u64> = token.split(':').filter_map(|part| part.parse().ok()).collect();
            if parts.len() == 3 {
                time = Some((parts[0], parts[1], parts[2]));
                continue;
            }
        }
        if day.is_none() && token.len() <= 2 && token.chars().all(|c| c.is_ascii_digit()) {
            day = token.parse::<u64>().ok();
            continue;
        }
        if month.is_none() && token.len() >= 3 {
            const MONTHS: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
            let lower = token[..3].to_ascii_lowercase();
            if let Some(at) = MONTHS.iter().position(|name| *name == lower) {
                month = Some(at as u64 + 1);
                continue;
            }
        }
        if year.is_none() && (2..=4).contains(&token.len()) && token.chars().all(|c| c.is_ascii_digit()) {
            let given: u64 = token.parse().ok()?;
            year = Some(match given {
                70..=99 => given + 1900,
                0..=69 => given + 2000,
                _ => given,
            });
        }
    }
    let (day, month, year, (hour, minute, second)) = (day?, month?, year?, time?);
    if !(1..=31).contains(&day) || year < 1601 || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    // Days from 1970-01-01 to the date (Howard Hinnant's days_from_civil).
    let (y, m) = (year as i64 - i64::from(month <= 2), month as i64);
    let era = y.div_euclid(400);
    let of_era = y - era * 400;
    let of_year = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + day as i64 - 1;
    let of_cycle = of_era * 365 + of_era / 4 - of_era / 100 + of_year;
    let days = era * 146_097 + of_cycle - 719_468;
    let seconds = days * 86_400 + (hour * 3600 + minute * 60 + second) as i64;
    (seconds >= 0).then_some(seconds as u64)
}

/// The app's jar: every request's cookies (`http.rs`), on any thread.
pub static JAR: Mutex<Option<Jar>> = Mutex::new(None);

/// The app's jar, kept in `dir` (the app's files dir) from now on, with the cookies kept there.
pub fn keep_in(dir: &str, now_ms: u64) {
    let file = PathBuf::from(dir).join("rocx-cookies.txt");
    *JAR.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Jar::open(file, now_ms));
}

/// The `cookie` header for a request to `url`.
pub fn for_request(url: &str, now_ms: u64) -> Option<String> {
    let place = Place::of(url)?;
    JAR.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).get_or_insert_with(Jar::default).header(&place, now_ms)
}

/// The `set-cookie`s of an answer to a request to `url`, kept (and written to the jar's file).
pub fn from_answer(url: &str, headers: &[(String, String)], now_ms: u64) {
    let Some(place) = Place::of(url) else { return };
    let mut jar = JAR.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let jar = jar.get_or_insert_with(Jar::default);
    let mut changed = false;
    for (name, value) in headers {
        if name.eq_ignore_ascii_case("set-cookie") {
            changed |= jar.store(&place, value, now_ms);
        }
    }
    if changed {
        jar.save();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_764_340_000_000;

    fn place(url: &str) -> Place {
        Place::of(url).unwrap()
    }

    #[test]
    fn a_cookie_is_sent_back_to_its_host_and_path() {
        let mut jar = Jar::default();
        let at = place("http://localhost:8098/auth/dev");
        assert!(jar.store(&at, "session=abc; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000", NOW));
        assert!(jar.store(&at, "dev=1", NOW));
        assert_eq!(jar.header(&place("http://localhost:8098/"), NOW).as_deref(), Some("session=abc"));
        assert_eq!(jar.header(&place("http://localhost:8098/auth/dev?x=1"), NOW).as_deref(), Some("dev=1; session=abc"), "the default path is the request's directory, the longer path first");
        assert_eq!(jar.header(&place("http://localhost:8098/authority"), NOW).as_deref(), Some("session=abc"), "/auth isn't /authority's");
        assert_eq!(jar.header(&place("http://10.0.2.2:8098/"), NOW), None, "another host");
        assert_eq!(jar.header(&place("http://sub.localhost:8098/"), NOW), None, "host-only");
    }

    #[test]
    fn a_cookie_is_replaced_and_deleted() {
        let mut jar = Jar::default();
        let at = place("http://localhost:8098/login");
        jar.store(&at, "session=one; Path=/", NOW);
        jar.store(&at, "session=two; Path=/", NOW + 5);
        assert_eq!(jar.cookies().len(), 1);
        assert_eq!(jar.cookies()[0].value, "two");
        assert_eq!(jar.cookies()[0].created, NOW, "a replaced cookie keeps its creation");
        assert!(jar.store(&at, "session=; Path=/; Max-Age=0", NOW));
        assert!(jar.cookies().is_empty());
        jar.store(&at, "flash=x; Path=/", NOW);
        jar.store(&at, "flash=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT", NOW);
        assert!(jar.cookies().is_empty(), "an expiry in the past deletes it");
        jar.store(&at, "keep=1; Path=/; Max-Age=60", NOW);
        assert_eq!(jar.header(&at, NOW + 59_000).as_deref(), Some("keep=1"));
        assert_eq!(jar.header(&at, NOW + 60_000), None, "expired");
    }

    #[test]
    fn domain_and_secure_are_as_a_browser_has_them() {
        let mut jar = Jar::default();
        let at = place("https://app.acme.example/");
        assert!(jar.store(&at, "wide=1; Domain=.acme.example; Path=/", NOW));
        assert!(!jar.store(&at, "other=1; Domain=evil.example", NOW), "a domain the host isn't under");
        assert!(jar.store(&at, "s=1; Secure; Path=/", NOW));
        assert_eq!(jar.header(&place("https://api.acme.example/x"), NOW).as_deref(), Some("wide=1"));
        assert_eq!(jar.header(&place("http://app.acme.example/"), NOW).as_deref(), Some("wide=1"), "Secure goes over HTTPS alone");
        assert_eq!(jar.header(&place("https://app.acme.example/"), NOW).as_deref(), Some("wide=1; s=1"));
        assert!(!jar.store(&place("http://app.acme.example/"), "t=1; Secure", NOW), "set over plain HTTP");
        assert!(jar.store(&place("http://localhost:8098/"), "t=1; Secure; Path=/", NOW), "localhost is secure, as browsers have it");
        assert!(!jar.store(&at, "__Host-x=1; Secure; Path=/; Domain=acme.example", NOW));
        assert!(jar.store(&at, "__Host-x=1; Secure; Path=/", NOW));
        assert!(!jar.store(&at, "__Secure-y=1; Path=/", NOW));
    }

    #[test]
    fn dates_are_read_in_the_formats_servers_send() {
        assert_eq!(http_date("Wed, 21 Oct 2015 07:28:00 GMT"), Some(1_445_412_480));
        assert_eq!(http_date("Wednesday, 21-Oct-15 07:28:00 GMT"), Some(1_445_412_480));
        assert_eq!(http_date("Wed Oct 21 07:28:00 2015"), Some(1_445_412_480));
        assert_eq!(http_date("Thu, 01 Jan 1970 00:00:00 GMT"), Some(0));
        assert_eq!(http_date("Sat, 29 Feb 2028 23:59:59 GMT"), Some(1_835_481_599));
        assert_eq!(http_date("tomorrow"), None);
    }

    #[test]
    fn the_jar_outlives_the_process() {
        let dir = std::env::temp_dir().join(format!("rocx-jar-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("cookies.txt");
        let _ = std::fs::remove_file(&file);
        let at = place("http://localhost:8098/");
        let mut jar = Jar::open(file.clone(), NOW);
        jar.store(&at, "session=abc; Path=/; Max-Age=3600", NOW);
        jar.store(&at, "tab=1; Path=/", NOW);
        jar.save();
        let mut again = Jar::open(file.clone(), NOW + 1000);
        assert_eq!(again.header(&at, NOW + 1000).as_deref(), Some("session=abc"), "the session cookie (no expiry) stays with the process");
        let later = Jar::open(file, NOW + 3_601_000);
        assert!(later.cookies().is_empty(), "expired while the app was closed");
        let _ = std::fs::remove_dir_all(dir);
    }
}
