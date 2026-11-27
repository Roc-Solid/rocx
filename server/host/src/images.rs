//! Smaller copies of an app's photos, for `enhanced:src` (D-125). A page's `<img enhanced:src={x}>`
//! asks, as the server renders it, whether copies of `x` are ready (`lookup`): if they are, the page
//! gets their `srcset` and the photo's size; if not, the page keeps its original `src`, and the
//! photo goes to a queue that makes its copies in the background, so the next page that shows it
//! gets them. A page never waits on a photo, but in a static build (`wait`), which has no next
//! request.
//!
//! A source is a path of this site: a file under the server's `--static` directory, or else what
//! the app answers a signed-out GET of it (asked of the server itself, no cookies), so only what
//! anyone may see gets copies anyone may fetch. Nothing else is fetched.
//!
//! A photo's copies are WebP, at the widths of `LADDER` under its own width, and its own width up to
//! the ladder's top. They are named by the SHA-256 of the photo's bytes (`RECIPE` before them, so a
//! change to how copies are made names them anew), kept in the images directory (`data/images`,
//! `--images-dir`) as `<hash>-<width>.webp` and a `<hash>.txt` written last, which holds the
//! photo's width and height and the copies' widths: a photo is ready when its `.txt` is there, so
//! the directory is its own index, read again as the server starts. Which photo a source is, is a
//! `<hash of its path>.src` beside them (the photo's hash, and the file's length and modification
//! time, or that a route answered it), so a server started again knows its pages' photos at once:
//! a file still as it was is its photo, a route's photo is shown while it is asked again. A `.txt`'s modification time
//! is when a page last used the photo (set again at most once a day), and the sweep (as the server
//! starts, then daily) removes the photos no page used for `MAX_AGE`, then the least recently used
//! while the directory is over its size (`--images-max-mb`, 1 GiB). A photo removed is made again
//! the next time a page shows it: the page gets the original meanwhile, never a missing copy.
//!
//! The queue has a few workers of its own (threads, not tokio's or Roc's), one photo each at a time:
//! a photo asked for by a hundred pages is made once. A photo that can't be made (not a JPEG, PNG
//! or WebP, too many pixels, a route that doesn't answer 200) is remembered until its source
//! changes, so it isn't tried again on every page.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Condvar, LazyLock, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

/// The widths copies are made at, under a photo's own (and its own, up to the last).
pub const LADDER: [u32; 6] = [160, 320, 640, 960, 1280, 1920];

/// Written before a photo's bytes in its hash: another recipe (widths, quality, encoder) names
/// every copy anew, and the sweep removes the old ones.
const RECIPE: &[u8] = b"rocx-images-1\0";

/// WebP's quality, 0 to 100.
const QUALITY: f32 = 80.0;

/// The most pixels a photo may have (a 48-megapixel phone camera's is 8064 by 6048).
pub const MAX_PIXELS: u64 = 64 * 1024 * 1024;

/// The most bytes a source may have.
pub const MAX_SOURCE_BYTES: usize = 64 * 1024 * 1024;

/// A photo no page used for this long is removed.
pub const MAX_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);

/// How often a use is written down (a `.txt`'s modification time), and the sweep runs.
const DAY: Duration = Duration::from_secs(24 * 60 * 60);

/// How long a route's answer is taken as current before a page's use asks for it again.
const ROUTE_FRESH: Duration = Duration::from_secs(5 * 60);

/// The URL path copies are served under.
pub const URL_PREFIX: &str = "/rocx/images/";

/// 1 GiB, unless the server was started with another `--images-max-mb`.
const DEFAULT_MAX_BYTES: u64 = 1024 * 1024 * 1024;

/// What a ready photo's copies are, for a page.
#[derive(Clone, Debug, PartialEq)]
pub struct Ready {
    pub hash: String,
    pub width: u32,
    pub height: u32,
    pub widths: Vec<u32>,
}

impl Ready {
    /// `srcset`'s value: each copy's URL and width.
    pub fn srcset(&self) -> String {
        self.widths.iter().map(|w| format!("{URL_PREFIX}{}-{w}.webp {w}w", self.hash)).collect::<Vec<_>>().join(", ")
    }
}

/// Where a source's bytes are, and what says they changed.
#[derive(Clone, Debug, PartialEq)]
enum Seen {
    /// A file: its length and modification time.
    File(u64, SystemTime),
    /// A route's answer: when it was read.
    Route(Instant),
}

