//! Images on a phone (D-139): which of an `<img>`'s sources it shows (`srcset` and `sizes` against
//! the screen's density and width, as a browser picks), its file loaded off the main thread with
//! the app's cookies (the HTTP client's `fetch_bytes`, D-138's jar) into the app's cache directory,
//! and its size in pixels read from the file's header (PNG, JPEG with its EXIF orientation, GIF,
//! WebP), which is the `<img>`'s natural size for layout. The phone's view decodes the file
//! itself (Android's `BitmapFactory`, at the size it is drawn), so pixels never cross JNI.
//!
//! A file is kept on disk while its answer's `cache-control` lets it be (`max-age`, `immutable`),
//! so the next run shows it without asking; in a run, an image asked for once is kept by its URL.
//! A picked file (`file://`, D-139's file inputs) is its own file. A failure shows nothing, as a
//! browser's broken image does (without its icon).

use std::cell::RefCell;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

/// Where an image is.
#[derive(Clone, Debug, PartialEq)]
pub enum Image {
    Loading,
    /// On disk at `path`, `width` by `height` pixels (turned upright by its EXIF orientation).
    Ready { path: String, width: u32, height: u32 },
    Failed(String),
}

thread_local! {
    static IMAGES: RefCell<HashMap<String, Image>> = RefCell::new(HashMap::new());
    /// The elements waiting for an image, by its URL.
    static WAITING: RefCell<HashMap<String, Vec<crate::dom::NodeId>>> = RefCell::new(HashMap::new());
    /// Videos' sizes in pixels, by their source, as their players said (`loadedmetadata`).
    static VIDEOS: RefCell<HashMap<String, (u32, u32)>> = RefCell::new(HashMap::new());
}

/// A video's size in pixels, once a player has said it.
pub fn video_size(src: &str) -> Option<(u32, u32)> {
    VIDEOS.with(|videos| videos.borrow().get(src).copied())
}

/// A player's `loadedmetadata` (`<width>x<height> <duration ms>`): the video's size, its element's
/// natural size from now on.
pub fn video_said(src: &str, value: &str) {
    let size = value.split_whitespace().next().and_then(|size| size.split_once('x')).and_then(|(w, h)| Some((w.parse().ok()?, h.parse().ok()?)));
    if let Some(size) = size.filter(|(w, h): &(u32, u32)| *w > 0 && *h > 0) {
        VIDEOS.with(|videos| videos.borrow_mut().insert(src.to_string(), size));
    }
}

/// What a load on another thread found, for the main thread (`crate::Message::Media`).
#[derive(Debug)]
pub struct Loaded {
    pub url: String,
    pub image: Image,
}

/// On the main thread: where the image at `url` (absolute, or `file://`) is, for element `node`;
/// one not asked for yet starts loading now. The elements that asked for it are marked changed once
/// it is in (`loaded`), so the screen shows it (D-137 projects again only what changed).
pub fn image(url: &str, node: crate::dom::NodeId) -> Image {
    if let Some(known) = IMAGES.with(|images| images.borrow().get(url).cloned()) {
        if known == Image::Loading {
            WAITING.with(|waiting| {
                let mut waiting = waiting.borrow_mut();
                let nodes = waiting.entry(url.to_string()).or_default();
                if !nodes.contains(&node) {
                    nodes.push(node);
                }
            });
        }
        return known;
    }
    WAITING.with(|waiting| waiting.borrow_mut().insert(url.to_string(), vec![node]));
    IMAGES.with(|images| images.borrow_mut().insert(url.to_string(), Image::Loading));
    let made = crate::generation();
    let url = url.to_string();
    let dir = cache_dir();
    std::thread::spawn(move || {
        let image = load(&url, &dir);
        crate::post(crate::Message::Media(made, Loaded { url, image }));
    });
    Image::Loading
}

