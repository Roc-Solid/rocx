//! URLs as the phone needs them (D-138): a reference resolved against the URL it appears on (a
//! redirect's `location`, a link's `href`, `Router.navigate!`'s target), as a browser's `new
//! URL(reference, base)` does for HTTP URLs (RFC 3986 §5.2: dot segments removed), and an absolute
//! URL taken apart into its origin, path, query and hash.

/// An absolute HTTP(S) URL's parts: `origin` (`http://host:port`, its scheme and host lowercase),
/// `path` (from `/`), `query` (after `?`, without it), `hash` (after `#`, without it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Url {
    pub origin: String,
    pub path: String,
    pub query: Option<String>,
    pub hash: Option<String>,
}

impl Url {
    pub fn parse(url: &str) -> Option<Url> {
        let (scheme, rest) = url.split_once("://")?;
        let scheme = scheme.to_ascii_lowercase();
        if scheme != "http" && scheme != "https" {
            return None;
        }
        let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let authority = rest[..end].to_ascii_lowercase();
        if authority.is_empty() {
            return None;
        }
        // The scheme's own port is no port (`http://host:80` is `http://host`).
        let authority = authority.strip_suffix(if scheme == "http" { ":80" } else { ":443" }).map(str::to_string).unwrap_or(authority);
        let (before_hash, hash) = match rest[end..].split_once('#') {
            Some((before, hash)) => (before, Some(hash.to_string())),
            None => (&rest[end..], None),
        };
        let (path, query) = match before_hash.split_once('?') {
            Some((path, query)) => (path, Some(query.to_string())),
            None => (before_hash, None),
        };
        let path = if path.is_empty() { "/".to_string() } else { remove_dots(path) };
        Some(Url { origin: format!("{scheme}://{authority}"), path, query, hash })
    }

    /// `reference` resolved against this URL; none for one that isn't HTTP(S) (`mailto:`, `tel:`).
    pub fn join(&self, reference: &str) -> Option<Url> {
        let reference = reference.trim();
        if let Some((scheme, _)) = reference.split_once(':')
            && !scheme.is_empty()
            && scheme.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
            && scheme.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        {
            return Url::parse(reference);
        }
        if let Some(rest) = reference.strip_prefix("//") {
            let scheme = self.origin.split("://").next().unwrap_or("http");
            return Url::parse(&format!("{scheme}://{rest}"));
        }
        let (before_hash, hash) = match reference.split_once('#') {
            Some((before, hash)) => (before, Some(hash.to_string())),
            None => (reference, None),
        };
        let (path, query) = match before_hash.split_once('?') {
            Some((path, query)) => (path, Some(query.to_string())),
            None => (before_hash, None),
        };
        let (path, query) = if path.is_empty() {
            (self.path.clone(), if query.is_some() { query } else { self.query.clone() })
        } else if path.starts_with('/') {
            (remove_dots(path), query)
        } else {
            let directory = &self.path[..self.path.rfind('/').map(|at| at + 1).unwrap_or(0)];
            (remove_dots(&format!("{directory}{path}")), query)
        };
        Some(Url { origin: self.origin.clone(), path, query, hash })
    }

    /// The path and query (`/a?b`), as a request line and `Router.location!` have them.
    pub fn target(&self) -> String {
        match &self.query {
            Some(query) => format!("{}?{query}", self.path),
            None => self.path.clone(),
        }
    }

    /// The whole URL, without its hash (a document's key: the browser's `documentKey`).
    pub fn without_hash(&self) -> String {
        format!("{}{}", self.origin, self.target())
    }

    pub fn href(&self) -> String {
        match &self.hash {
            Some(hash) => format!("{}#{hash}", self.without_hash()),
            None => self.without_hash(),
        }
    }
}

/// A path with its `.` and `..` segments taken out (RFC 3986 §5.2.4).
fn remove_dots(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    let segments: Vec<&str> = path.split('/').collect();
    let last = segments.len() - 1;
    for (at, segment) in segments.iter().enumerate() {
        match *segment {
            "." => {
                if at == last {
                    out.push("");
                }
            }
            ".." => {
                if out.len() > 1 {
                    out.pop();
                }
                if at == last {
                    out.push("");
                }
            }
            other => out.push(other),
        }
    }
    let joined = out.join("/");
    if joined.starts_with('/') { joined } else { format!("/{joined}") }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(url: &str) -> Url {
        Url::parse(url).unwrap()
    }

    #[test]
    fn a_url_is_taken_apart() {
        let url = at("HTTP://LocalHost:8098/posts/7?from=2026-11-21#top");
        assert_eq!(url.origin, "http://localhost:8098");
        assert_eq!(url.path, "/posts/7");
        assert_eq!(url.query.as_deref(), Some("from=2026-11-21"));
        assert_eq!(url.hash.as_deref(), Some("top"));
        assert_eq!(url.target(), "/posts/7?from=2026-11-21");
        assert_eq!(at("http://acme.example").path, "/");
        assert_eq!(at("http://acme.example:80/x").origin, "http://acme.example");
        assert_eq!(at("https://acme.example:443/x").origin, "https://acme.example");
        assert_eq!(Url::parse("mailto:a@acme.example"), None);
    }

    #[test]
    fn references_resolve_as_a_browser_has_them() {
        let base = at("http://localhost:8098/posts/7?from=x");
        assert_eq!(base.join("/login?then=%2F").unwrap().href(), "http://localhost:8098/login?then=%2F");
        assert_eq!(base.join("8").unwrap().href(), "http://localhost:8098/posts/8");
        assert_eq!(base.join("../calendar").unwrap().href(), "http://localhost:8098/calendar");
        assert_eq!(base.join("?from=y").unwrap().href(), "http://localhost:8098/posts/7?from=y");
        assert_eq!(base.join("#comments").unwrap().href(), "http://localhost:8098/posts/7?from=x#comments");
        assert_eq!(base.join("").unwrap().href(), "http://localhost:8098/posts/7?from=x");
        assert_eq!(base.join("//cdn.acme.example/a.png").unwrap().href(), "http://cdn.acme.example/a.png");
        assert_eq!(base.join("https://accounts.acme.example/o?x=1").unwrap().origin, "https://accounts.acme.example");
        assert_eq!(base.join("/a/./b/../c/").unwrap().path, "/a/c/");
        assert_eq!(base.join("/../..").unwrap().path, "/");
        assert!(base.join("mailto:someone@acme.example").is_none());
        assert!(base.join("tel:+15550100").is_none());
    }
}