struct Source {
    seen: Seen,
    /// The photo's hash, once its bytes were read (and its copies made, or found).
    hash: Option<String>,
    /// Why its copies couldn't be made, for the bytes `seen` describes.
    failed: Option<String>,
}

struct Photo {
    ready: Ready,
    /// The bytes its copies and `.txt` take.
    bytes: u64,
    /// When a page last used it, as its `.txt` says.
    used: SystemTime,
}

struct State {
    dir: PathBuf,
    max_bytes: u64,
    static_dirs: Vec<PathBuf>,
    /// Pages wait for their photos' copies (`--images-wait`).
    wait: bool,
    photos: HashMap<String, Photo>,
    total: u64,
    sources: HashMap<String, Source>,
    /// Sources queued or being made.
    queued: HashSet<String>,
    jobs: Option<Sender<String>>,
}

/// Reads a route's answer: the server's own answer to a signed-out GET of a path (http.rs sets it).
pub type RouteReader = Arc<dyn Fn(&str) -> Result<Vec<u8>, String> + Send + Sync>;

static STATE: LazyLock<Mutex<Option<State>>> = LazyLock::new(|| Mutex::new(None));
static ROUTES: OnceLock<RouteReader> = OnceLock::new();
/// Signalled each time a source leaves the queue, for `wait`.
static SETTLED: Condvar = Condvar::new();

/// The images directory's settings, from the server's flags.
#[derive(Clone, Debug)]
pub struct Config {
    pub dir: PathBuf,
    pub max_bytes: u64,
    /// The `--static` directories, in order: a source is the first one's file that is there.
    pub static_dirs: Vec<PathBuf>,
    pub wait: bool,
    pub workers: usize,
}

impl Config {
    pub fn new(dir: Option<PathBuf>, max_mb: Option<u64>, static_dirs: Vec<PathBuf>, wait: bool) -> Config {
        let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2);
        Config {
            dir: dir.unwrap_or_else(|| PathBuf::from("data/images")),
            max_bytes: max_mb.map(|mb| mb.saturating_mul(1024 * 1024)).unwrap_or(DEFAULT_MAX_BYTES),
            static_dirs,
            wait,
            workers: (cores / 4).clamp(1, 2),
        }
    }
}

/// Opens the images directory (made when first written to), reads what it holds, and starts the
/// workers and the daily sweep.
pub fn start(config: Config, routes: RouteReader) {
    let _ = ROUTES.set(routes);
    let (jobs, queue) = channel::<String>();
    let mut state = State {
        dir: config.dir.clone(),
        max_bytes: config.max_bytes,
        static_dirs: config.static_dirs.clone(),
        wait: config.wait,
        photos: HashMap::new(),
        total: 0,
        sources: HashMap::new(),
        queued: HashSet::new(),
        jobs: Some(jobs),
    };
    read_dir(&mut state);
    sweep(&mut state, SystemTime::now());
    *STATE.lock().unwrap() = Some(state);
    let queue = Arc::new(Mutex::new(queue));
    for n in 0..config.workers {
        let queue = Arc::clone(&queue);
        let _ = std::thread::Builder::new().name(format!("rocx-images-{n}")).spawn(move || work(queue));
    }
    let _ = std::thread::Builder::new().name("rocx-images-sweep".into()).spawn(|| {
        loop {
            std::thread::sleep(DAY);
            if let Some(state) = STATE.lock().unwrap().as_mut() {
                sweep(state, SystemTime::now());
            }
        }
    });
}

/// Whether a page waits for its photos (`--images-wait`, a static build's server): `wait`, not
/// `lookup`.
pub fn waits() -> bool {
    STATE.lock().unwrap().as_ref().is_some_and(|state| state.wait)
}

/// A page's `<img enhanced:src={src}>`: the photo's copies if they are ready, else nothing, and the
/// photo queued (if it can be: a path of this site, not an SVG, not made before, its source not
/// known to fail).
pub fn lookup(src: &str) -> Option<Ready> {
    let path = source_path(src)?;
    if vector(&path) {
        return None;
    }
    let mut guard = STATE.lock().unwrap();
    let state = guard.as_mut()?;
    let now = SystemTime::now();
    let seen = seen(state, &path);
    let current = match state.sources.get(&path) {
        Some(source) => match (&source.seen, &seen) {
            (Seen::File(..), Some(file)) => source.seen == *file,
            (Seen::Route(at), None) => at.elapsed() < ROUTE_FRESH,
            _ => false,
        },
        None => false,
    };
    let known = state.sources.get(&path).and_then(|s| if current && s.failed.is_some() { None } else { s.hash.clone() });
    let failed = current && state.sources.get(&path).is_some_and(|s| s.failed.is_some());
    // A file that changed is a photo not known yet (the old copies aren't its); a route's answer
    // past its time keeps its copies while it is read again.
    let ready = match (&seen, current) {
        (Some(_), false) => None,
        _ => known.and_then(|hash| state.photos.get_mut(&hash)).map(|photo| {
            if now.duration_since(photo.used).unwrap_or_default() >= DAY {
                photo.used = now;
                touch(&state.dir, &photo.ready.hash, now);
            }
            photo.ready.clone()
        }),
    };
    if !current && !failed && !state.queued.contains(&path) {
        if let Some(jobs) = &state.jobs {
            state.queued.insert(path.clone());
            let _ = jobs.send(path);
        }
    }
    ready
}

