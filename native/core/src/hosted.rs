//! web/platform's hosted functions (`Host.roc`, 63 of them), as the phone does them: each is the
//! symbol the app's Roc calls (`roc_<name>`), with the glue's C signature
//! (`roc_platform_abi.rs`), and does what web/runtime.js's `js_<name>` import does, through the
//! engine. One that ends the running computation (a read that waits, a failure) lets go of what
//! it holds first, then jumps (`roc::abort`).
//!
//! `live_publish!` fails, as the browser's does (it is the server's). `Browser.call!` goes to the
//! platform's native handler by its name (`crate::call_native`). `request!` and `status!` answer
//! what the browser's do: nothing. Navigation (`navigate!`, `is_routing!`, leaving) is nav.rs's
//! (D-138), live updates (`listen!`, channels) live.rs's (D-140).

use crate::abi::{RocErasedCallable as Callable, RocStr};
use crate::engine;
use crate::roc::{self, Abort, given, taken};

fn fail(why: String) -> ! {
    roc::abort(Abort::Failed(why, None))
}

/// A box given to the engine to keep: noted in the running call's frame (rocx-memory's `hand`), so
/// a call that ends early frees nothing the engine still holds.
fn handed(boxed: Callable) -> Callable {
    rocx_memory::hand(boxed as usize);
    boxed
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_keep(callable: Callable) -> u64 {
    engine::keep(handed(callable))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_new(value: Callable) -> u64 {
    engine::signal_new(handed(value))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_get(id: u64) -> Callable {
    match engine::signal_get(id) {
        Ok(value) => value,
        Err(why) => fail(why),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_set(id: u64, value: Callable) {
    if let Err(value) = engine::signal_set(id, handed(value)) {
        roc::release(value);
        fail("a signal is written in a handler, not while computing".into())
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_new(runner: Callable) -> u64 {
    engine::memo_new(handed(runner))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_done(value: Callable, same: bool) {
    engine::memo_done(handed(value), same)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_tracking() -> bool {
    engine::tracking()
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_last(fallback: Callable) -> Callable {
    engine::memo_last(fallback)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_latest(id: u64) -> Callable {
    match engine::signal_latest(id) {
        Ok(value) => value,
        Err(why) => fail(why),
    }
}

/// `Solid.update!` (D-094): the running handler's reads of signals give its own writes, from on to off.
#[unsafe(no_mangle)]
pub extern "C" fn roc_own_writes(on: bool) {
    engine::own_writes(on)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_optimistic_set(id: u64, value: Callable) {
    if let Err(value) = engine::optimistic_set(id, handed(value)) {
        roc::release(value);
        fail("an optimistic value is written in a handler, not while computing".into())
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_get(id: u64) -> Callable {
    match engine::memo_get(id) {
        Ok(value) => value,
        Err(why) => roc::abort(why),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_selector_new(runner: Callable) -> u64 {
    engine::selector_new(handed(runner))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_selector_is(id: u64, key: RocStr) -> bool {
    match engine::selector_is(id, taken(key)) {
        Ok(answer) => answer,
        Err(why) => roc::abort(why),
    }
}

/// A template (`Html.template`, D-084): its state, by its site (`engine::template`).
#[unsafe(no_mangle)]
pub extern "C" fn roc_template(site: RocStr) -> u32 {
    engine::template(taken(site))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_refresh(probe: Callable) {
    engine::refresh_probe(handed(probe))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_is_pending(probe: Callable) -> bool {
    engine::is_pending(handed(probe))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_fail(why: RocStr) {
    let why = taken(why);
    fail(why)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_event_value() -> RocStr {
    given(&engine::event_value())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_boundary() -> u64 {
    engine::boundary()
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_problem() -> RocStr {
    given(&engine::problem())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_retry(id: u64) {
    engine::retry(id)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_for_new() -> u64 {
    engine::for_new()
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_index(list: u64, key: RocStr) -> u64 {
    engine::row_index(list, taken(key))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_set(list: u64, key: RocStr, value: Callable, same: bool) -> bool {
    engine::row_set(list, taken(key), handed(value), same);
    // The engine makes each row from its box: none is kept.
    false
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_last(list: u64, key: RocStr, fallback: Callable) -> Callable {
    engine::row_last(list, taken(key), fallback)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_get(list: u64, key: RocStr) -> Callable {
    match engine::row_get(list, taken(key)) {
        Ok(value) => value,
        Err(why) => fail(why),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_value(value: Callable) -> u64 {
    engine::context_value(handed(value))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_find(name: RocStr) -> u64 {
    let name = taken(name);
    engine::context_find(&name)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_get(id: u64) -> Callable {
    match engine::context_get(id) {
        Ok(value) => value,
        Err(why) => fail(why),
    }
}

/// The browser's: there is no request being answered.
#[unsafe(no_mangle)]
pub extern "C" fn roc_request() -> RocStr {
    given("")
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_location() -> RocStr {
    given(&engine::location())
}

/// The browser's: nothing (a status is the server's answer to a page).
#[unsafe(no_mangle)]
pub extern "C" fn roc_status(_code: u16) {}

#[unsafe(no_mangle)]
pub extern "C" fn roc_fetch(method: RocStr, url: RocStr, headers: RocStr, body: RocStr) -> RocStr {
    let (method, url, headers, body) = (taken(method), taken(url), taken(headers), taken(body));
    let answer = engine::fetch_for(&method, &url, &headers, &body);
    drop((method, url, headers, body));
    match answer {
        Ok(json) => given(&json),
        Err(why) => roc::abort(why),
    }
}

/// `Endpoint.listen!` (D-140): the endpoint's events, read as they come (`live::listen`).
#[unsafe(no_mangle)]
pub extern "C" fn roc_listen(url: RocStr, handler: Callable) {
    crate::live::listen(taken(url), handed(handler))
}

/// `Endpoint.subscribe!` (D-140): a channel, on the app's one stream (`live::subscribe`).
#[unsafe(no_mangle)]
pub extern "C" fn roc_subscribe(url: RocStr, handler: Callable) {
    if let Err(why) = crate::live::subscribe(taken(url), handed(handler)) {
        fail(why)
    }
}

/// `Endpoint.say!` (D-140): what the app says on a channel, in the next post.
#[unsafe(no_mangle)]
pub extern "C" fn roc_say(url: RocStr, said: RocStr) {
    crate::live::say(taken(url), taken(said))
}

/// `Endpoint.resync!` (D-140): a resync of a channel the app subscribes to.
#[unsafe(no_mangle)]
pub extern "C" fn roc_resync(url: RocStr) {
    crate::live::resync(taken(url))
}

/// The server's, as in the browser.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_live_publish(topic: RocStr, message: RocStr) {
    drop((taken(topic), taken(message)));
    fail("Endpoint.publish! is the server's: a page says things on a channel with Endpoint.say!".into())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_timeout(ms: u64, handler: Callable) -> u64 {
    engine::start_timer(ms, false, handed(handler))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_interval(ms: u64, handler: Callable) -> u64 {
    engine::start_timer(ms, true, handed(handler))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_clear_timer(id: u64) {
    engine::clear_timer(id)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_now_millis() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_millis() as u64).unwrap_or(0)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_now_nanos() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_nanos() as u64).unwrap_or(0)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_browser_call(name: RocStr, arg: RocStr) {
    let (name, arg) = (taken(name), taken(arg));
    if let Err(why) = engine::browser_call(name, arg) {
        fail(why)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_effect_new(runner: Callable) {
    if let Err(why) = engine::effect_new(handed(runner)) {
        fail(why)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_effect_options(render: bool, error_box: u64) {
    engine::effect_options(render, error_box)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_cleanup(runner: Callable) {
    if let Err(why) = engine::cleanup(handed(runner)) {
        fail(why)
    }
}

/// The browser's: the flash the page came with (its document's, D-138).
#[unsafe(no_mangle)]
pub extern "C" fn roc_flash(found: RocStr) -> RocStr {
    drop(taken(found));
    given(&engine::flash())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_action(url: RocStr) {
    engine::action(taken(url))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission(url: RocStr) -> RocStr {
    given(&engine::submission(taken(url), false))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submissions(url: RocStr) -> RocStr {
    given(&engine::submission(taken(url), true))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission_clear(url: RocStr) {
    engine::submission_clear(taken(url))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission_drop(url: RocStr, id: u64) {
    engine::submission_drop(taken(url), id)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submit(method: RocStr, url: RocStr, body: RocStr, input: RocStr) {
    let sent = engine::submit(taken(method), taken(url), taken(body), taken(input));
    if let Err(why) = sent {
        fail(why)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_title(text: RocStr) {
    if let Err(why) = engine::title(taken(text)) {
        fail(why)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_untrack(on: bool) {
    engine::untrack(on)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_read_at(place: RocStr) -> RocStr {
    given(&engine::read_at(taken(place)))
}

// ---- D-054's router actions ----

#[unsafe(no_mangle)]
pub extern "C" fn roc_revalidate(keys: RocStr) {
    if let Err(why) = engine::revalidate_keys(taken(keys)) {
        fail(why)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission_retry(key: RocStr, id: u64) {
    engine::submission_retry(taken(key), id)
}

// ---- Navigation (D-040, D-138) and the page's <head> (D-054) ----
//
// As the browser's (nav.rs): the route table kept, `navigate!` once the handler is done, routing
// tracked, leave listeners asked before each navigation and back. A <Meta>, <Link> or <Style> has
// no <head> to go in.

#[unsafe(no_mangle)]
pub extern "C" fn roc_app(build: RocStr, _dev: bool, routes: RocStr) {
    taken(build);
    engine::app(&taken(routes));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_navigate(to: RocStr, replace: bool, scroll: bool) {
    let to = taken(to);
    if let Err(why) = engine::navigate(to, replace, scroll) {
        fail(why)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_is_routing() -> bool {
    engine::is_routing()
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_before_leave(listener: Callable) {
    if let Err(listener) = engine::before_leave(handed(listener)) {
        roc::release(listener);
        fail("Router.use_before_leave! is called in a component or a computation, which its listener goes with: in a handler or an effect's apply, nothing would own it".into())
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_leave_prevent(id: u64) {
    crate::nav::prevent(id)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_leave_retry(id: u64, force: bool) {
    if let Err(why) = engine::leave_retry(id, force) {
        fail(why)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_head(key: RocStr, markup: RocStr) {
    taken(key);
    taken(markup);
}
