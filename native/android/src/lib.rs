//! The native host's Android half (D-063's spike): the app's library (`libapp.so`, the app's Roc
//! linked with native/core and this) as the Kotlin side (native/android/app) sees it.
//!
//! - `Rocx.start(origin, path)` and `Rocx.send(id, name, value)` (Kotlin's `external fun`s) start
//!   the engine and pass it the views' events, on the main thread.
//! - Each flush's ops go to Kotlin's `Rocx.apply(ByteArray)`: one JNI call a batch, which the
//!   Kotlin applier walks (React Native's "mount items", for the same reason: a JNI call a view
//!   change is slow).
//! - Answers and timers come on other threads; they wake the main thread through a pipe its
//!   looper watches (`ALooper_addFd`), and the looper's callback runs `pump` there.
//! - `Browser.call!`'s native half (a plugin's: `audio.play`, `vibrate.pattern`) is Kotlin's
//!   `Rocx.call(name, arg, origin)`, on the main thread once a handler is done.
//! - `log` goes to logcat, tagged `rocx`.

use jni::JNIEnv;
use jni::JavaVM;
use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::sys::{JNI_VERSION_1_6, jint, jlong};
use rocx_native_core::{self as core, Level, Platform};
use std::ffi::{CString, c_int, c_void};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicI32, Ordering};

static VM: OnceLock<JavaVM> = OnceLock::new();
/// Kotlin's `dev.rocx.phone.Rocx`, held for the looper's callback (whose thread's class loader
/// is the system's, which doesn't know the app's classes).
static ROCX: OnceLock<GlobalRef> = OnceLock::new();
/// The pipe's ends: other threads write a byte to wake the main thread.
static WAKE_WRITE: AtomicI32 = AtomicI32::new(-1);
static WAKE_READ: AtomicI32 = AtomicI32::new(-1);

#[repr(C)]
struct ALooper {
    _private: [u8; 0],
}

type LooperCallback = extern "C" fn(fd: c_int, events: c_int, data: *mut c_void) -> c_int;

#[link(name = "android")]
#[link(name = "log")]
unsafe extern "C" {
    fn ALooper_forThread() -> *mut ALooper;
    fn ALooper_addFd(looper: *mut ALooper, fd: c_int, ident: c_int, events: c_int, callback: Option<LooperCallback>, data: *mut c_void) -> c_int;
    fn __android_log_write(priority: c_int, tag: *const std::ffi::c_char, text: *const std::ffi::c_char) -> c_int;
}

const ALOOPER_POLL_CALLBACK: c_int = -2;
const ALOOPER_EVENT_INPUT: c_int = 1;

struct Android;

impl Platform for Android {
    fn wake(&self) {
        let fd = WAKE_WRITE.load(Ordering::Relaxed);
        if fd >= 0 {
            let byte = 1u8;
            unsafe { libc::write(fd, &byte as *const u8 as *const c_void, 1) };
        }
    }

    fn apply(&self, ops: &[u8]) {
        let (Some(vm), Some(rocx)) = (VM.get(), ROCX.get()) else { return };
        let Ok(mut env) = vm.get_env() else { return };
        let sent = (|| -> jni::errors::Result<()> {
            let bytes = env.byte_array_from_slice(ops)?;
            let class = JClass::from(env.new_local_ref(rocx.as_obj())?);
            env.call_static_method(&class, "apply", "([B)V", &[JValue::Object(&JObject::from(bytes))])?;
            Ok(())
        })();
        if let Err(why) = sent {
            if env.exception_check().unwrap_or(false) {
                let _ = env.exception_describe();
                let _ = env.exception_clear();
            }
            self.log(Level::Error, &format!("rocx native: the applier failed: {why}"));
        }
    }