/// `lookup` for a static build, which has no next request: the photo's copies, made now if they
/// must be (waiting for a worker making them already). `None` if they can't be made.
pub fn wait(src: &str) -> Option<Ready> {
    if let Some(ready) = lookup(src) {
        return Some(ready);
    }
    let path = source_path(src)?;
    let mut guard = STATE.lock().unwrap();
    loop {
        let state = guard.as_ref()?;
        if !state.queued.contains(&path) {
            break;
        }
        guard = SETTLED.wait(guard).unwrap();
    }
    drop(guard);
    let mut guard = STATE.lock().unwrap();
    let state = guard.as_mut()?;
    let hash = state.sources.get(&path).filter(|s| s.failed.is_none()).and_then(|s| s.hash.clone())?;
    state.photos.get(&hash).map(|photo| photo.ready.clone())
}

/// The file a URL path names, if it is a copy this server has: `/rocx/images/<hash>-<width>.webp`.
pub fn file_for(url_path: &str) -> Option<PathBuf> {
    let name = url_path.strip_prefix(URL_PREFIX)?;
    let (stem, ext) = name.rsplit_once('.')?;
    let (hash, width) = stem.split_once('-')?;
    if ext != "webp" || hash.len() != 16 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let width: u32 = width.parse().ok()?;
    let guard = STATE.lock().unwrap();
    let state = guard.as_ref()?;
    let photo = state.photos.get(hash)?;
    photo.ready.widths.contains(&width).then(|| state.dir.join(format!("{hash}-{width}.webp")))
}

/// A source's path on this site: `/a/b.jpg` (a query or fragment dropped); nothing for another
/// site's URL (`https://…`, `//…`), a `data:` URL, or a path that climbs (`..`).
pub fn source_path(src: &str) -> Option<String> {
    let path = src.split(['?', '#']).next().unwrap_or("");
    if !path.starts_with('/') || path.starts_with("//") || path.contains('\\') {
        return None;
    }
    if path.split('/').any(|segment| segment == ".." || segment == ".") || path.starts_with(URL_PREFIX) {
        return None;
    }
    Some(path.to_string())
}

/// Whether a path names an SVG, by its extension: drawn at any size, it has no copies to make, and
/// isn't tried (or said in the log) as a photo that can't be read.
pub fn vector(path: &str) -> bool {
    path.rsplit_once('.').is_some_and(|(_, extension)| extension.eq_ignore_ascii_case("svg"))
}

/// The widths of a photo `width` wide.
pub fn widths(width: u32) -> Vec<u32> {
    let top = *LADDER.last().unwrap();
    let mut widths: Vec<u32> = LADDER.iter().copied().filter(|w| *w < width).collect();
    let own = width.min(top);
    if !widths.contains(&own) {
        widths.push(own);
    }
    widths
}

/// A copy's height: the photo's shape, at least a pixel.
pub fn height_at(width: u32, height: u32, at: u32) -> u32 {
    ((height as u64 * at as u64 + width as u64 / 2) / width as u64).max(1) as u32
}

/// What a source's bytes are, now: a file's length and modification time, or nothing (a route's).
fn seen(state: &State, path: &str) -> Option<Seen> {
    let file = static_file(&state.static_dirs, path)?;
    let meta = fs::metadata(file).ok()?;
    meta.is_file().then(|| Seen::File(meta.len(), meta.modified().unwrap_or(SystemTime::UNIX_EPOCH)))
}

/// What a source is now, for a failure that didn't say (a panic).
fn seen_now(path: &str) -> Seen {
    let guard = STATE.lock().unwrap();
    guard.as_ref().and_then(|state| seen(state, path)).unwrap_or(Seen::Route(Instant::now()))
}

