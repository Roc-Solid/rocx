//! Objects kept by key, for packages/storage's `file:` and `memory:` buckets (D-047): the platform's
//! `Blobs`. A root is a directory (`file:<dir>`, made when missing) or a map in the server's memory
//! (`memory:<name>`, gone when it stops). An object is its bytes, its content type and its ETag (its
//! MD5, as S3 has one for a single put); a directory keeps the bytes at `<dir>/<key>` and the rest
//! beside them, in `<dir>/.storage/meta/<key>`, out of a key's reach.
//!
//! A put is written to a file of its own first (`<dir>/.storage/tmp/…`), then renamed into its
//! place: a crash leaves the object as it was, never half of the new one. A key is one or more
//! segments between `/`s, none empty, `.` or `..`, and the first not `.storage`; anything else is
//! refused, so a key never reaches outside its root.
//!
//! Every function here blocks (files); the hosted functions run them on tokio's blocking threads.

use bytes::Bytes;
use md5::{Digest, Md5};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

/// What a lookup finds no object for: the hosted functions answer it as this text, which `Blobs`
/// reads as `NotFound`.
pub const NOT_FOUND: &str = "NotFound";

/// The directory a file root keeps its objects' details and its writes in progress in.
const OWN: &str = ".storage";

/// Where objects are kept.
#[derive(Clone, Debug)]
pub enum Root {
    Dir(PathBuf),
    Memory(String),
}

/// An object in memory.
struct Kept {
    bytes: Bytes,
    content_type: String,
    etag: String,
    modified: SystemTime,
}

static MEMORY: LazyLock<Mutex<HashMap<String, HashMap<String, Arc<Kept>>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static SECRETS: LazyLock<Mutex<HashMap<String, String>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// An object's details: its size, content type, ETag (no quotes) and when it was last written.
#[derive(Clone, Debug)]
pub struct Info {
    pub size: u64,
    pub content_type: String,
    pub etag: String,
    pub modified: SystemTime,
}

/// An object to send: its details, and where its bytes are.
pub enum Found {
    File(PathBuf, Info),
    Memory(Bytes, Info),
}

/// The root `spec` names: `file:<dir>` or `memory:<name>` (`memory:` alone is the name "").
pub fn root(spec: &str) -> Result<Root, String> {
    if let Some(dir) = spec.strip_prefix("file:") {
        let dir = dir.strip_prefix("//").unwrap_or(dir);
        if dir.is_empty() {
            return Err("file: needs a directory (file:data/uploads)".into());
        }
        Ok(Root::Dir(PathBuf::from(dir)))
    } else if let Some(name) = spec.strip_prefix("memory:") {
        Ok(Root::Memory(name.to_string()))
    } else {
        Err(format!("a bucket's root is file:<dir> or memory:<name>, not `{spec}`"))
    }
}

/// The key's path under a directory, if it is a key: segments, none empty, `.` or `..`, the
/// first not the root's own.
fn path_of(dir: &Path, key: &str) -> Result<PathBuf, String> {
    let refused = || format!("`{key}` isn't a key: segments between /s, none empty, . or .., not starting with {OWN}");
    if key.is_empty() || key.contains('\0') || key.contains('\\') {
        return Err(refused());
    }
    let segments: Vec<&str> = key.split('/').collect();
    if segments.iter().any(|segment| segment.is_empty() || *segment == "." || *segment == "..") || segments[0] == OWN {
        return Err(refused());
    }
    let relative = Path::new(key);
    if !relative.components().all(|part| matches!(part, Component::Normal(_))) {
        return Err(refused());
    }
    Ok(dir.join(relative))
}

/// A key checked as `path_of` checks one, for memory.
fn checked(key: &str) -> Result<(), String> {
    path_of(Path::new("."), key).map(|_| ())
}

fn meta_path(dir: &Path, key: &str) -> PathBuf {
    dir.join(OWN).join("meta").join(key)
}

fn md5_hex(bytes: &[u8]) -> String {
    let digest = Md5::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn failed(what: &str, path: &Path, error: std::io::Error) -> String {
    format!("{what} {}: {error}", path.display())
}

/// A new file in the root's own directory, to write before it is renamed into its place.
fn temporary(dir: &Path) -> Result<(PathBuf, fs::File), String> {
    let tmp = dir.join(OWN).join("tmp");
    fs::create_dir_all(&tmp).map_err(|error| failed("can't make", &tmp, error))?;
    let mut random = [0u8; 12];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut random).map_err(|_| "no random bytes".to_string())?;
    let name: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let path = tmp.join(name);
    let file = fs::File::create(&path).map_err(|error| failed("can't write", &path, error))?;
    Ok((path, file))
}

/// `from` renamed to `to`, its directory made first.
fn placed(from: &Path, to: &Path) -> Result<(), String> {
    if let Some(parent) = to.parent() {
        fs::create_dir_all(parent).map_err(|error| failed("can't make", parent, error))?;
    }
    fs::rename(from, to).map_err(|error| {
        let _ = fs::remove_file(from);
        failed("can't write", to, error)
    })
}