    fn call(&self, name: &str, arg: &str, origin: &str) -> bool {
        let (Some(vm), Some(rocx)) = (VM.get(), ROCX.get()) else { return false };
        let Ok(mut env) = vm.get_env() else { return false };
        let called = (|| -> jni::errors::Result<bool> {
            let class = JClass::from(env.new_local_ref(rocx.as_obj())?);
            let (name, arg, origin) = (env.new_string(name)?, env.new_string(arg)?, env.new_string(origin)?);
            let handled = env.call_static_method(&class, "call", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z", &[JValue::Object(&name), JValue::Object(&arg), JValue::Object(&origin)])?;
            handled.z()
        })();
        match called {
            Ok(handled) => handled,
            Err(why) => {
                if env.exception_check().unwrap_or(false) {
                    let _ = env.exception_describe();
                    let _ = env.exception_clear();
                }
                self.log(Level::Error, &format!("rocx native: the native handler {name} failed: {why}"));
                true
            }
        }
    }

    fn log(&self, level: Level, text: &str) {
        let priority = match level {
            Level::Debug => 3,
            Level::Info => 4,
            Level::Warn => 5,
            Level::Error => 6,
        };
        let tag = c"rocx";
        let line = CString::new(text.replace('\0', " ")).unwrap_or_default();
        unsafe { __android_log_write(priority, tag.as_ptr(), line.as_ptr()) };
        #[cfg(feature = "dev")]
        ship::line(level, text);
    }
}

/// The looper's callback, on the main thread: the pipe drained, then what other threads posted.
extern "C" fn woken(fd: c_int, _events: c_int, _data: *mut c_void) -> c_int {
    let mut buffer = [0u8; 64];
    while unsafe { libc::read(fd, buffer.as_mut_ptr() as *mut c_void, buffer.len()) } > 0 {}
    core::pump();
    1
}

#[unsafe(no_mangle)]
pub extern "system" fn JNI_OnLoad(vm: *mut jni::sys::JavaVM, _reserved: *mut c_void) -> jint {
    if let Ok(vm) = unsafe { JavaVM::from_raw(vm) } {
        let _ = VM.set(vm);
    }
    JNI_VERSION_1_6
}

fn text(env: &mut JNIEnv, value: &JString) -> String {
    env.get_string(value).map(String::from).unwrap_or_default()
}

/// What the main thread needs before the app runs: Kotlin's `Rocx` held, and the wake pipe on its
/// looper.
fn prepare(env: &mut JNIEnv, class: &JClass) {
    if ROCX.get().is_none()
        && let Ok(global) = env.new_global_ref(&class)
    {
        let _ = ROCX.set(global);
    }
    if WAKE_READ.load(Ordering::Relaxed) < 0 {
        let mut fds = [0 as c_int; 2];
        if unsafe { libc::pipe(fds.as_mut_ptr()) } == 0 {
            unsafe {
                libc::fcntl(fds[0], libc::F_SETFL, libc::fcntl(fds[0], libc::F_GETFL) | libc::O_NONBLOCK);
                libc::fcntl(fds[1], libc::F_SETFL, libc::fcntl(fds[1], libc::F_GETFL) | libc::O_NONBLOCK);
            }
            WAKE_READ.store(fds[0], Ordering::Relaxed);
            WAKE_WRITE.store(fds[1], Ordering::Relaxed);
            unsafe { ALooper_addFd(ALooper_forThread(), fds[0], ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, Some(woken), std::ptr::null_mut()) };
        }
    }
}

/// `Rocx.start(origin, path)`, on the main thread: the app linked into this library, started.
#[cfg(not(feature = "dev"))]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_rocx_phone_Rocx_start(mut env: JNIEnv, class: JClass, origin: JString, path: JString) {
    prepare(&mut env, &class);
    let (origin, path) = (text(&mut env, &origin), text(&mut env, &path));
    core::start(Box::new(Android), &origin, &path);
}

/// `Rocx.reload(library, origin, path)`, on the main thread (the dev client's): the app's Roc in a
/// library rocx dev built (`libapp-<build>.so`, in the app's files), loaded, and started in place
/// of the last build. "" once it runs, else why not (the library doesn't load, or isn't an app).
/// The last build's library stays loaded: its code may still be referred to.
#[cfg(feature = "dev")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_rocx_phone_Rocx_reload<'local>(mut env: JNIEnv<'local>, class: JClass, library: JString, origin: JString, path: JString) -> JString<'local> {
    prepare(&mut env, &class);
    let (library, origin, path) = (text(&mut env, &library), text(&mut env, &origin), text(&mut env, &path));
    ship::to(&origin);
    let said = match load(&library) {
        Ok((mount, run)) => {
            core::roc::set_entries(mount, run);
            core::restart(Box::new(Android), &origin, &path);
            String::new()
        }
        Err(why) => why,
    };
    env.new_string(said).unwrap_or_default()
}

/// A library's `roc_mount` and `roc_run`. Its hosted functions are this library's (it needs
/// libhost.so, whose symbols the loader finds already loaded).
#[cfg(feature = "dev")]
fn load(library: &str) -> Result<(usize, usize), String> {
    let path = CString::new(library).map_err(|_| "a library path with a NUL in it".to_string())?;
    let handle = unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL) };
    if handle.is_null() {
        let why = unsafe { std::ffi::CStr::from_ptr(libc::dlerror()) }.to_string_lossy().into_owned();
        return Err(format!("the app's library didn't load: {why}"));
    }
    let find = |name: &std::ffi::CStr| {
        let found = unsafe { libc::dlsym(handle, name.as_ptr()) };
        if found.is_null() { Err(format!("the app's library has no {}: is it an app on web/platform?", name.to_string_lossy())) } else { Ok(found as usize) }
    };
    Ok((find(c"roc_mount")?, find(c"roc_run")?))
}