/// A path's file in the first `--static` directory that has it.
fn static_file(static_dirs: &[PathBuf], path: &str) -> Option<PathBuf> {
    let relative = path.trim_start_matches('/');
    if relative.is_empty() || relative.ends_with('/') {
        return None;
    }
    static_dirs.iter().map(|dir| dir.join(relative)).find(|file| file.is_file())
}

/// A worker: takes sources off the queue, one at a time, until the server stops.
fn work(queue: Arc<Mutex<Receiver<String>>>) {
    loop {
        let path = match queue.lock().unwrap().recv() {
            Ok(path) => path,
            Err(_) => return,
        };
        let outcome = std::panic::catch_unwind(|| make_source(&path)).unwrap_or_else(|_| Err((seen_now(&path), "the image library panicked".into())));
        let mut guard = STATE.lock().unwrap();
        if let Some(state) = guard.as_mut() {
            state.queued.remove(&path);
            match outcome {
                Ok((seen, made)) => {
                    let hash = made.ready.hash.clone();
                    if let Some(made) = made.photo {
                        if !state.photos.contains_key(&hash) {
                            state.total += made.bytes;
                            state.photos.insert(hash.clone(), made);
                            over_size(state, Some(&hash));
                        }
                    }
                    if state.photos.contains_key(&hash) {
                        record(&state.dir, &path, &hash, &seen);
                    }
                    state.sources.insert(path, Source { seen, hash: Some(hash), failed: None });
                }
                Err((seen, why)) => {
                    eprintln!("rocx server: enhanced:src {path}: {why}; its page keeps the original");
                    let _ = fs::remove_file(state.dir.join(source_name(&path)));
                    state.sources.insert(path, Source { seen, hash: None, failed: Some(why) });
                }
            }
        }
        drop(guard);
        SETTLED.notify_all();
    }
}

struct Made {
    ready: Ready,
    /// The photo, if this made it (not when its copies were there already).
    photo: Option<Photo>,
}

/// Reads a source and makes its photo's copies, unless they are there.
fn make_source(path: &str) -> Result<(Seen, Made), (Seen, String)> {
    let (dir, static_dirs) = {
        let guard = STATE.lock().unwrap();
        let state = guard.as_ref().ok_or((Seen::Route(Instant::now()), "the server stopped".to_string()))?;
        (state.dir.clone(), state.static_dirs.clone())
    };
    let (seen, bytes) = match static_file(&static_dirs, path) {
        Some(file) => {
            let meta = fs::metadata(&file).map_err(|e| (Seen::Route(Instant::now()), e.to_string()))?;
            let seen = Seen::File(meta.len(), meta.modified().unwrap_or(SystemTime::UNIX_EPOCH));
            if meta.len() > MAX_SOURCE_BYTES as u64 {
                return Err((seen, format!("over {} MiB", MAX_SOURCE_BYTES / 1024 / 1024)));
            }
            let bytes = fs::read(&file).map_err(|e| (seen.clone(), e.to_string()))?;
            (seen, bytes)
        }
        None => {
            let seen = Seen::Route(Instant::now());
            let read = ROUTES.get().ok_or((seen.clone(), "no server to ask".to_string()))?;
            let bytes = read(path).map_err(|why| (seen.clone(), why))?;
            if bytes.len() > MAX_SOURCE_BYTES {
                return Err((seen, format!("over {} MiB", MAX_SOURCE_BYTES / 1024 / 1024)));
            }
            (seen, bytes)
        }
    };
    let hash = hash_of(&bytes);
    {
        let guard = STATE.lock().unwrap();
        if let Some(photo) = guard.as_ref().and_then(|state| state.photos.get(&hash)) {
            return Ok((seen, Made { ready: photo.ready.clone(), photo: None }));
        }
    }
    let copies = make(&bytes).map_err(|why| (seen.clone(), why))?;
    let photo = write(&dir, &hash, &copies).map_err(|why| (seen.clone(), why))?;
    Ok((seen, Made { ready: photo.ready.clone(), photo: Some(photo) }))
}

