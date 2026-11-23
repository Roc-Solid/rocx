//! Actors (`Actor`): a kind and a key, each with a mailbox, handling one message at a time, in the
//! order they came. Nothing is shared and nothing is locked. One task, the router, owns the table
//! of the actors that are awake and the timers. Every ask, tell and timer is an order sent to it,
//! and it passes each message on to its actor's mailbox. An actor is a task of its own: it takes
//! its messages one at a time and runs each in a call into Roc (`actor_for_host!`, a coroutine on
//! one of Roc's threads), which keeps its state (in Postgres, with a database) and answers. The only things two
//! threads touch are the channels (`tokio::sync::mpsc`, unbounded, and `oneshot`: atomics, no
//! lock) and the counter of timers.
//!
//! - Virtual: an actor is never made or ended by the app. The first message to a key wakes it (the
//!   router starts its task, and its first turn reads its state); after `idle` with nothing to do
//!   (`--actor-idle-ms`), it tells the router so, and the router lets it go if nothing was sent to
//!   it meanwhile: it had handled all it was sent, and its state is in Postgres, so the next
//!   message wakes it again as it was. Without a database its state is in its task alone, so it
//!   stays awake.
//! - Ordered: one router, and one mailbox each, both first-in first-out: an actor handles what one
//!   sender sends it in the order it was sent, and asks never overtake one another.
//! - Typed in Roc: messages and replies come here as JSON; a message an actor doesn't take (it
//!   doesn't parse as its kind's message), a kind the app has none of, and a crash in `receive!`
//!   are logged as errors, and told to the asker (an ask); the actor's state stays as it was, and
//!   it goes on with its next message.
//! - Asking is waiting: an actor that asks one whose turn waits on it (itself, or any actor up the
//!   chain of asks) is refused at once, and an ask not answered in 30 s is given up on (a cycle
//!   through two queues: each waits on a message behind the other's turn). A message whose asker
//!   gave up before its turn came is dropped, with a warning: its asker was told it failed.
//! - Timers: a tell, later (`after`), until cancelled (`cancel`): one that has fired, its message in
//!   its actor's mailbox, can still be cancelled until its turn comes, and its message is dropped.
//!   The platform numbers them, and with a database keeps each as a row (`ActorTimers.roc`, D-057),
//!   which is deleted here once the timer's turn has ended, however it ended (`hosted::forget_timer`),
//!   and set again by the platform's start after a restart. Tells not yet handled are in memory:
//!   a restart loses them (a job is for work that must survive one).

use crate::{coroutine, hosted, logging};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// An actor: its kind's name and its key.
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub struct Id {
    pub kind: String,
    pub key: String,
}

impl Id {
    /// As messages name it: `counter 7`.
    pub fn who(&self) -> String {
        format!("{} {}", self.kind, self.key)
    }
}

/// What an ask is answered with: the reply (JSON), or why there is none.
pub type Reply = Result<String, String>;

/// A message on its way to an actor: its JSON, where its answer goes (an ask's; none for a tell),
/// the actors whose turns wait on that answer (an ask made in a turn: that actor, and the ones
/// waiting on it), and the timer it comes from, if it does.
struct Letter {
    message: String,
    answer: Option<oneshot::Sender<Reply>>,
    waiting: Vec<Id>,
    timer: Option<Fired>,
}

/// A timer that has fired: its number, and whether it was cancelled before its turn came.
struct Fired {
    timer: u64,
    cancelled: Arc<AtomicBool>,
}

/// What the router is told.
enum Order {
    /// The app's kinds of actor, as the platform starts: a message to any other is refused.
    Kinds(HashSet<String>),
    Send(Id, Letter),
    After { timer: u64, to: Id, ms: u64, message: String },
    /// A timer's time has come.
    Fire(u64),
    Cancel(u64),
    /// A timer that fired has had its turn (or was dropped): it can't be cancelled now.
    Handled(u64),
    /// An actor has had nothing to do for `idle`, having been sent `handled` messages in its
    /// `life` (the router's count of the tasks it started, which tells an old one from a new).
    Idle { id: Id, handled: u64, life: u64 },
}

static ROUTER: OnceLock<mpsc::UnboundedSender<Order>> = OnceLock::new();

/// Starts the router, on the runtime this runs in. `idle`: how long an actor waits with nothing to
/// do before it is let go (none: never).
pub fn start(idle: Option<Duration>) {
    let (orders, inbox) = mpsc::unbounded_channel();
    if ROUTER.set(orders.clone()).is_ok() {
        tokio::spawn(Router { kinds: HashSet::new(), awake: HashMap::new(), timers: HashMap::new(), fired: HashMap::new(), lives: 0, orders, idle }.route(inbox));
    }
}