/// On the main thread: a load's result, kept.
pub fn loaded(loaded: Loaded) {
    if let Image::Failed(why) = &loaded.image {
        crate::log(crate::Level::Warn, &format!("rocx native: the image {} isn't shown: {why}", shown(&loaded.url)));
    }
    let nodes = WAITING.with(|waiting| waiting.borrow_mut().remove(&loaded.url)).unwrap_or_default();
    IMAGES.with(|images| images.borrow_mut().insert(loaded.url, loaded.image));
    crate::engine::with(|engine| {
        for node in nodes {
            if node < engine.dom.nodes.len() {
                engine.dom.touch(node);
            }
        }
    });
}

/// A URL for the log: without its query (a signed URL's signature).
fn shown(url: &str) -> &str {
    url.split(['?', '#']).next().unwrap_or(url)
}

/// The images known, forgotten (a dev client's new build starts afresh).
pub fn forget() {
    IMAGES.with(|images| images.borrow_mut().clear());
    WAITING.with(|waiting| waiting.borrow_mut().clear());
    VIDEOS.with(|videos| videos.borrow_mut().clear());
}

fn cache_dir() -> PathBuf {
    let dir = crate::cache_dir().map(PathBuf::from).unwrap_or_else(std::env::temp_dir).join("rocx-media");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// A name for a URL's file in the cache.
fn key(url: &str) -> String {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    url.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_secs()).unwrap_or(0)
}

/// An image's file and size: a picked file as it is, a URL's from the cache while it is fresh, else
/// fetched (with the app's cookies) and kept.
fn load(url: &str, dir: &Path) -> Image {
    if let Some(path) = url.strip_prefix("file://") {
        let path = percent_decoded(path);
        return match std::fs::read(&path) {
            Ok(bytes) => sized(path, &bytes),
            Err(why) => Image::Failed(why.to_string()),
        };
    }
    let file = dir.join(key(url));
    let until = dir.join(format!("{}.until", key(url)));
    let fresh = std::fs::read_to_string(&until).ok().and_then(|text| text.trim().parse::<u64>().ok()).is_some_and(|until| until > now_secs());
    if fresh && let Ok(bytes) = std::fs::read(&file) {
        return sized(file.to_string_lossy().into_owned(), &bytes);
    }
    let answer = match crate::http::fetch_bytes("GET", url, &[("accept".into(), "image/webp,image/png,image/jpeg,image/*;q=0.8".into())], &[], false) {
        Ok(answer) => answer,
        Err(why) => return Image::Failed(why),
    };
    if !(200..300).contains(&answer.status) {
        return Image::Failed(format!("the server answered {}", answer.status));
    }
    if let Err(why) = std::fs::write(&file, &answer.body) {
        return Image::Failed(format!("the cache: {why}"));
    }
    match kept_for(answer.header("cache-control")) {
        Some(seconds) => {
            let _ = std::fs::write(&until, (now_secs() + seconds).to_string());
        }
        None => {
            let _ = std::fs::remove_file(&until);
        }
    }
    sized(file.to_string_lossy().into_owned(), &answer.body)
}

fn sized(path: String, bytes: &[u8]) -> Image {
    match size_of(bytes) {
        Some((width, height)) => Image::Ready { path, width, height },
        None if looks_like_svg(bytes) => Image::Failed("SVG images (an <img> of an .svg) aren't on phones yet".into()),
        None => Image::Failed("not a PNG, JPEG, GIF or WebP image".into()),
    }
}

fn looks_like_svg(bytes: &[u8]) -> bool {
    let start = String::from_utf8_lossy(&bytes[..bytes.len().min(512)]).to_ascii_lowercase();
    start.contains("<svg")
}

/// How long an answer may be kept by its `cache-control` (seconds); none when it may not be kept
/// beyond this run (`no-store`, `no-cache`, no `max-age`).
pub fn kept_for(cache_control: Option<&str>) -> Option<u64> {
    let value = cache_control?.to_ascii_lowercase();
    let mut max_age = None;
    for part in value.split(',').map(str::trim) {
        if part == "no-store" || part == "no-cache" {
            return None;
        }
        if part == "immutable" {
            max_age = Some(max_age.unwrap_or(365 * 24 * 3600));
        }
        if let Some(age) = part.strip_prefix("max-age=").and_then(|age| age.trim_matches('"').parse::<u64>().ok()) {
            max_age = Some(age);
        }
    }
    max_age.filter(|age| *age > 0)
}

fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%'
            && let Some(byte) = text.get(at + 1..at + 3).and_then(|hex| u8::from_str_radix(hex, 16).ok())
        {
            out.push(byte);
            at += 3;
            continue;
        }
        out.push(bytes[at]);
        at += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ---- An image's size, from its header ----

/// An image's size in pixels, from its first bytes: PNG, GIF, WebP (lossy, lossless, extended) and
/// JPEG (turned by its EXIF orientation, as a browser shows it: 5 to 8 swap the sides).
pub fn size_of(bytes: &[u8]) -> Option<(u32, u32)> {
    let be16 = |at: usize| -> Option<u32> { Some(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?) as u32) };
    let le16 = |at: usize| -> Option<u32> { Some(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?) as u32) };
    let be32 = |at: usize| -> Option<u32> { Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?)) };
    let le24 = |at: usize| -> Option<u32> {
        let b = bytes.get(at..at + 3)?;
        Some(b[0] as u32 | (b[1] as u32) << 8 | (b[2] as u32) << 16)
    };
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some((be32(16)?, be32(20)?));
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some((le16(6)?, le16(8)?));
    }
    if bytes.len() >= 30 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return match &bytes[12..16] {
            b"VP8 " => Some((le16(26)? & 0x3fff, le16(28)? & 0x3fff)),
            b"VP8L" => {
                let b = bytes.get(21..25)?;
                let bits = u32::from_le_bytes(b.try_into().ok()?);
                Some(((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1))
            }
            b"VP8X" => Some((le24(24)? + 1, le24(27)? + 1)),
            _ => None,
        };
    }
    if bytes.starts_with(&[0xff, 0xd8]) {
        let mut at = 2;
        let mut orientation = 1;
        while at + 4 <= bytes.len() {
            if bytes[at] != 0xff {
                at += 1;
                continue;
            }
            let marker = bytes[at + 1];
            if marker == 0xff {
                at += 1;
                continue;
            }
            if matches!(marker, 0xd8 | 0x01 | 0xd0..=0xd7) {
                at += 2;
                continue;
            }
            let length = be16(at + 2)? as usize;
            if marker == 0xe1 && bytes.get(at + 4..at + 10) == Some(b"Exif\0\0") {
                orientation = exif_orientation(bytes.get(at + 10..at + 2 + length)?).unwrap_or(1);
            }
            // A frame's header (SOF0 to SOF15, but DHT, JPG and DAC): its height, then its width.
            if (0xc0..=0xcf).contains(&marker) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
                let (height, width) = (be16(at + 5)?, be16(at + 7)?);
                return Some(if (5..=8).contains(&orientation) { (height, width) } else { (width, height) });
            }
            at += 2 + length;
        }
    }
    None
}

/// The orientation (1 to 8) in an EXIF block (a TIFF header and its first IFD).
fn exif_orientation(tiff: &[u8]) -> Option<u16> {
    let little = match tiff.get(0..2)? {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let u16_at = |at: usize| -> Option<u16> {
        let b: [u8; 2] = tiff.get(at..at + 2)?.try_into().ok()?;
        Some(if little { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) })
    };
    let u32_at = |at: usize| -> Option<u32> {
        let b: [u8; 4] = tiff.get(at..at + 4)?.try_into().ok()?;
        Some(if little { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) })
    };
    let ifd = u32_at(4)? as usize;
    let count = u16_at(ifd)? as usize;
    for entry in 0..count {
        let at = ifd + 2 + entry * 12;
        if u16_at(at)? == 0x0112 {
            return u16_at(at + 8);
        }
    }
    None
}

// ---- srcset and sizes ----