/// A photo's hash: the first 8 bytes of the SHA-256 of `RECIPE` and its bytes, in hex.
pub fn hash_of(bytes: &[u8]) -> String {
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    context.update(RECIPE);
    context.update(bytes);
    context.finish().as_ref()[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// A photo's copies, made: its width and height (upright), and each copy's width and WebP bytes.
#[derive(Debug)]
pub struct Copies {
    pub width: u32,
    pub height: u32,
    pub copies: Vec<(u32, Vec<u8>)>,
}

/// Decodes a JPEG, PNG or WebP, turns it upright (its EXIF orientation), and makes its copies.
pub fn make(bytes: &[u8]) -> Result<Copies, String> {
    use image::{ImageDecoder, ImageFormat, ImageReader};
    let mut reader = ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format().map_err(|e| e.to_string())?;
    match reader.format() {
        Some(ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::WebP) => {}
        Some(other) => return Err(format!("{other:?} isn't a JPEG, PNG or WebP")),
        None => return Err("not an image".into()),
    }
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(MAX_PIXELS * 8);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().map_err(|e| e.to_string())?;
    let (w, h) = decoder.dimensions();
    if w == 0 || h == 0 {
        return Err("an empty image".into());
    }
    if w as u64 * h as u64 > MAX_PIXELS {
        return Err(format!("{w} by {h} is over {} megapixels", MAX_PIXELS / 1024 / 1024));
    }
    let orientation = decoder.orientation().unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut image = image::DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
    image.apply_orientation(orientation);
    let (width, height) = (image.width(), image.height());
    let alpha = image.color().has_alpha();
    let pixels = if alpha { image::DynamicImage::ImageRgba8(image.to_rgba8()) } else { image::DynamicImage::ImageRgb8(image.to_rgb8()) };
    drop(image);
    let mut copies = Vec::new();
    for at in widths(width) {
        let at_height = height_at(width, height, at);
        let resized = resize(&pixels, at, at_height)?;
        let encoder = if alpha { webp::Encoder::from_rgba(&resized, at, at_height) } else { webp::Encoder::from_rgb(&resized, at, at_height) };
        let encoded = encoder.encode_simple(false, QUALITY).map_err(|e| format!("WebP: {e:?}"))?;
        copies.push((at, encoded.to_vec()));
    }
    Ok(Copies { width, height, copies })
}

/// The photo's pixels at a width and height (Lanczos 3), as packed RGB or RGBA bytes.
fn resize(pixels: &image::DynamicImage, width: u32, height: u32) -> Result<Vec<u8>, String> {
    use fast_image_resize::{FilterType, ResizeAlg, ResizeOptions, Resizer, images::Image};
    if pixels.width() == width && pixels.height() == height {
        return Ok(pixels.as_bytes().to_vec());
    }
    let kind = if pixels.color().has_alpha() { fast_image_resize::PixelType::U8x4 } else { fast_image_resize::PixelType::U8x3 };
    let mut into = Image::new(width, height, kind);
    let options = ResizeOptions::new().resize_alg(ResizeAlg::Convolution(FilterType::Lanczos3));
    Resizer::new().resize(pixels, &mut into, &options).map_err(|e| e.to_string())?;
    Ok(into.into_vec())
}

/// Writes a photo's copies into the directory, then its `.txt`: each to a file of its own first,
/// renamed into its place, so a crash leaves no photo half there.
fn write(dir: &Path, hash: &str, made: &Copies) -> Result<Photo, String> {
    let tmp = dir.join(".tmp");
    fs::create_dir_all(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
    let mut bytes = 0u64;
    let put = |name: &str, contents: &[u8]| -> Result<(), String> {
        let part = tmp.join(name);
        let mut file = fs::File::create(&part).map_err(|e| e.to_string())?;
        file.write_all(contents).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::rename(&part, dir.join(name)).map_err(|e| e.to_string())
    };
    for (at, webp) in &made.copies {
        put(&format!("{hash}-{at}.webp"), webp)?;
        bytes += webp.len() as u64;
    }
    let widths: Vec<u32> = made.copies.iter().map(|(at, _)| *at).collect();
    let txt = describe(made.width, made.height, &widths);
    put(&format!("{hash}.txt"), txt.as_bytes())?;
    bytes += txt.len() as u64;
    Ok(Photo { ready: Ready { hash: hash.to_string(), width: made.width, height: made.height, widths }, bytes, used: SystemTime::now() })
}

/// A `.txt`: `<width> <height> <copy width> …`.
fn describe(width: u32, height: u32, widths: &[u32]) -> String {
    let mut text = format!("{width} {height}");
    for w in widths {
        text.push_str(&format!(" {w}"));
    }
    text.push('\n');
    text
}

fn read_description(text: &str) -> Option<(u32, u32, Vec<u32>)> {
    let mut numbers = text.split_whitespace().map(|n| n.parse::<u32>());
    let width = numbers.next()?.ok()?;
    let height = numbers.next()?.ok()?;
    let widths: Vec<u32> = numbers.collect::<Result<_, _>>().ok()?;
    (width > 0 && height > 0 && !widths.is_empty()).then_some((width, height, widths))
}

/// Reads the directory: each photo whose `.txt` and copies are there. What a crash left (a copy
/// with no `.txt`, a file half written) is removed.
fn read_dir(state: &mut State) {
    let _ = fs::remove_dir_all(state.dir.join(".tmp"));
    let Ok(entries) = fs::read_dir(&state.dir) else { return };
    let mut files: HashMap<String, u64> = HashMap::new();
    let mut described: Vec<(String, SystemTime)> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        if let Some(hash) = name.strip_suffix(".txt") {
            described.push((hash.to_string(), meta.modified().unwrap_or(SystemTime::UNIX_EPOCH)));
        }
        files.insert(name, meta.len());
    }
    let mut kept: HashSet<String> = HashSet::new();
    for (hash, used) in described {
        let txt = format!("{hash}.txt");
        let Some((width, height, widths)) = fs::read_to_string(state.dir.join(&txt)).ok().as_deref().and_then(read_description) else { continue };
        let names: Vec<String> = widths.iter().map(|w| format!("{hash}-{w}.webp")).collect();
        if !names.iter().all(|n| files.contains_key(n)) {
            continue;
        }
        let bytes = files[&txt] + names.iter().map(|n| files[n]).sum::<u64>();
        kept.insert(txt);
        kept.extend(names);
        state.total += bytes;
        state.photos.insert(hash.clone(), Photo { ready: Ready { hash, width, height, widths }, bytes, used });
    }
    for name in files.keys() {
        if !kept.contains(name) && (name.ends_with(".webp") || name.ends_with(".txt")) {
            let _ = fs::remove_file(state.dir.join(name));
        }
    }
    // Which photo each source is: one whose photo is gone is removed.
    for name in files.keys().filter(|name| name.ends_with(".src")) {
        let file = state.dir.join(name);
        match fs::read_to_string(&file).ok().as_deref().and_then(read_source) {
            Some((path, hash, seen)) if state.photos.contains_key(&hash) && source_name(&path) == *name => {
                state.sources.insert(path, Source { seen, hash: Some(hash), failed: None });
            }
            _ => {
                let _ = fs::remove_file(file);
            }
        }
    }
}

/// The file that says which photo a source is: its path's hash, `.src`.
fn source_name(path: &str) -> String {
    let digest = ring::digest::digest(&ring::digest::SHA256, path.as_bytes());
    let hex: String = digest.as_ref()[..8].iter().map(|b| format!("{b:02x}")).collect();
    format!("{hex}.src")
}

/// Writes which photo a source is (`<photo hash>`, then `file <length> <modified, ns>` or `route`,
/// then its path), to a file of its own first, renamed into its place.
fn record(dir: &Path, path: &str, hash: &str, seen: &Seen) {
    let kind = match seen {
        Seen::File(length, modified) => format!("file {length} {}", modified.duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_nanos()),
        Seen::Route(_) => "route".to_string(),
    };
    let name = source_name(path);
    let tmp = dir.join(".tmp");
    let part = tmp.join(&name);
    if fs::create_dir_all(&tmp).is_ok() && fs::write(&part, format!("{hash}\n{kind}\n{path}\n")).is_ok() {
        let _ = fs::rename(&part, dir.join(name));
    }
}

/// A `.src`: its source's path, its photo's hash, and what the source was (a route's: due to be
/// asked again).
fn read_source(text: &str) -> Option<(String, String, Seen)> {
    let mut lines = text.lines();
    let hash = lines.next()?.to_string();
    let kind = lines.next()?;
    let path = lines.next()?.to_string();
    let seen = match kind.split_whitespace().collect::<Vec<_>>().as_slice() {
        ["file", length, nanos] => Seen::File(length.parse().ok()?, SystemTime::UNIX_EPOCH + Duration::from_nanos(nanos.parse().ok()?)),
        ["route"] => Seen::Route(Instant::now().checked_sub(ROUTE_FRESH).unwrap_or_else(Instant::now)),
        _ => return None,
    };
    (hash.len() == 16 && source_path(&path).as_deref() == Some(path.as_str())).then_some((path, hash, seen))
}

/// Writes down that a page used a photo: its `.txt`'s modification time.
fn touch(dir: &Path, hash: &str, now: SystemTime) {
    if let Ok(file) = fs::File::options().write(true).open(dir.join(format!("{hash}.txt"))) {
        let _ = file.set_modified(now);
    }
}

/// Removes the photos no page used for `MAX_AGE`, then the least recently used while over the size.
fn sweep(state: &mut State, now: SystemTime) {
    let old: Vec<String> = state.photos.iter().filter(|(_, p)| now.duration_since(p.used).unwrap_or_default() > MAX_AGE).map(|(h, _)| h.clone()).collect();
    for hash in old {
        remove(state, &hash);
    }
    over_size(state, None);
}

/// Removes the least recently used photos while the directory is over its size, never `keep`.
fn over_size(state: &mut State, keep: Option<&str>) {
    while state.total > state.max_bytes {
        let oldest = state.photos.iter().filter(|(h, _)| Some(h.as_str()) != keep).min_by_key(|(_, p)| p.used).map(|(h, _)| h.clone());
        match oldest {
            Some(hash) => remove(state, &hash),
            None => return,
        }
    }
}

/// Removes a photo: its `.txt` first, so a crash midway leaves copies `read_dir` removes.
fn remove(state: &mut State, hash: &str) {
    let Some(photo) = state.photos.remove(hash) else { return };
    state.total = state.total.saturating_sub(photo.bytes);
    let _ = fs::remove_file(state.dir.join(format!("{hash}.txt")));
    for w in &photo.ready.widths {
        let _ = fs::remove_file(state.dir.join(format!("{hash}-{w}.webp")));
    }
    for (path, source) in &state.sources {
        if source.hash.as_deref() == Some(hash) {
            let _ = fs::remove_file(state.dir.join(source_name(path)));
        }
    }
    state.sources.retain(|_, source| source.hash.as_deref() != Some(hash));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widths_under_a_photos_own() {
        assert_eq!(widths(2400), vec![160, 320, 640, 960, 1280, 1920]);
        assert_eq!(widths(1920), vec![160, 320, 640, 960, 1280, 1920]);
        assert_eq!(widths(1000), vec![160, 320, 640, 960, 1000]);
        assert_eq!(widths(640), vec![160, 320, 640]);
        assert_eq!(widths(100), vec![100]);
    }

    #[test]
    fn heights_keep_the_shape() {
        assert_eq!(height_at(2400, 1600, 640), 427);
        assert_eq!(height_at(1000, 1, 160), 1);
    }

    #[test]
    fn sources_are_paths_of_this_site() {
        assert_eq!(source_path("/images/a.jpg?v=2#x"), Some("/images/a.jpg".into()));
        assert_eq!(source_path("https://example.com/a.jpg"), None);
        assert_eq!(source_path("//example.com/a.jpg"), None);
        assert_eq!(source_path("data:image/png;base64,AAAA"), None);
        assert_eq!(source_path("/images/../secret"), None);
        assert_eq!(source_path("images/a.jpg"), None);
        assert_eq!(source_path("/rocx/images/0123456789abcdef-640.webp"), None);
    }

    #[test]
    fn svgs_have_no_copies() {
        assert!(vector("/images/mark.svg"));
        assert!(vector("/images/Mark.SVG"));
        assert!(!vector("/images/harbour.jpg"));
        assert!(!vector("/photos/svg"));
        assert_eq!(lookup("/images/mark.svg"), None);
    }

    #[test]
    fn descriptions_read_back() {
        let text = describe(2400, 1600, &[160, 320]);
        assert_eq!(read_description(&text), Some((2400, 1600, vec![160, 320])));
        assert_eq!(read_description("12 x"), None);
        assert_eq!(read_description("12 12"), None);
    }

    fn jpeg(width: u32, height: u32) -> Vec<u8> {
        let image = image::RgbImage::from_fn(width, height, |x, y| image::Rgb([(x % 256) as u8, (y % 256) as u8, 128]));
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image).write_to(&mut out, image::ImageFormat::Jpeg).unwrap();
        out.into_inner()
    }

    #[test]
    fn a_jpeg_makes_webp_copies() {
        let made = make(&jpeg(1000, 500)).unwrap();
        assert_eq!((made.width, made.height), (1000, 500));
        assert_eq!(made.copies.iter().map(|(w, _)| *w).collect::<Vec<_>>(), vec![160, 320, 640, 960, 1000]);
        for (w, bytes) in &made.copies {
            assert_eq!(&bytes[..4], b"RIFF");
            let copy = image::load_from_memory_with_format(bytes, image::ImageFormat::WebP).unwrap();
            assert_eq!((copy.width(), copy.height()), (*w, height_at(1000, 500, *w)));
        }
    }

    #[test]
    fn not_a_photo_is_refused() {
        assert!(make(b"<svg xmlns='http://www.w3.org/2000/svg'/>").is_err());
        // A GIF's signature is enough to know it: GIFs aren't read (an animation's frames).
        assert!(make(b"GIF89a\x01\x00\x01\x00\x00\x00\x00;").unwrap_err().contains("Gif"));
    }

    #[test]
    fn the_directory_is_its_own_index() {
        let dir = std::env::temp_dir().join(format!("rocx-images-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let bytes = jpeg(400, 200);
        let hash = hash_of(&bytes);
        let photo = write(&dir, &hash, &make(&bytes).unwrap()).unwrap();
        fs::write(dir.join("ffffffffffffffff-160.webp"), b"left by a crash").unwrap();
        let mut state = State {
            dir: dir.clone(),
            max_bytes: DEFAULT_MAX_BYTES,
            static_dirs: Vec::new(),
            wait: false,
            photos: HashMap::new(),
            total: 0,
            sources: HashMap::new(),
            queued: HashSet::new(),
            jobs: None,
        };
        let file_seen = Seen::File(1234, SystemTime::UNIX_EPOCH + Duration::from_nanos(1_700_000_000_123_456_789));
        record(&dir, "/images/a.jpg", &hash, &file_seen);
        record(&dir, "/photos/7", &hash, &Seen::Route(Instant::now()));
        record(&dir, "/gone.jpg", "eeeeeeeeeeeeeeee", &Seen::Route(Instant::now()));
        read_dir(&mut state);
        assert_eq!(state.photos.get(&hash).map(|p| p.ready.clone()), Some(photo.ready.clone()));
        // Which photo each source is, read back: a file's as it was, a route's due to be asked again.
        assert_eq!(state.sources["/images/a.jpg"].seen, file_seen);
        assert_eq!(state.sources["/images/a.jpg"].hash.as_deref(), Some(hash.as_str()));
        assert!(matches!(state.sources["/photos/7"].seen, Seen::Route(at) if at.elapsed() >= ROUTE_FRESH || at.elapsed() < Duration::from_secs(1)));
        assert!(!state.sources.contains_key("/gone.jpg"), "its photo isn't there");
        assert!(!dir.join(source_name("/gone.jpg")).exists());
        assert_eq!(state.total, photo.bytes);
        assert!(!dir.join("ffffffffffffffff-160.webp").exists());
        // Unused for longer than MAX_AGE: swept.
        sweep(&mut state, SystemTime::now() + MAX_AGE + DAY);
        assert!(state.photos.is_empty());
        assert_eq!(state.total, 0);
        assert!(!dir.join(format!("{hash}.txt")).exists());
        assert!(!dir.join(format!("{hash}-160.webp")).exists());
        assert!(!dir.join(source_name("/images/a.jpg")).exists(), "its sources' records go with it");
        assert!(state.sources.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn over_its_size_the_least_recently_used_go() {
        let dir = std::env::temp_dir().join(format!("rocx-images-size-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let mut state = State {
            dir: dir.clone(),
            max_bytes: u64::MAX,
            static_dirs: Vec::new(),
            wait: false,
            photos: HashMap::new(),
            total: 0,
            sources: HashMap::new(),
            queued: HashSet::new(),
            jobs: None,
        };
        let mut hashes = Vec::new();
        for (n, size) in [(0u64, 300u32), (1, 310), (2, 320)] {
            let bytes = jpeg(size, 100);
            let hash = hash_of(&bytes);
            let mut photo = write(&dir, &hash, &make(&bytes).unwrap()).unwrap();
            photo.used = SystemTime::UNIX_EPOCH + Duration::from_secs(1000 + n);
            state.total += photo.bytes;
            state.photos.insert(hash.clone(), photo);
            hashes.push(hash);
        }
        let newest_two: u64 = hashes[1..].iter().map(|h| state.photos[h].bytes).sum();
        state.max_bytes = newest_two;
        over_size(&mut state, None);
        assert!(!state.photos.contains_key(&hashes[0]));
        assert!(state.photos.contains_key(&hashes[1]) && state.photos.contains_key(&hashes[2]));
        // The one just made stays, even if it is the oldest.
        state.max_bytes = 1;
        over_size(&mut state, Some(&hashes[1]));
        assert_eq!(state.photos.keys().cloned().collect::<Vec<_>>(), vec![hashes[1].clone()]);
        let _ = fs::remove_dir_all(&dir);
    }
}
