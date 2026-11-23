//! Watching a directory tree. Every file under it is known by its size and modification time
//! (`Tree`); whatever the system says changed is looked at again, and a file is reported only when
//! it differs from what was known: macOS reports a change of metadata, an event it delivers late
//! and an editor's temporary file, none of which is an edit.
//!
//! On macOS the system says so through FSEvents, loaded when watching starts (`dlopen`): Roc links
//! an app against the C library alone, so a framework can't be linked. Elsewhere, or when FSEvents
//! can't be loaded, the trees are walked again every 250 ms (inotify would do for Linux).

use crate::events::{Event, push};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

struct Tree {
    root: PathBuf,
    skip: Vec<String>,
    stamps: HashMap<PathBuf, (u64, u128)>,
}

fn stamp(meta: &std::fs::Metadata) -> (u64, u128) {
    let modified = meta.modified().ok().and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok()).map(|since| since.as_nanos()).unwrap_or(0);
    (meta.len(), modified)
}

impl Tree {
    /// Whether the path is one this tree leaves out: hidden, or in a directory it skips.
    fn skipped(&self, path: &Path) -> bool {
        let Ok(rest) = path.strip_prefix(&self.root) else { return true };
        let parts: Vec<_> = rest.components().map(|part| part.as_os_str().to_string_lossy().into_owned()).collect();
        parts.iter().enumerate().any(|(i, part)| part.starts_with('.') || (i + 1 < parts.len() && self.skip.contains(part)))
    }

    /// Everything under `dir` looked at again: what changed, appeared or went.
    fn rescan(&mut self, dir: &Path, changed: &mut Vec<PathBuf>) {
        let mut found = HashMap::new();
        self.walk(dir, &mut found);
        for (path, now) in &found {
            if self.stamps.get(path) != Some(now) {
                changed.push(path.clone());
            }
        }
        let gone: Vec<PathBuf> = self.stamps.keys().filter(|path| path.starts_with(dir) && !found.contains_key(*path)).cloned().collect();
        for path in gone {
            self.stamps.remove(&path);
            changed.push(path);
        }
        self.stamps.extend(found);
    }

    fn walk(&self, dir: &Path, found: &mut HashMap<PathBuf, (u64, u128)>) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                if !self.skip.contains(&name) {
                    self.walk(&path, found);
                }
            } else if let Ok(meta) = std::fs::metadata(&path) {
                found.insert(path, stamp(&meta));
            }
        }
    }

    /// One path the system named, looked at again.
    fn check(&mut self, path: &Path, changed: &mut Vec<PathBuf>) {
        if self.skipped(path) {
            return;
        }
        match std::fs::metadata(path) {
            Ok(meta) if meta.is_dir() => {
                if !path.file_name().is_some_and(|name| self.skip.contains(&name.to_string_lossy().into_owned())) {
                    self.rescan(path, changed);
                }
            }
            Ok(meta) => {
                let now = stamp(&meta);
                if self.stamps.insert(path.to_path_buf(), now) != Some(now) {
                    changed.push(path.to_path_buf());
                }
            }
            // Gone: the file, or a directory and everything that was in it.
            Err(_) => {
                let gone: Vec<PathBuf> = self.stamps.keys().filter(|known| known.starts_with(path)).cloned().collect();
                for known in gone {
                    self.stamps.remove(&known);
                    changed.push(known);
                }
            }
        }
    }
}

fn report(changed: Vec<PathBuf>) {
    if !changed.is_empty() {
        push(Event::Changed(changed.into_iter().map(|path| path.to_string_lossy().into_owned()).collect()));
    }
}

/// Starts watching `dir` (its real path: FSEvents names real paths).
pub fn watch(dir: &str, skip: Vec<String>) -> Result<(), String> {
    let root = std::fs::canonicalize(dir).map_err(|error| error.to_string())?;
    if !root.is_dir() {
        return Err("not a directory".to_string());
    }
    let mut tree = Tree { root: root.clone(), skip, stamps: HashMap::new() };
    let mut ignored = Vec::new();
    tree.rescan(&root, &mut ignored);
    let tree = Arc::new(Mutex::new(tree));
    if std::env::var("ROCX_WATCH").as_deref() != Ok("poll") {
        #[cfg(target_os = "macos")]
        if fsevents::start(&root, tree.clone()).is_ok() {
            return Ok(());
        }
    }
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(std::time::Duration::from_millis(250));
            let mut changed = Vec::new();
            let mut tree = tree.lock().unwrap();
            let root = tree.root.clone();
            tree.rescan(&root, &mut changed);
            drop(tree);
            report(changed);
        }
    });
    Ok(())
}

