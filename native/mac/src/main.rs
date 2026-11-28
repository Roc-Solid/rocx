//! Runs an app on the native host, on the Mac, as a phone would (D-063's spike): the same engine,
//! the same ops, and a recording renderer in place of the phone's views. It prints the screen
//! after each step, so a test (or a person) can see what a phone would show.
//!
//! ```sh
//! rocx-native-mac --origin http://127.0.0.1:8095 show wait:1500 show tap:Tap show type:hello tap:Send wait:1500 show
//! ```
//!
//! Steps: `show` (the screen, as an outline, each view's frame in it), `ops` (print each batch of
//! ops as it is applied, from here on), `wait:<ms>` (let answers and timers come), `tap:<text>` (a
//! tap on the button, link or other tappable view that says it), `type:<text>` (typing into the
//! first field), `css` (the CSS the phone ignores), `width:<dp>` (the screen's width, 412 at
//! first; a rotation), `time` (how long the last layout took).

use rocx_native_core::{self as core, Level, Platform};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

struct Mac {
    wake: Mutex<Sender<()>>,
}

static SHOW_OPS: AtomicBool = AtomicBool::new(false);
static WARNINGS: Mutex<Vec<String>> = Mutex::new(Vec::new());

impl Platform for Mac {
    fn wake(&self) {
        let _ = self.wake.lock().map(|wake| wake.send(()));
    }
    fn apply(&self, ops: &[u8]) {
        if SHOW_OPS.load(Ordering::Relaxed) {
            for line in core::native::describe(ops) {
                println!("  op {line}");
            }
        }
    }
    fn call(&self, name: &str, arg: &str, _origin: &str) -> bool {
        println!("  call {name} {arg}");
        true
    }
    fn log(&self, level: Level, text: &str) {
        if level == Level::Warn {
            WARNINGS.lock().unwrap().push(text.to_string());
        }
        eprintln!("[{level:?}] {text}");
    }
}

fn settle(woken: &Receiver<()>, ms: u64) {
    let until = Instant::now() + Duration::from_millis(ms);
    loop {
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        if woken.recv_timeout(left).is_ok() {
            core::pump();
        }
    }
}

fn find(kind: &str, text: Option<&str>) -> Option<u64> {
    let mut views: Vec<(u64, core::native::View)> = core::native::shown_views().into_iter().collect();
    views.sort_by_key(|(id, _)| *id);
    views.into_iter().find(|(_, view)| view.kind == kind && text.is_none_or(|text| view.props.get("text").map(String::as_str) == Some(text))).map(|(id, _)| id)
}

/// The text a view shows, its children's too.
fn said(views: &std::collections::HashMap<u64, core::native::View>, id: u64) -> String {
    let Some(view) = views.get(&id) else { return String::new() };
    let mut out = view.props.get("text").cloned().unwrap_or_default();
    for child in &view.children {
        let more = said(views, *child);
        if !more.is_empty() {
            if !out.is_empty() {
                out.push(' ');
            }
            out.push_str(&more);
        }
    }
    out
}

/// The tappable view (a button, a link, one with a click handler) that says `text`.
fn tappable(text: &str) -> Option<u64> {
    let views = core::native::shown_views();
    let mut ids: Vec<&u64> = views.keys().collect();
    ids.sort();
    ids.into_iter().copied().find(|id| views[id].props.get("click").is_some_and(|click| click == "true") && said(&views, *id).trim() == text)
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut origin = "http://127.0.0.1:8080".to_string();
    if let Some(at) = args.iter().position(|arg| arg == "--origin") {
        origin = args.get(at + 1).cloned().unwrap_or(origin);
        args.drain(at..(at + 2).min(args.len()));
    }
    let (sender, woken) = channel();
    let started = Instant::now();
    let path = match args.iter().position(|arg| arg == "--path") {
        Some(at) => {
            let path = args.get(at + 1).cloned().unwrap_or_else(|| "/".into());
            args.drain(at..(at + 2).min(args.len()));
            path
        }
        None => "/".to_string(),
    };
    core::start(Box::new(Mac { wake: Mutex::new(sender) }), &origin, &path);
    println!("mounted in {:.1} ms", started.elapsed().as_secs_f64() * 1000.0);
    for step in args {
        let (name, value) = step.split_once(':').unwrap_or((step.as_str(), ""));
        match name {
            "show" => print!("{}", core::native::outline()),
            "ops" => SHOW_OPS.store(true, Ordering::Relaxed),
            "wait" => settle(&woken, value.parse().unwrap_or(1000)),
            "tap" => match tappable(value) {
                Some(id) => {
                    println!("tap {value:?} (#{id})");
                    core::event(id, "click", "");
                }
                None => println!("no button says {value:?}"),
            },
            "type" => match find("input", None) {
                Some(id) => {
                    println!("type {value:?} (#{id})");
                    core::event(id, "input", value);
                }
                None => println!("no field"),
            },
            "width" => {
                let width: f32 = value.parse().unwrap_or(412.0);
                core::viewport(width, 915.0);
            }
            "boxes" => print!("{}", core::native::boxes()),
            "time" => println!("laid out in {:.2} ms", core::native::last_layout_ms()),
            "css" => {
                for warning in WARNINGS.lock().unwrap().iter().filter(|warning| warning.contains("CSS")) {
                    println!("{warning}");
                }
            }
            other => println!("unknown step {other}"),
        }
        settle(&woken, 0);
    }
    println!("live allocations: {}", core::roc::live_allocations());
    let (kept, made) = core::roc::memory_notes();
    println!("notes kept: {kept} (of {made} allocations made)");
}
