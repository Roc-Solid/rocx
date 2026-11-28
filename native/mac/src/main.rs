//! Runs an app on the native host, on the Mac, as a phone would (D-063's spike): the same engine,
//! the same ops, and a recording renderer in place of the phone's views. It prints the screen
//! after each step, so a test (or a person) can see what a phone would show.
//!
//! ```sh
//! rocx-native-mac --origin http://127.0.0.1:8095 show wait:1500 show tap:Tap show type:hello tap:Send wait:1500 show
//! ```
//!
//! Steps: `show` (the screen, as an outline), `ops` (print each batch of ops as it is applied, from
//! here on), `wait:<ms>` (let answers and timers come), `tap:<text>` (a tap on the button that
//! says it), `type:<text>` (typing into the first field), `enter` (the keyboard's Enter in it),
//! `css` (the CSS the phone ignores); navigation's (D-138): `link:<text>` (a tap on the link that
//! says it), `nav:<to>` (`Router.navigate!`), `back` (Android's back), `where` (the location and
//! the history), `cookies` (the jar), `at:<id>` (a tap on the view with that id) and `at:<id>=<text>`
//! (typing into it).
//!
//! Options: `--origin <url>`, `--path <start path>`, `--files <dir>` (where the cookie jar is kept,
//! as an app's files dir).

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

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut origin = "http://127.0.0.1:8080".to_string();
    if let Some(at) = args.iter().position(|arg| arg == "--origin") {
        origin = args.get(at + 1).cloned().unwrap_or(origin);
        args.drain(at..(at + 2).min(args.len()));
    }
    let mut path = "/".to_string();
    if let Some(at) = args.iter().position(|arg| arg == "--path") {
        path = args.get(at + 1).cloned().unwrap_or(path);
        args.drain(at..(at + 2).min(args.len()));
    }
    if let Some(at) = args.iter().position(|arg| arg == "--files") {
        if let Some(dir) = args.get(at + 1) {
            core::files(dir);
        }
        args.drain(at..(at + 2).min(args.len()));
    }
    let (sender, woken) = channel();
    let started = Instant::now();
    core::start(Box::new(Mac { wake: Mutex::new(sender) }), &origin, &path);
    println!("mounted in {:.1} ms", started.elapsed().as_secs_f64() * 1000.0);
    for step in args {
        let (name, value) = step.split_once(':').unwrap_or((step.as_str(), ""));
        match name {
            "show" => print!("{}", core::native::outline()),
            "ops" => SHOW_OPS.store(true, Ordering::Relaxed),
            "wait" => settle(&woken, value.parse().unwrap_or(1000)),
            "tap" => match find("button", Some(value)) {
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
            // A view by its id (`show` prints them): `at:<id>` taps it, `at:<id>=<text>` types into it.
            "at" => {
                let (id, text) = value.split_once('=').map(|(id, text)| (id, Some(text))).unwrap_or((value, None));
                let id: u64 = id.trim_start_matches('#').parse().unwrap_or(0);
                match text {
                    Some(text) => {
                        println!("type {text:?} (#{id})");
                        core::event(id, "input", text);
                    }
                    None => {
                        // A checkbox's view says whether it is checked now, as Android's does.
                        let checkbox = core::native::shown_views().get(&id).filter(|view| view.kind == "checkbox").map(|view| view.props.get("checked").map(String::as_str) != Some("true"));
                        match checkbox {
                            Some(now) => {
                                println!("check #{id}: {now}");
                                core::event(id, "click", &now.to_string());
                                core::event(id, "change", &now.to_string());
                            }
                            None => {
                                println!("tap #{id}");
                                core::event(id, "click", "");
                            }
                        }
                    }
                }
            }
            "enter" => match find("input", None) {
                Some(id) => {
                    println!("enter (#{id})");
                    core::event(id, "keydown", "Enter");
                }
                None => println!("no field"),
            },
            "link" => match core::nav::link_with_text(value) {
                Some(id) => {
                    println!("link {value:?} (#{id})");
                    core::event(id, "click", "");
                }
                None => println!("no link says {value:?}"),
            },
            "nav" => {
                println!("navigate {value:?}");
                core::nav::navigate(value, core::nav::Options { scroll: true, ..Default::default() });
                core::pump();
            }
            "back" => println!("back: {}", if core::back() { "went back" } else { "at the first entry: the app closes" }),
            "where" => println!("{}", core::nav::describe()),
            "cookies" => {
                for cookie in core::cookies::JAR.lock().unwrap().as_ref().map(|jar| jar.cookies().to_vec()).unwrap_or_default() {
                    println!("cookie {}={} (domain {}, path {}, expires {:?})", cookie.name, cookie.value.chars().take(12).collect::<String>(), cookie.domain, cookie.path, cookie.expires);
                }
            }
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