#[cfg(target_os = "macos")]
mod fsevents {
    //! FSEvents through `dlopen` and `dlsym`: CoreServices and CoreFoundation loaded at run time.
    //! The stream calls back on a dispatch queue of its own, with each path that changed.

    use super::{Tree, report};
    use std::ffi::{CString, c_char, c_void};
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};

    type Callback = extern "C" fn(*const c_void, *mut c_void, usize, *mut c_void, *const u32, *const u64);

    const UTF8: u32 = 0x0800_0100;
    const SINCE_NOW: u64 = u64::MAX;
    const NO_DEFER: u32 = 0x02;
    const FILE_EVENTS: u32 = 0x10;

    fn symbol(library: *mut c_void, name: &str) -> Result<*mut c_void, String> {
        let name = CString::new(name).unwrap();
        let found = unsafe { libc::dlsym(library, name.as_ptr()) };
        if found.is_null() { Err(format!("FSEvents: no {}", name.to_string_lossy())) } else { Ok(found) }
    }

    fn open(path: &str) -> Result<*mut c_void, String> {
        let path = CString::new(path).unwrap();
        let library = unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_NOW) };
        if library.is_null() { Err(format!("FSEvents: can't load {}", path.to_string_lossy())) } else { Ok(library) }
    }

    extern "C" fn changed(_stream: *const c_void, info: *mut c_void, count: usize, paths: *mut c_void, _flags: *const u32, _ids: *const u64) {
        let tree = unsafe { &*(info as *const Mutex<Tree>) };
        let paths = paths as *const *const c_char;
        let mut found = Vec::new();
        let mut tree = tree.lock().unwrap();
        for i in 0..count {
            let path = unsafe { std::ffi::CStr::from_ptr(*paths.add(i)) }.to_string_lossy().into_owned();
            tree.check(Path::new(&path), &mut found);
        }
        drop(tree);
        report(found);
    }

    #[repr(C)]
    struct Context {
        version: isize,
        info: *mut c_void,
        retain: *const c_void,
        release: *const c_void,
        describe: *const c_void,
    }

    pub fn start(root: &PathBuf, tree: Arc<Mutex<Tree>>) -> Result<(), String> {
        let core_foundation = open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")?;
        let core_services = open("/System/Library/Frameworks/CoreServices.framework/CoreServices")?;
        unsafe {
            let string_create: extern "C" fn(*const c_void, *const c_char, u32) -> *const c_void = std::mem::transmute(symbol(core_foundation, "CFStringCreateWithCString")?);
            let array_create: extern "C" fn(*const c_void, *const *const c_void, isize, *const c_void) -> *const c_void = std::mem::transmute(symbol(core_foundation, "CFArrayCreate")?);
            let array_callbacks = symbol(core_foundation, "kCFTypeArrayCallBacks")?;
            let stream_create: extern "C" fn(*const c_void, Callback, *const Context, *const c_void, u64, f64, u32) -> *mut c_void = std::mem::transmute(symbol(core_services, "FSEventStreamCreate")?);
            let set_queue: extern "C" fn(*mut c_void, *mut c_void) = std::mem::transmute(symbol(core_services, "FSEventStreamSetDispatchQueue")?);
            let stream_start: extern "C" fn(*mut c_void) -> bool = std::mem::transmute(symbol(core_services, "FSEventStreamStart")?);
            let queue_create: extern "C" fn(*const c_char, *const c_void) -> *mut c_void = std::mem::transmute(symbol(libc::RTLD_DEFAULT, "dispatch_queue_create")?);

            let path = CString::new(root.to_string_lossy().into_owned()).unwrap();
            let cf_path = string_create(std::ptr::null(), path.as_ptr(), UTF8);
            let paths = array_create(std::ptr::null(), &cf_path, 1, array_callbacks);
            // The tree lives as long as the program: the stream is never stopped.
            let info = Arc::into_raw(tree) as *mut c_void;
            let context = Context { version: 0, info, retain: std::ptr::null(), release: std::ptr::null(), describe: std::ptr::null() };
            let stream = stream_create(std::ptr::null(), changed, &context, paths, SINCE_NOW, 0.05, NO_DEFER | FILE_EVENTS);
            if stream.is_null() {
                return Err("FSEvents: no stream".to_string());
            }
            let label = CString::new("rocx.watch").unwrap();
            set_queue(stream, queue_create(label.as_ptr(), std::ptr::null()));
            if !stream_start(stream) {
                return Err("FSEvents: the stream didn't start".to_string());
            }
        }
        Ok(())
    }
}
