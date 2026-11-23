//! Plugins' files (`Plugin.File`, D-050): handed to the host once, as the platform starts
//! (`roc_host_plugin_file`), and served as they are, before anything else answers the request, the
//! app's middleware among it, never through Roc. `GET` and `HEAD`, with the file's content type
//! and an ETag of its bytes (304 when the request's `If-None-Match` has it); any other method, 405.
//! And their scripts (`roc_host_page_scripts`), which every page the host renders loads
//! (`signals::document`).

use crate::http::Body;
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::header::{ALLOW, CACHE_CONTROL, CONTENT_LENGTH, CONTENT_TYPE, ETAG, HeaderValue, IF_NONE_MATCH};
use hyper::{Method, Request, Response, StatusCode};
use std::sync::{LazyLock, RwLock};

/// A file, as the host keeps it.
struct File {
    /// Where it is served: `/rocx/plugins/push/push.js`, `/push-sw.js`.
    url: String,
    content_type: String,
    body: Bytes,
    /// Its bytes' SHA-256, quoted, as `ETag` has it.
    etag: String,
}

static FILES: LazyLock<RwLock<Vec<File>>> = LazyLock::new(|| RwLock::new(Vec::new()));
static SCRIPTS: LazyLock<RwLock<Vec<String>>> = LazyLock::new(|| RwLock::new(Vec::new()));

/// Keeps a file to serve at `url` (one there already is replaced: the platform hands each once).
pub fn add(url: String, content_type: String, body: Vec<u8>) {
    let digest = ring::digest::digest(&ring::digest::SHA256, &body);
    let etag = format!("\"{}\"", digest.as_ref().iter().take(16).map(|byte| format!("{byte:02x}")).collect::<String>());
    let mut files = FILES.write().unwrap_or_else(|poisoned| poisoned.into_inner());
    files.retain(|file| file.url != url);
    files.push(File { url, content_type, body: Bytes::from(body), etag });
}

/// The scripts every page loads, by URL, in the plugins' order.
pub fn set_scripts(urls: Vec<String>) {
    *SCRIPTS.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = urls;
}

/// The tags that load the scripts, as a page has them before start.js (web/runtime.js's
/// `scriptTags` writes the same).
pub fn script_tags() -> String {
    let scripts = SCRIPTS.read().unwrap_or_else(|poisoned| poisoned.into_inner());
    scripts.iter().map(|url| format!(r#"<script type="module" data-rocx src="{}"></script>"#, url.replace('&', "&amp;").replace('"', "&quot;"))).collect()
}

/// The answer for a request at `path`, if a plugin has a file there.
pub fn answer<B>(request: &Request<B>, path: &str, dev: bool) -> Option<Response<Body>> {
    let files = FILES.read().unwrap_or_else(|poisoned| poisoned.into_inner());
    let file = files.iter().find(|file| file.url == path)?;
    let method = request.method();
    if method != Method::GET && method != Method::HEAD {
        let mut refused = Response::new(Full::new(Bytes::from_static(b"Method Not Allowed")).boxed());
        *refused.status_mut() = StatusCode::METHOD_NOT_ALLOWED;
        refused.headers_mut().insert(ALLOW, HeaderValue::from_static("GET, HEAD"));
        refused.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_static("text/plain; charset=utf-8"));
        return Some(refused);
    }
    let etag = HeaderValue::from_str(&file.etag).ok()?;
    let cache = HeaderValue::from_static(if dev { "no-store" } else { "no-cache" });
    let met = request.headers().get_all(IF_NONE_MATCH).iter().filter_map(|value| value.to_str().ok()).any(|given| {
        given.split(',').any(|tag| {
            let tag = tag.trim();
            tag == "*" || tag.trim_start_matches("W/") == file.etag
        })
    });
    let (status, body) = if met {
        (StatusCode::NOT_MODIFIED, Bytes::new())
    } else if method == Method::HEAD {
        (StatusCode::OK, Bytes::new())
    } else {
        (StatusCode::OK, file.body.clone())
    };
    let mut response = Response::new(Full::new(body).boxed());
    *response.status_mut() = status;
    let headers = response.headers_mut();
    headers.insert(ETAG, etag);
    headers.insert(CACHE_CONTROL, cache);
    if !met {
        headers.insert(CONTENT_TYPE, HeaderValue::from_str(&file.content_type).unwrap_or(HeaderValue::from_static("application/octet-stream")));
        headers.insert(CONTENT_LENGTH, HeaderValue::from(file.body.len()));
    }
    Some(response)
}

/// The files, as JSON (`GET /__rocx/plugin-files`, under `--debug`): each one's URL and type, and
/// whether pages load it as a script. What a static copy of the site copies (site/build.mjs).
pub fn listed() -> String {
    let files = FILES.read().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scripts = SCRIPTS.read().unwrap_or_else(|poisoned| poisoned.into_inner());
    let each: Vec<serde_json::Value> = files
        .iter()
        .map(|file| serde_json::json!({ "url": file.url, "content_type": file.content_type, "script": scripts.contains(&file.url) }))
        .collect();
    serde_json::Value::Array(each).to_string()
}