fn order(order: Order) -> Result<(), String> {
    match ROUTER.get() {
        Some(router) => router.send(order).map_err(|_| "the server is stopping".to_string()),
        None => Err("actors haven't started".to_string()),
    }
}

/// The app's kinds of actor (`program.actors`), as the platform starts.
pub fn kinds(names: impl IntoIterator<Item = String>) {
    let _ = order(Order::Kinds(names.into_iter().collect()));
}

/// Asks `to`, its message `message`: the answer, once it has handled the messages before it.
/// `waiting`: the actors whose turns wait on this ask.
pub fn ask(to: Id, message: String, waiting: Vec<Id>) -> Result<oneshot::Receiver<Reply>, String> {
    let (answer, answered) = oneshot::channel();
    order(Order::Send(to, Letter { message, answer: Some(answer), waiting, timer: None }))?;
    Ok(answered)
}

/// Sends `to` its message, answered by no one.
pub fn tell(to: Id, message: String) {
    if let Err(why) = order(Order::Send(to.clone(), Letter { message, answer: None, waiting: Vec::new(), timer: None })) {
        logging::warn("rocx actor: a message not sent", &[("actor", to.kind.into()), ("key", to.key.into()), ("error", why.into())]);
    }
}

/// Tells `to` its message in `ms` milliseconds, as the timer numbered `timer` (the platform's), for
/// `cancel`.
pub fn after(to: Id, ms: u64, message: String, timer: u64) {
    let _ = order(Order::After { timer, to, ms, message });
}

/// Stops a timer whose message hasn't been handled: waiting, or fired with its turn still to come.
/// (One that has been handled, or never was, is nothing to stop.)
pub fn cancel(timer: u64) {
    let _ = order(Order::Cancel(timer));
}

/// An actor that is awake: its mailbox, how many messages were sent to it, and which of the tasks
/// the router started it is.
struct Awake {
    mailbox: mpsc::UnboundedSender<Letter>,
    sent: u64,
    life: u64,
}

/// A timer that hasn't fired: what it tells whom, and its sleeping task.
struct Timer {
    to: Id,
    message: String,
    sleeping: tokio::task::AbortHandle,
}

/// The router's own state: no other task sees it.
struct Router {
    kinds: HashSet<String>,
    awake: HashMap<Id, Awake>,
    timers: HashMap<u64, Timer>,
    /// The timers that have fired and whose turns haven't come yet: a cancel still stops them.
    fired: HashMap<u64, Arc<AtomicBool>>,
    lives: u64,
    /// Its own inbox's sender, for the tasks it starts (timers, actors) to tell it things.
    orders: mpsc::UnboundedSender<Order>,
    idle: Option<Duration>,
}

impl Router {
    async fn route(mut self, mut inbox: mpsc::UnboundedReceiver<Order>) {
        while let Some(order) = inbox.recv().await {
            match order {
                Order::Kinds(kinds) => self.kinds = kinds,
                Order::Send(to, letter) => self.deliver(to, letter),
                Order::After { timer, to, ms, message } => {
                    let orders = self.orders.clone();
                    let sleeping = tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(ms)).await;
                        let _ = orders.send(Order::Fire(timer));
                    });
                    if let Some(replaced) = self.timers.insert(timer, Timer { to, message, sleeping: sleeping.abort_handle() }) {
                        replaced.sleeping.abort();
                    }
                }
                Order::Fire(timer) => {
                    if let Some(Timer { to, message, .. }) = self.timers.remove(&timer) {
                        let cancelled = Arc::new(AtomicBool::new(false));
                        self.fired.insert(timer, cancelled.clone());
                        self.deliver(to, Letter { message, answer: None, waiting: Vec::new(), timer: Some(Fired { timer, cancelled }) });
                    }
                }
                Order::Cancel(timer) => {
                    if let Some(waiting) = self.timers.remove(&timer) {
                        waiting.sleeping.abort();
                    } else if let Some(cancelled) = self.fired.remove(&timer) {
                        cancelled.store(true, Ordering::Release);
                    }
                }
                Order::Handled(timer) => {
                    self.fired.remove(&timer);
                }
                Order::Idle { id, handled, life } => {
                    // Nothing sent since it last looked: it goes, and its mailbox with it (its
                    // task sees the mailbox closed, and ends). Else the message on its way keeps it.
                    if self.awake.get(&id).is_some_and(|awake| awake.life == life && awake.sent == handled) {
                        self.awake.remove(&id);
                    }
                }
            }
        }
    }

    /// Puts `letter` in the mailbox of `to`, waking it if it sleeps.
    fn deliver(&mut self, to: Id, letter: Letter) {
        if !self.kinds.contains(&to.kind) {
            let why = format!("no kind of actor is called {}: the app defines none (`Actor.define`)", to.kind);
            failed(&to, &why);
            if let Some(answer) = letter.answer {
                let _ = answer.send(Err(why));
            }
            // A timer for a kind the app no longer has: its row goes too, or every start would set it.
            if let Some(fired) = letter.timer {
                self.fired.remove(&fired.timer);
                tokio::spawn(forget(fired.timer));
            }
            return;
        }
        let mut letter = letter;
        // Twice at most: a task that ended without being let go (it panicked) is started again.
        for _ in 0..2 {
            let awake = match self.awake.get_mut(&to) {
                Some(awake) => awake,
                None => {
                    self.lives += 1;
                    let (mailbox, letters) = mpsc::unbounded_channel();
                    tokio::spawn(live(to.clone(), self.lives, letters, self.orders.clone(), self.idle));
                    self.awake.entry(to.clone()).or_insert(Awake { mailbox, sent: 0, life: self.lives })
                }
            };
            match awake.mailbox.send(letter) {
                Ok(()) => {
                    awake.sent += 1;
                    return;
                }
                Err(mpsc::error::SendError(returned)) => {
                    self.awake.remove(&to);
                    letter = returned;
                }
            }
        }
    }
}