/// `meta` (an object's content type and ETag) written for `key`, as an object is.
fn write_meta(dir: &Path, key: &str, content_type: &str, etag: &str) -> Result<(), String> {
    let (path, mut file) = temporary(dir)?;
    let text = json!({ "content_type": content_type, "etag": etag }).to_string();
    file.write_all(text.as_bytes()).map_err(|error| failed("can't write", &path, error))?;
    drop(file);
    placed(&path, &meta_path(dir, key))
}

/// Keeps `bytes` at `key`, in place of what was there.
pub fn put(root: &Root, key: &str, bytes: Vec<u8>, content_type: &str) -> Result<(), String> {
    let etag = md5_hex(&bytes);
    match root {
        Root::Dir(dir) => {
            let target = path_of(dir, key)?;
            let (path, mut file) = temporary(dir)?;
            file.write_all(&bytes).and_then(|()| file.sync_data()).map_err(|error| failed("can't write", &path, error))?;
            drop(file);
            write_meta(dir, key, content_type, &etag)?;
            placed(&path, &target)
        }
        Root::Memory(name) => {
            checked(key)?;
            let kept = Kept { bytes: Bytes::from(bytes), content_type: content_type.to_string(), etag, modified: SystemTime::now() };
            MEMORY.lock().unwrap().entry(name.clone()).or_default().insert(key.to_string(), Arc::new(kept));
            Ok(())
        }
    }
}