/// `Rocx.log(level, text)`: a line of the Kotlin side's log (Android's priorities: 3 debug, 4
/// info, 5 warn, 6 error), to logcat and, as the engine's, to the dev server.
#[cfg(feature = "dev")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_rocx_phone_Rocx_log(mut env: JNIEnv, _class: JClass, priority: jint, said: JString) {
    let said = text(&mut env, &said);
    let level = match priority {
        3 => Level::Debug,
        5 => Level::Warn,
        6 => Level::Error,
        _ => Level::Info,
    };
    Android.log(level, &said);
}

/// The dev client's log, sent to the dev server it loads builds from (`POST /__rocx/dev/log`,
/// which the server logs `from=phone`, so it shows where rocx dev runs, on Wi-Fi as on USB): the
/// lines kept as they come (the last 2,000 at most), a batch every 200 ms, kept for the next try
/// while the server can't be reached (a restart between builds), dropped if it refuses them (a
/// server from before the endpoint).
#[cfg(feature = "dev")]
mod ship {
    use rocx_native_core::Level;
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use std::sync::{Mutex, Once};
    use std::time::Duration;

    static LINES: Mutex<Vec<(Level, String)>> = Mutex::new(Vec::new());
    static TO: Mutex<String> = Mutex::new(String::new());
    static STARTED: Once = Once::new();
    const KEPT: usize = 2000;

    pub fn line(level: Level, text: &str) {
        let mut lines = LINES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if lines.len() >= KEPT {
            lines.remove(0);
        }
        lines.push((level, text.to_string()));
    }

    /// Where the lines go (the server of the build just loaded), and the sending started.
    pub fn to(origin: &str) {
        *TO.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = origin.trim_end_matches('/').to_string();
        STARTED.call_once(|| {
            std::thread::spawn(send);
        });
    }

    fn send() {
        loop {
            std::thread::sleep(Duration::from_millis(200));
            let origin = TO.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
            let batch = std::mem::take(&mut *LINES.lock().unwrap_or_else(|poisoned| poisoned.into_inner()));
            if batch.is_empty() {
                continue;
            }
            match post(&origin, &json(&batch)) {
                Sent::Yes | Sent::Refused => {}
                Sent::Unreachable => {
                    let mut lines = LINES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                    let newer = std::mem::replace(&mut *lines, batch);
                    lines.extend(newer);
                    let over = lines.len().saturating_sub(KEPT);
                    lines.drain(..over);
                }
            }
        }
    }

    enum Sent {
        Yes,
        Refused,
        Unreachable,
    }

    fn post(origin: &str, body: &str) -> Sent {
        let Some(rest) = origin.strip_prefix("http://") else { return Sent::Refused };
        let authority = rest.split('/').next().unwrap_or(rest);
        let address = if authority.contains(':') { authority.to_string() } else { format!("{authority}:80") };
        let Ok(mut stream) = TcpStream::connect(&address) else { return Sent::Unreachable };
        stream.set_read_timeout(Some(Duration::from_secs(5))).ok();
        let request = format!("POST /__rocx/dev/log HTTP/1.1\r\nhost: {authority}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
        if stream.write_all(request.as_bytes()).is_err() {
            return Sent::Unreachable;
        }
        let mut answer = [0u8; 12];
        match stream.read_exact(&mut answer) {
            Ok(()) if answer.starts_with(b"HTTP/1.1 2") || answer.starts_with(b"HTTP/1.0 2") => Sent::Yes,
            Ok(()) => Sent::Refused,
            Err(_) => Sent::Unreachable,
        }
    }

    fn json(lines: &[(Level, String)]) -> String {
        let mut out = String::from("[");
        for (at, (level, text)) in lines.iter().enumerate() {
            if at > 0 {
                out.push(',');
            }
            let level = match level {
                Level::Debug => "D",
                Level::Info => "I",
                Level::Warn => "W",
                Level::Error => "E",
            };
            out.push_str(&format!("{{\"level\":\"{level}\",\"text\":\""));
            for char in text.chars() {
                match char {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\r' => out.push_str("\\r"),
                    '\t' => out.push_str("\\t"),
                    char if (char as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", char as u32)),
                    char => out.push(char),
                }
            }
            out.push_str("\"}");
        }
        out.push(']');
        out
    }
}

/// `Rocx.fingerprint()`: the platform this dev client runs apps for (core/build.rs), and the Roc
/// compiler, which a build's must match.
#[cfg(feature = "dev")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_rocx_phone_Rocx_fingerprint<'local>(env: JNIEnv<'local>, _class: JClass) -> JString<'local> {
    env.new_string(format!("{} {}", core::FINGERPRINT, core::ROC_VERSION)).unwrap_or_default()
}

/// `Rocx.send(id, name, value)`: an event on a view, on the main thread.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_rocx_phone_Rocx_send(mut env: JNIEnv, _class: JClass, id: jlong, name: JString, value: JString) {
    let (name, value) = (text(&mut env, &name), text(&mut env, &value));
    core::event(id as u64, &name, &value);
}
