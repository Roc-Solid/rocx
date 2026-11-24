//! The CLI platform's host (`cli/platform`, which rocx is built on): Roc's memory, the program's
//! arguments, and the effects in `platform/Host.roc`. Threads of its own watch files (`watch`), wait
//! for children and read signals; each puts what it saw on one queue (`events`), which `Host.next!`
//! waits on. Roc runs on the main thread alone, and only it touches Roc's memory.
//!
//! The glue (`just glue`) names the result types after the first hosted function that returns
//! each, so adding one can rename them: the aliases below are the one place that follows.

#[path = "roc_platform_abi.rs"]
#[allow(unsafe_op_in_unsafe_fn)]
mod abi;
mod events;
mod http;
mod watch;

use abi::{RocHost, RocList, RocStr};
use std::collections::HashMap;
use std::ffi::{CStr, c_char, c_int, c_void};
use std::io::{Read, Write};
use std::mem::ManuallyDrop;
use std::process::{Command, Stdio};
use std::ptr::NonNull;
use std::sync::{Mutex, OnceLock};
use std::time::{Instant, UNIX_EPOCH};

/// `Try({}, Str)`.
type UnitResult = abi::HostCopyResult;
type UnitPayload = abi::HostCopyResultPayload;
type UnitTag = abi::HostCopyResultTag;
/// `Try(Str, Str)`.
type TextResult = abi::HostReadResult;
type TextPayload = abi::HostReadResultPayload;
type TextTag = abi::HostReadResultTag;
/// `{ code : I32, out : Str, err : Str }`.
type Ran = abi::AnonStruct4789a1b2f954e45c;
/// `{ kind : U8, paths : List(Str), child : U64, code : I32 }`.
type Next = abi::AnonStruct40c3f27e6ea250c6;

// ---- Roc's memory ----