/// An actor, awake: its turns, one message at a time, until the router lets it go. `kept` is its
/// state as its last turn left it (JSON; none until a turn has read it).
async fn live(id: Id, life: u64, mut letters: mpsc::UnboundedReceiver<Letter>, router: mpsc::UnboundedSender<Order>, idle: Option<Duration>) {
    let mut kept: Option<String> = None;
    let mut handled = 0u64;
    // Let go only when its state is kept in the database, which the platform's start opened.
    let idle = idle.filter(|_| crate::db::flavor().is_some());
    loop {
        let next = match idle {
            Some(idle) => match tokio::time::timeout(idle, letters.recv()).await {
                Ok(next) => next,
                Err(_) => {
                    let _ = router.send(Order::Idle { id: id.clone(), handled, life });
                    continue;
                }
            },
            None => letters.recv().await,
        };
        let Some(Letter { message, answer, waiting, timer }) = next else { return };
        handled += 1;
        if answer.as_ref().is_some_and(|answer| answer.is_closed()) {
            logging::warn("rocx actor: a message dropped: its asker had given up", &[("actor", id.kind.clone().into()), ("key", id.key.clone().into())]);
            continue;
        }
        // A timer cancelled after it fired, before its turn: its message is dropped (its row went
        // with the cancel).
        if let Some(fired) = &timer {
            let _ = router.send(Order::Handled(fired.timer));
            if fired.cancelled.load(Ordering::Acquire) {
                continue;
            }
        }
        let turn = (id.clone(), kept.clone());
        let ran = coroutine::run(move || {
            let (id, kept) = turn;
            hosted::actor_turn(&id, waiting, kept.as_deref(), &message)
        })
        .await
        .unwrap_or_else(|_| Err("the host panicked".to_string()));
        let reply = match ran {
            Ok((state, reply)) => {
                kept = Some(state);
                Ok(reply)
            }
            Err(why) => {
                failed(&id, &why);
                Err(why)
            }
        };
        if let Some(answer) = answer {
            let _ = answer.send(reply);
        }
        // Its turn has ended, however it ended: its row goes (a message that crashes its actor
        // isn't told again after every restart).
        if let Some(fired) = timer {
            forget(fired.timer).await;
        }
    }
}

/// Deletes the row of a timer whose turn has ended (or whose kind is gone), with a database: in a
/// call of the platform's own (`rocx:actor-timer-done`). If it can't be, the timer is told again
/// after a restart.
async fn forget(timer: u64) {
    if crate::db::flavor().is_none() {
        return;
    }
    let forgotten = coroutine::run(move || hosted::forget_timer(timer)).await.unwrap_or_else(|_| Err("the host panicked".to_string()));
    if let Err(why) = forgotten {
        logging::error("rocx actor: a timer's row couldn't be deleted: it is told again after a restart", &[("timer", timer.to_string().into()), ("error", why.into())]);
    }
}

/// A message an actor didn't handle, logged.
fn failed(id: &Id, why: &str) {
    logging::error("rocx actor: a message failed", &[("actor", id.kind.clone().into()), ("key", id.key.clone().into()), ("error", why.to_string().into())]);
}