/// A candidate of a `srcset`: its URL and descriptor (`2x`; `640w`; none, which is `1x`).
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub url: String,
    pub density: Option<f32>,
    pub width: Option<f32>,
}

/// A `srcset`'s candidates, as the HTML spec parses them (a URL up to whitespace, a trailing comma
/// ending it; then its descriptors up to a comma outside parentheses).
pub fn candidates(srcset: &str) -> Vec<Candidate> {
    let chars: Vec<char> = srcset.chars().collect();
    let mut at = 0;
    let mut out = Vec::new();
    loop {
        while at < chars.len() && (chars[at].is_whitespace() || chars[at] == ',') {
            at += 1;
        }
        if at >= chars.len() {
            return out;
        }
        let start = at;
        while at < chars.len() && !chars[at].is_whitespace() {
            at += 1;
        }
        let mut url: String = chars[start..at].iter().collect();
        let mut descriptors = String::new();
        if url.ends_with(',') {
            while url.ends_with(',') {
                url.pop();
            }
        } else {
            let mut depth = 0;
            while at < chars.len() {
                let c = chars[at];
                if c == '(' {
                    depth += 1;
                } else if c == ')' {
                    depth -= 1;
                } else if c == ',' && depth == 0 {
                    at += 1;
                    break;
                }
                descriptors.push(c);
                at += 1;
            }
        }
        let mut candidate = Candidate { url, density: None, width: None };
        for descriptor in descriptors.split_whitespace() {
            if let Some(x) = descriptor.strip_suffix('x').and_then(|x| x.parse::<f32>().ok()) {
                candidate.density = Some(x);
            } else if let Some(w) = descriptor.strip_suffix('w').and_then(|w| w.parse::<f32>().ok()) {
                candidate.width = Some(w);
            }
        }
        if !candidate.url.is_empty() {
            out.push(candidate);
        }
    }
}

/// The width `sizes` says the image is drawn at (CSS px) on a screen this wide: the first entry
/// whose media condition holds, else the last's length; `100vw` without one.
pub fn sizes_width(sizes: Option<&str>, screen: crate::css::Media) -> f32 {
    let ctx = crate::values::Ctx { em: 16.0, rem: 16.0, vw: screen.width, vh: screen.height };
    let fallback = screen.width;
    let Some(sizes) = sizes else { return fallback };
    for entry in crate::values::split(sizes, Some(',')) {
        let entry = entry.trim();
        if entry.eq_ignore_ascii_case("auto") {
            continue;
        }
        let (condition, length) = match entry.rfind(')') {
            Some(end) if entry.starts_with('(') || entry.to_ascii_lowercase().starts_with("not") => (Some(&entry[..=end]), entry[end + 1..].trim()),
            _ => (None, entry),
        };
        if condition.is_none_or(|condition| crate::css::media_applies(condition, screen))
            && let Some(px) = crate::values::px(length, ctx)
        {
            return px;
        }
    }
    fallback
}

/// The source a browser on this screen picks (`density`: device pixels a CSS px), and its density
/// (the image's pixels a CSS px, which its natural size is divided by): of `srcset`'s candidates
/// (with `src` as `1x` when there is no `1x` and no widths), the smallest density at least the
/// screen's, else the largest.
pub fn pick(src: Option<&str>, srcset: Option<&str>, sizes: Option<&str>, density: f32, screen: crate::css::Media) -> Option<(String, f32)> {
    let mut all = srcset.map(candidates).unwrap_or_default();
    let widths = all.iter().any(|candidate| candidate.width.is_some());
    let drawn = sizes_width(sizes, screen).max(1.0);
    let mut options: Vec<(String, f32)> = all.drain(..).map(|candidate| {
        let own = match candidate.width {
            Some(w) => w / drawn,
            None => candidate.density.unwrap_or(1.0),
        };
        (candidate.url, own)
    }).collect();
    if let Some(src) = src.filter(|src| !src.is_empty())
        && !widths
        && !options.iter().any(|(_, own)| (*own - 1.0).abs() < 0.001)
    {
        options.push((src.to_string(), 1.0));
    }
    if options.is_empty() {
        return None;
    }
    options.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
    let chosen = options.iter().find(|(_, own)| *own >= density - 0.01).or_else(|| options.last())?;
    Some(chosen.clone())
}