fn host() -> RocHost {
    abi::make_roc_host(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> NonNull<c_void> {
    abi::DefaultAllocators::roc_alloc(std::ptr::null_mut(), length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dealloc(ptr: *mut c_void, alignment: usize) {
    abi::DefaultAllocators::roc_dealloc(std::ptr::null_mut(), ptr, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_realloc(ptr: *mut c_void, length: usize, alignment: usize) -> NonNull<c_void> {
    abi::DefaultAllocators::roc_realloc(std::ptr::null_mut(), ptr, length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    eprintln!("[dbg] {}", text(bytes, len));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    eprintln!("expect failed: {}", text(bytes, len));
}

/// A crash ends the program; its children end with it.
#[unsafe(no_mangle)]
pub extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    eprintln!("Roc crashed: {}", text(bytes, len));
    stop_children();
    std::process::exit(1);
}

fn text(bytes: *const u8, len: usize) -> String {
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(bytes, len) }).into_owned()
}

/// A Roc string's text, the string released (hosted arguments are the host's to release).
fn taken(value: RocStr) -> String {
    let owned = value.as_str().to_owned();
    unsafe { value.decref(&host()) };
    owned
}

fn taken_list(value: RocList<RocStr>) -> Vec<String> {
    let owned = value.as_slice().iter().map(|item| item.as_str().to_owned()).collect();
    unsafe { abi::decref_list_of_str(value, &host()) };
    owned
}

fn roc_str(value: &str) -> RocStr {
    RocStr::from_str(value, &host())
}

fn roc_list(values: &[String]) -> RocList<RocStr> {
    let items: Vec<RocStr> = values.iter().map(|value| roc_str(value)).collect();
    unsafe { RocList::from_slice(&items, &host()) }
}

// ---- Starting and ending ----

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: c_int, argv: *const *const c_char) -> c_int {
    events::catch_signals();
    let args: Vec<String> = (1..argc as isize).map(|i| unsafe { CStr::from_ptr(*argv.offset(i)) }.to_string_lossy().into_owned()).collect();
    let code = unsafe { abi::roc_main(roc_list(&args)) };
    let _ = std::io::stdout().flush();
    stop_children();
    code
}

// ---- Children ----

/// Children still running: their ids and process ids. A child's thread waits for it, takes it off,
/// and puts its end on the queue.
fn children() -> &'static Mutex<HashMap<u64, u32>> {
    static CHILDREN: OnceLock<Mutex<HashMap<u64, u32>>> = OnceLock::new();
    CHILDREN.get_or_init(|| Mutex::new(HashMap::new()))
}

/// SIGTERM to every child still running: none outlives the program.
fn stop_children() {
    for pid in children().lock().unwrap().values() {
        unsafe { libc::kill(*pid as i32, libc::SIGTERM) };
    }
}

/// SIGTERM to every child still running, then a wait (up to `limit`) until each has ended: its
/// thread takes it off the list when it has.
fn stop_children_and_wait(limit: std::time::Duration) {
    stop_children();
    let until = Instant::now() + limit;
    while !children().lock().unwrap().is_empty() && Instant::now() < until {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

fn exit_code(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

fn command(program: &str, args: &[String], cwd: &str, vars: &[String]) -> Command {
    let mut command = Command::new(program);
    command.args(args);
    if !cwd.is_empty() {
        command.current_dir(cwd);
    }
    for var in vars {
        if let Some((name, value)) = var.split_once('=') {
            command.env(name, value);
        }
    }
    command
}

// ---- Hosted ----

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_write(to: u8, data: RocStr) {
    let data = taken(data);
    if to == 1 {
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(data.as_bytes());
        let _ = out.flush();
    } else {
        let _ = std::io::stderr().lock().write_all(data.as_bytes());
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_cwd() -> RocStr {
    roc_str(&std::env::current_dir().map(|dir| dir.to_string_lossy().into_owned()).unwrap_or_default())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_env_var(name: RocStr) -> RocStr {
    roc_str(&std::env::var(taken(name)).unwrap_or_default())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_exe_path() -> RocStr {
    roc_str(&std::env::current_exe().map(|path| path.to_string_lossy().into_owned()).unwrap_or_default())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_now_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_now_ns() -> u64 {
    std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_nanos() as u64).unwrap_or(0)
}

/// This program replaced by another; children stopped first. Only returns (why) when it couldn't.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_exec(program: RocStr, args: RocList<RocStr>, cwd: RocStr, vars: RocList<RocStr>) -> RocStr {
    use std::os::unix::process::CommandExt;
    let (program, args, cwd, vars) = (taken(program), taken_list(args), taken(cwd), taken_list(vars));
    stop_children_and_wait(std::time::Duration::from_secs(10));
    let _ = std::io::stdout().flush();
    let error = command(&program, &args, &cwd, &vars).exec();
    roc_str(&error.to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_sleep(ms: u64) {
    std::thread::sleep(std::time::Duration::from_millis(ms));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_stdin() -> RocStr {
    let mut input = Vec::new();
    let _ = std::io::stdin().lock().read_to_end(&mut input);
    roc_str(&String::from_utf8_lossy(&input))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_pid() -> u32 {
    std::process::id()
}

/// Whether the process is running: signal 0 checks it is there; one this user may not signal
/// (EPERM) is there too.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_alive(pid: u32) -> bool {
    let sent = unsafe { libc::kill(pid as i32, 0) };
    sent == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_delete(path: RocStr) -> UnitResult {
    let path = taken(path);
    let path = std::path::Path::new(&path);
    unit_result(
        match std::fs::symlink_metadata(path) {
            Err(_) => Ok(()),
            Ok(meta) if meta.is_dir() => std::fs::remove_dir_all(path),
            Ok(_) => std::fs::remove_file(path),
        }
        .map_err(|error| error.to_string()),
    )
}

/// Makes the file only if nothing is there (`O_EXCL`): true when made, false when something was.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_create_new(path: RocStr, data: RocStr) -> abi::HostCreateNewResult {
    let (path, data) = (taken(path), taken(data));
    let made = std::fs::OpenOptions::new().write(true).create_new(true).open(&path).and_then(|mut file| file.write_all(data.as_bytes()));
    let (payload, tag) = match made {
        Ok(()) => (abi::HostCreateNewResultPayload { ok: ManuallyDrop::new(true) }, abi::HostCreateNewResultTag::Ok),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (abi::HostCreateNewResultPayload { ok: ManuallyDrop::new(false) }, abi::HostCreateNewResultTag::Ok),
        Err(error) => (abi::HostCreateNewResultPayload { err: ManuallyDrop::new(roc_str(&error.to_string())) }, abi::HostCreateNewResultTag::Err),
    };
    abi::HostCreateNewResult { payload, tag }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_copy(from: RocStr, to: RocStr) -> UnitResult {
    let (from, to) = (taken(from), taken(to));
    unit_result(copy(std::path::Path::new(&from), std::path::Path::new(&to)).map_err(|error| error.to_string()))
}

/// A file, or a directory and everything in it (a symbolic link as the link).
fn copy(from: &std::path::Path, to: &std::path::Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(from)?;
    if meta.file_type().is_symlink() {
        let _ = std::fs::remove_file(to);
        return std::os::unix::fs::symlink(std::fs::read_link(from)?, to);
    }
    if meta.is_dir() {
        std::fs::create_dir_all(to)?;
        for entry in std::fs::read_dir(from)? {
            let entry = entry?;
            copy(&entry.path(), &to.join(entry.file_name()))?;
        }
        return Ok(());
    }
    if let Some(dir) = to.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::copy(from, to).map(|_| ())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_exists(path: RocStr) -> bool {
    std::path::Path::new(&taken(path)).exists()
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_is_dir(path: RocStr) -> bool {
    std::path::Path::new(&taken(path)).is_dir()
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_modified(path: RocStr) -> u64 {
    std::fs::metadata(taken(path))
        .and_then(|meta| meta.modified())
        .map(|at| at.duration_since(UNIX_EPOCH).map(|since| since.as_nanos() as u64).unwrap_or(0))
        .unwrap_or(0)
}

fn text_result(result: Result<String, String>) -> TextResult {
    match result {
        Ok(value) => TextResult { payload: TextPayload { ok: ManuallyDrop::new(roc_str(&value)) }, tag: TextTag::Ok },
        Err(why) => TextResult { payload: TextPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: TextTag::Err },
    }
}

fn unit_result(result: Result<(), String>) -> UnitResult {
    match result {
        Ok(()) => UnitResult { payload: UnitPayload { ok: [] }, tag: UnitTag::Ok },
        Err(why) => UnitResult { payload: UnitPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: UnitTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_read(path: RocStr) -> TextResult {
    text_result(std::fs::read_to_string(taken(path)).map_err(|error| error.to_string()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_real_path(path: RocStr) -> TextResult {
    text_result(std::fs::canonicalize(taken(path)).map(|real| real.to_string_lossy().into_owned()).map_err(|error| error.to_string()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_write_file(path: RocStr, data: RocStr) -> UnitResult {
    let (path, data) = (taken(path), taken(data));
    let path = std::path::Path::new(&path);
    unit_result((|| {
        if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(path, data)
    })()
    .map_err(|error| error.to_string()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_write_bytes(path: RocStr, data: abi::RocListWith<u8, false>) -> UnitResult {
    let path = taken(path);
    let bytes = data.as_slice().to_vec();
    unsafe { data.decref(&host()) };
    let path = std::path::Path::new(&path);
    unit_result((|| {
        if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(path, bytes)
    })()
    .map_err(|error| error.to_string()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_http_get(url: RocStr, headers: RocList<RocStr>) -> abi::HostHttpGetResult {
    let (url, headers) = (taken(url), taken_list(headers));
    match http::get(&url, &headers) {
        Ok(answer) => abi::HostHttpGetResult {
            payload: abi::HostHttpGetResultPayload {
                ok: ManuallyDrop::new(abi::AnonStructD1699bdaa9628d69 {
                    body: unsafe { abi::RocListWith::from_slice(&answer.body, &host()) },
                    content_type: roc_str(&answer.content_type),
                    status: answer.status,
                }),
            },
            tag: abi::HostHttpGetResultTag::Ok,
        },
        Err(why) => abi::HostHttpGetResult { payload: abi::HostHttpGetResultPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: abi::HostHttpGetResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_free_port() -> abi::HostFreePortResult {
    match std::net::TcpListener::bind(("127.0.0.1", 0)).and_then(|listener| listener.local_addr()) {
        Ok(address) => abi::HostFreePortResult { payload: abi::HostFreePortResultPayload { ok: ManuallyDrop::new(address.port()) }, tag: abi::HostFreePortResultTag::Ok },
        Err(error) => abi::HostFreePortResult { payload: abi::HostFreePortResultPayload { err: ManuallyDrop::new(roc_str(&error.to_string())) }, tag: abi::HostFreePortResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_rename(from: RocStr, to: RocStr) -> UnitResult {
    let (from, to) = (taken(from), taken(to));
    unit_result(std::fs::rename(from, to).map_err(|error| error.to_string()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_make_dirs(path: RocStr) -> UnitResult {
    unit_result(std::fs::create_dir_all(taken(path)).map_err(|error| error.to_string()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_list(path: RocStr) -> abi::HostListResult {
    let listed = std::fs::read_dir(taken(path)).and_then(|entries| {
        let mut names = entries.map(|entry| entry.map(|entry| entry.file_name().to_string_lossy().into_owned())).collect::<Result<Vec<_>, _>>()?;
        names.sort();
        Ok(names)
    });
    match listed {
        Ok(names) => abi::HostListResult { payload: abi::HostListResultPayload { ok: ManuallyDrop::new(roc_list(&names)) }, tag: abi::HostListResultTag::Ok },
        Err(error) => abi::HostListResult { payload: abi::HostListResultPayload { err: ManuallyDrop::new(roc_str(&error.to_string())) }, tag: abi::HostListResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_run(program: RocStr, args: RocList<RocStr>, cwd: RocStr, vars: RocList<RocStr>, input: RocStr, mode: u8) -> abi::HostRunResult {
    let (program, args, cwd, vars, input) = (taken(program), taken_list(args), taken(cwd), taken_list(vars), taken(input));
    let ran = run(&program, &args, &cwd, &vars, input, mode);
    match ran {
        Ok((code, out, err)) => abi::HostRunResult {
            payload: abi::HostRunResultPayload { ok: ManuallyDrop::new(Ran { err: roc_str(&err), out: roc_str(&out), code }) },
            tag: abi::HostRunResultTag::Ok,
        },
        Err(error) => abi::HostRunResult { payload: abi::HostRunResultPayload { err: ManuallyDrop::new(roc_str(&error.to_string())) }, tag: abi::HostRunResultTag::Err },
    }
}

/// A command run to its end: its exit code, and its stdout and stderr (mode 0), both in one pipe
/// (1: `out`), or neither kept (2: this program's own). Its input is `input`, written by a thread of
/// its own while its output is read, so neither side waits on the other.
fn run(program: &str, args: &[String], cwd: &str, vars: &[String], input: String, mode: u8) -> std::io::Result<(i32, String, String)> {
    let mut command = command(program, args, cwd, vars);
    command.stdin(if input.is_empty() { Stdio::null() } else { Stdio::piped() });
    if mode == 2 {
        let mut child = command.spawn()?;
        feed(&mut child, input);
        return Ok((exit_code(child.wait()?), String::new(), String::new()));
    }
    if mode == 1 {
        // One pipe for stdout and stderr: what it wrote, in the order it wrote it.
        let (mut reader, writer) = std::io::pipe()?;
        command.stdout(writer.try_clone()?).stderr(writer);
        let mut child = command.spawn()?;
        // The pipe's write ends the command kept: reading ends when the child's do.
        drop(command);
        feed(&mut child, input);
        let mut output = Vec::new();
        reader.read_to_end(&mut output)?;
        return Ok((exit_code(child.wait()?), String::from_utf8_lossy(&output).into_owned(), String::new()));
    }
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn()?;
    feed(&mut child, input);
    let output = child.wait_with_output()?;
    Ok((exit_code(output.status), String::from_utf8_lossy(&output.stdout).into_owned(), String::from_utf8_lossy(&output.stderr).into_owned()))
}

/// The child's input, written by a thread, then closed.
fn feed(child: &mut std::process::Child, input: String) {
    if let Some(mut stdin) = child.stdin.take() {
        std::thread::spawn(move || {
            let _ = stdin.write_all(input.as_bytes());
        });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_spawn(program: RocStr, args: RocList<RocStr>, cwd: RocStr, vars: RocList<RocStr>, log: RocStr) -> abi::HostSpawnResult {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let (program, args, cwd, vars, log) = (taken(program), taken_list(args), taken(cwd), taken_list(vars), taken(log));
    let mut command = command(&program, &args, &cwd, &vars);
    if !log.is_empty() {
        // Its stdout and stderr in one file, in the order it wrote them.
        let opened = std::fs::File::create(&log).and_then(|file| Ok((file.try_clone()?, file)));
        match opened {
            Ok((out, err)) => {
                command.stdout(out).stderr(err);
            }
            Err(error) => {
                return abi::HostSpawnResult { payload: abi::HostSpawnResultPayload { err: ManuallyDrop::new(roc_str(&format!("{log}: {error}"))) }, tag: abi::HostSpawnResultTag::Err };
            }
        }
    }
    match command.spawn() {
        Ok(mut child) => {
            let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            children().lock().unwrap().insert(id, child.id());
            std::thread::spawn(move || {
                let code = child.wait().map(exit_code).unwrap_or(-1);
                children().lock().unwrap().remove(&id);
                events::push(events::Event::Exited { child: id, code });
            });
            abi::HostSpawnResult { payload: abi::HostSpawnResultPayload { ok: ManuallyDrop::new(id) }, tag: abi::HostSpawnResultTag::Ok }
        }
        Err(error) => abi::HostSpawnResult { payload: abi::HostSpawnResultPayload { err: ManuallyDrop::new(roc_str(&error.to_string())) }, tag: abi::HostSpawnResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kill(id: u64, signal: i32) {
    if let Some(pid) = children().lock().unwrap().get(&id) {
        unsafe { libc::kill(*pid as i32, signal) };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_watch(dir: RocStr, skip: RocList<RocStr>) -> UnitResult {
    let (dir, skip) = (taken(dir), taken_list(skip));
    unit_result(watch::watch(&dir, skip))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_next(timeout_ms: u64) -> Next {
    let empty = || RocList::<RocStr>::empty();
    match events::next(timeout_ms) {
        None => Next { child: 0, paths: empty(), code: 0, kind: 0 },
        Some(events::Event::Changed(paths)) => Next { child: 0, paths: roc_list(&paths), code: 0, kind: 1 },
        Some(events::Event::Exited { child, code }) => Next { child, paths: empty(), code, kind: 2 },
        Some(events::Event::Signal(signal)) => Next { child: 0, paths: empty(), code: signal, kind: 3 },
    }
}
