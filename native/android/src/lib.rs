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

    fn log(&self, level: Level, text: &str) {
        let priority = match level {
            Level::Debug => 3,
            Level::Info => 4,
            Level::Warn => 5,
            Level::Error => 6,
        };
        let tag = c"rocx";
        let text = CString::new(text.replace('\0', " ")).unwrap_or_default();
        unsafe { __android_log_write(priority, tag.as_ptr(), text.as_ptr()) };
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

/// `Rocx.start(origin, path)`, on the main thread: the wake pipe on its looper, then the app.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_rocx_phone_Rocx_start(mut env: JNIEnv, class: JClass, origin: JString, path: JString) {
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
    let (origin, path) = (text(&mut env, &origin), text(&mut env, &path));
    core::start(Box::new(Android), &origin, &path);
}

/// `Rocx.send(id, name, value)`: an event on a view, on the main thread.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_rocx_phone_Rocx_send(mut env: JNIEnv, _class: JClass, id: jlong, name: JString, value: JString) {
    let (name, value) = (text(&mut env, &name), text(&mut env, &value));
    core::event(id as u64, &name, &value);
}