// ---- object-fit and object-position ----

/// `object-position` as two shares or offsets (`50% 50%`, `0px 100%`): `px` and `%` only, the
/// keywords made shares, the first the horizontal one.
pub fn position(value: Option<&str>, ctx: crate::values::Ctx) -> String {
    let words = crate::values::split(value.unwrap_or("50% 50%"), None);
    let axis = |word: Option<&String>| -> String {
        match word.map(|w| w.as_str()) {
            None | Some("center") => "50%".into(),
            Some("left" | "top") => "0%".into(),
            Some("right" | "bottom") => "100%".into(),
            Some(other) if other.ends_with('%') => other.to_string(),
            Some(other) => crate::values::px(other, ctx).map(|px| format!("{px}px")).unwrap_or_else(|| "50%".into()),
        }
    };
    let (first, second) = (words.first(), words.get(1));
    let swapped = first.is_some_and(|w| w == "top" || w == "bottom") || second.is_some_and(|w| w == "left" || w == "right");
    if swapped { format!("{} {}", axis(second), axis(first)) } else { format!("{} {}", axis(first), axis(second)) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::css::Media;

    const PHONE: Media = Media { width: 412.0, height: 915.0, dark: false };

    #[test]
    fn sizes_from_headers() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&640u32.to_be_bytes());
        png.extend_from_slice(&480u32.to_be_bytes());
        assert_eq!(size_of(&png), Some((640, 480)));
        assert_eq!(size_of(b"GIF89a\x10\x00\x20\x00"), Some((16, 32)));
        // A JPEG: SOI, an APP0, then a baseline frame's header (height 300, width 400).
        let jpeg = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x01, 0x2c, 0x01, 0x90, 0x03];
        assert_eq!(size_of(&jpeg), Some((400, 300)));
        // The same with an EXIF orientation of 6 (turned a quarter): upright, it is 300 wide.
        let mut turned = vec![0xff, 0xd8, 0xff, 0xe1];
        let tiff = [b'M', b'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0];
        let length = (2 + 6 + tiff.len()) as u16;
        turned.extend_from_slice(&length.to_be_bytes());
        turned.extend_from_slice(b"Exif\0\0");
        turned.extend_from_slice(&tiff);
        turned.extend_from_slice(&jpeg[8..]);
        assert_eq!(size_of(&turned), Some((300, 400)));
        // WebP, lossy: its frame's 14-bit sizes.
        let mut webp = b"RIFF\0\0\0\0WEBPVP8 \0\0\0\0\0\0\0\0\0\0".to_vec();
        webp.extend_from_slice(&800u16.to_le_bytes());
        webp.extend_from_slice(&600u16.to_le_bytes());
        assert_eq!(size_of(&webp), Some((800, 600)));
        // Extended: the canvas's sizes less one, 24 bits each.
        let mut extended = b"RIFF\0\0\0\0WEBPVP8X\0\0\0\0\0\0\0\0".to_vec();
        extended.extend_from_slice(&[0x1f, 0x03, 0x00, 0x57, 0x02, 0x00]);
        assert_eq!(size_of(&extended), Some((800, 600)));
        assert_eq!(size_of(b"<svg xmlns='http://www.w3.org/2000/svg'/>"), None);
    }

    #[test]
    fn srcset_is_parsed_as_the_spec_says() {
        assert_eq!(
            candidates("/a.webp 1x, /a@2x.webp 2x,/b.jpg"),
            vec![
                Candidate { url: "/a.webp".into(), density: Some(1.0), width: None },
                Candidate { url: "/a@2x.webp".into(), density: Some(2.0), width: None },
                Candidate { url: "/b.jpg".into(), density: None, width: None },
            ]
        );
        assert_eq!(candidates("/x,y.png 640w, /z.png 1280w")[0], Candidate { url: "/x,y.png".into(), density: None, width: Some(640.0) });
        assert_eq!(candidates("/one.png,/two.png 2x").len(), 1, "a comma inside a URL is the URL's");
        assert_eq!(candidates("/one.png, /two.png 2x").len(), 2);
    }

    #[test]
    fn a_source_is_picked_by_the_screens_density() {
        // Densities: the smallest at least the screen's.
        assert_eq!(pick(Some("/a.png"), Some("/a@2x.png 2x, /a@3x.png 3x"), None, 2.625, PHONE), Some(("/a@3x.png".into(), 3.0)));
        assert_eq!(pick(Some("/a.png"), Some("/a@2x.png 2x"), None, 1.0, PHONE), Some(("/a.png".into(), 1.0)));
        assert_eq!(pick(Some("/a.png"), Some("/a@2x.png 2x"), None, 4.0, PHONE), Some(("/a@2x.png".into(), 2.0)), "none dense enough: the densest");
        // Widths: against the width `sizes` says, on a 412-wide screen at 2.625 (1081.5 pixels).
        let srcset = "/p-320.webp 320w, /p-640.webp 640w, /p-1280.webp 1280w, /p-1920.webp 1920w";
        assert_eq!(pick(Some("/p.jpg"), Some(srcset), Some("(max-width: 1200px) 100vw, 1200px"), 2.625, PHONE).map(|(url, _)| url), Some("/p-1280.webp".into()));
        assert_eq!(pick(Some("/p.jpg"), Some(srcset), Some("200px"), 2.625, PHONE).map(|(url, _)| url), Some("/p-640.webp".into()));
        let (_, density) = pick(Some("/p.jpg"), Some(srcset), Some("200px"), 2.625, PHONE).unwrap();
        assert!((density - 3.2).abs() < 0.001, "640 pixels drawn in 200 px: {density}");
        assert_eq!(pick(Some("/p.jpg"), None, None, 2.0, PHONE), Some(("/p.jpg".into(), 1.0)));
        assert_eq!(pick(None, None, None, 2.0, PHONE), None);
        assert_eq!(sizes_width(Some("(min-width: 800px) 50vw, 90vw"), PHONE), 412.0 * 0.9);
    }

    #[test]
    fn caching_follows_cache_control() {
        assert_eq!(kept_for(Some("public, max-age=31536000, immutable")), Some(31536000));
        assert_eq!(kept_for(Some("private, max-age=60")), Some(60));
        assert_eq!(kept_for(Some("immutable")), Some(365 * 24 * 3600));
        assert_eq!(kept_for(Some("no-cache, max-age=60")), None);
        assert_eq!(kept_for(Some("max-age=0")), None);
        assert_eq!(kept_for(None), None);
    }

    #[test]
    fn object_position_is_two_values() {
        let ctx = crate::values::Ctx { em: 16.0, rem: 16.0, vw: 412.0, vh: 915.0 };
        assert_eq!(position(None, ctx), "50% 50%");
        assert_eq!(position(Some("top"), ctx), "50% 0%");
        assert_eq!(position(Some("right 10px"), ctx), "100% 10px");
        assert_eq!(position(Some("bottom left"), ctx), "0% 100%");
        assert_eq!(position(Some("25% 75%"), ctx), "25% 75%");
    }

    #[test]
    fn a_picked_file_is_its_own() {
        let dir = std::env::temp_dir().join(format!("rocx-media-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a photo.gif");
        std::fs::write(&path, b"GIF89a\x02\x00\x03\x00").unwrap();
        let url = format!("file://{}", path.to_string_lossy().replace(' ', "%20"));
        assert_eq!(load(&url, &dir), Image::Ready { path: path.to_string_lossy().into_owned(), width: 2, height: 3 });
        assert!(matches!(load("file:///nowhere/at/all.png", &dir), Image::Failed(_)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