/// The object at `key`: where its bytes are, and its details. `NOT_FOUND` when there is none.
pub fn find(root: &Root, key: &str) -> Result<Found, String> {
    match root {
        Root::Dir(dir) => {
            let path = path_of(dir, key)?;
            let metadata = match fs::metadata(&path) {
                Ok(metadata) if metadata.is_file() => metadata,
                Ok(_) => return Err(NOT_FOUND.into()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Err(NOT_FOUND.into()),
                Err(error) => return Err(failed("can't read", &path, error)),
            };
            let modified = metadata.modified().unwrap_or(UNIX_EPOCH);
            let meta: Option<Value> = fs::read_to_string(meta_path(dir, key)).ok().and_then(|text| serde_json::from_str(&text).ok());
            let text = |name: &str| meta.as_ref().and_then(|meta| meta.get(name)).and_then(Value::as_str).map(str::to_string);
            // An object put there by hand has no details: its type from its name, an ETag from its
            // size and when it was written.
            let since = modified.duration_since(UNIX_EPOCH).unwrap_or_default();
            let info = Info {
                size: metadata.len(),
                content_type: text("content_type").unwrap_or_else(|| crate::http::content_type(&path).to_string()),
                etag: text("etag").unwrap_or_else(|| format!("{:x}-{:x}", metadata.len(), since.as_nanos())),
                modified,
            };
            Ok(Found::File(path, info))
        }
        Root::Memory(name) => {
            checked(key)?;
            let kept = MEMORY.lock().unwrap().get(name).and_then(|objects| objects.get(key).cloned()).ok_or_else(|| NOT_FOUND.to_string())?;
            let info = Info { size: kept.bytes.len() as u64, content_type: kept.content_type.clone(), etag: kept.etag.clone(), modified: kept.modified };
            Ok(Found::Memory(kept.bytes.clone(), info))
        }
    }
}

/// The object at `key`'s details.
pub fn head(root: &Root, key: &str) -> Result<Info, String> {
    match find(root, key)? {
        Found::File(_, info) | Found::Memory(_, info) => Ok(info),
    }
}

/// `length` bytes of the object at `key` from `offset` (fewer at its end), and its size.
pub fn range(root: &Root, key: &str, offset: u64, length: u64) -> Result<(Vec<u8>, u64), String> {
    match find(root, key)? {
        Found::File(path, info) => {
            let start = offset.min(info.size);
            let wanted = length.min(info.size - start);
            let mut file = fs::File::open(&path).map_err(|error| failed("can't read", &path, error))?;
            file.seek(SeekFrom::Start(start)).map_err(|error| failed("can't read", &path, error))?;
            let mut bytes = Vec::with_capacity(wanted as usize);
            file.take(wanted).read_to_end(&mut bytes).map_err(|error| failed("can't read", &path, error))?;
            Ok((bytes, info.size))
        }
        Found::Memory(bytes, info) => {
            let start = (offset.min(info.size)) as usize;
            let end = (start as u64 + length).min(info.size) as usize;
            Ok((bytes[start..end].to_vec(), info.size))
        }
    }
}

/// The object at `key`, whole.
pub fn get(root: &Root, key: &str) -> Result<Vec<u8>, String> {
    match find(root, key)? {
        Found::File(path, _) => fs::read(&path).map_err(|error| failed("can't read", &path, error)),
        Found::Memory(bytes, _) => Ok(bytes.to_vec()),
    }
}

/// The object at `key` gone (none is no problem), and the directories it leaves empty.
pub fn delete(root: &Root, key: &str) -> Result<(), String> {
    match root {
        Root::Dir(dir) => {
            let path = path_of(dir, key)?;
            match fs::remove_file(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(failed("can't delete", &path, error)),
            }
            let meta = meta_path(dir, key);
            let _ = fs::remove_file(&meta);
            emptied(dir, &path);
            emptied(&dir.join(OWN).join("meta"), &meta);
            Ok(())
        }
        Root::Memory(name) => {
            checked(key)?;
            if let Some(objects) = MEMORY.lock().unwrap().get_mut(name) {
                objects.remove(key);
            }
            Ok(())
        }
    }
}

/// The directories between `path` and `top` that are empty now, removed.
fn emptied(top: &Path, path: &Path) {
    let mut at = path.parent();
    while let Some(dir) = at {
        if dir == top || !dir.starts_with(top) || fs::remove_dir(dir).is_err() {
            break;
        }
        at = dir.parent();
    }
}

/// The objects at `parts`, joined in order, kept at `key` (a multipart upload's end); the parts
/// stay (the caller deletes them). Its ETag is as S3 makes a multipart object's: the MD5 of its
/// parts' MD5s, and how many there are (`…-3`). `NOT_FOUND` when one isn't there.
pub fn compose(root: &Root, parts: &[String], key: &str, content_type: &str) -> Result<(), String> {
    let mut digests = Vec::new();
    for part in parts {
        let info = head(root, part)?;
        for at in (0..info.etag.len()).step_by(2) {
            digests.push(u8::from_str_radix(info.etag.get(at..at + 2).unwrap_or("00"), 16).unwrap_or(0));
        }
    }
    let etag = format!("{}-{}", md5_hex(&digests), parts.len());
    match root {
        Root::Dir(dir) => {
            let target = path_of(dir, key)?;
            let (path, mut file) = temporary(dir)?;
            let written: Result<(), String> = (|| {
                for part in parts {
                    let Found::File(from, _) = find(root, part)? else { return Err(NOT_FOUND.into()) };
                    let mut reader = fs::File::open(&from).map_err(|error| failed("can't read", &from, error))?;
                    std::io::copy(&mut reader, &mut file).map_err(|error| failed("can't write", &path, error))?;
                }
                file.sync_data().map_err(|error| failed("can't write", &path, error))
            })();
            drop(file);
            if let Err(why) = written {
                let _ = fs::remove_file(&path);
                return Err(why);
            }
            write_meta(dir, key, content_type, &etag)?;
            placed(&path, &target)
        }
        Root::Memory(name) => {
            checked(key)?;
            let mut whole = Vec::new();
            for part in parts {
                whole.extend_from_slice(&get(root, part)?);
            }
            let kept = Kept { bytes: Bytes::from(whole), content_type: content_type.to_string(), etag, modified: SystemTime::now() };
            MEMORY.lock().unwrap().entry(name.clone()).or_default().insert(key.to_string(), Arc::new(kept));
            Ok(())
        }
    }
}

/// The keys that start with `prefix`, in order: in a directory, the files under it (but the root's
/// own); in memory, the map's keys.
pub fn keys(root: &Root, prefix: &str) -> Result<Vec<String>, String> {
    let mut found = match root {
        Root::Dir(dir) => {
            // From the deepest directory the prefix names, down.
            let base = match prefix.rfind('/') {
                Some(at) => &prefix[..at],
                None => "",
            };
            let start = if base.is_empty() { dir.clone() } else { path_of(dir, base)? };
            let mut keys = Vec::new();
            let mut pending = vec![start];
            while let Some(at) = pending.pop() {
                let entries = match fs::read_dir(&at) {
                    Ok(entries) => entries,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                    Err(error) => return Err(failed("can't read", &at, error)),
                };
                for entry in entries.flatten() {
                    let path = entry.path();
                    let Ok(relative) = path.strip_prefix(dir) else { continue };
                    let key = relative.to_string_lossy().replace('\\', "/");
                    if key == OWN || key.starts_with(&format!("{OWN}/")) {
                        continue;
                    }
                    if path.is_dir() {
                        pending.push(path);
                    } else if key.starts_with(prefix) {
                        keys.push(key);
                    }
                }
            }
            keys
        }
        Root::Memory(name) => MEMORY.lock().unwrap().get(name).map(|objects| objects.keys().filter(|key| key.starts_with(prefix)).cloned().collect()).unwrap_or_default(),
    };
    found.sort();
    Ok(found)
}

/// Whether the root can be written: its directory made (and written to, and cleaned) when missing.
pub fn check(root: &Root) -> Result<(), String> {
    match root {
        Root::Dir(dir) => {
            let (path, file) = temporary(dir)?;
            drop(file);
            fs::remove_file(&path).map_err(|error| failed("can't delete", &path, error))
        }
        Root::Memory(_) => Ok(()),
    }
}

/// The secret the root's signed URLs are made with when its URL gives none: drawn when it is first
/// asked for, and kept while the server runs.
pub fn secret(spec: &str) -> String {
    SECRETS
        .lock()
        .unwrap()
        .entry(spec.to_string())
        .or_insert_with(|| {
            let mut random = [0u8; 32];
            let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut random);
            random.iter().map(|byte| format!("{byte:02x}")).collect()
        })
        .clone()
}
