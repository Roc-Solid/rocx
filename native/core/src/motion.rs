//! Motion on a phone (D-142): what moves, and how, as a browser's animation engine runs it.
//!
//! Four things move a view, each as the web has it:
//!
//! - **CSS animations** (`@keyframes` and `animation`): the keyframes' values resolved for the element
//!   (its custom properties, its colour), played with the animation's duration, delay, iteration
//!   count, direction, fill mode and play state, each keyframe's segment eased by its timing function;
//! - **CSS transitions**: a change to a property the element's `transition` names (opacity, a
//!   transform, colours, borders, shadows, and its box's size and place) goes from what is shown to
//!   the new value over its duration, after its delay, eased;
//! - **Roc's transition directives** (`transition:in`, `transition:out`, `transition={…}`): an element
//!   coming plays from its hidden style to its own, one going from its own to its hidden style (held
//!   there until it is taken away), as runtime.js's `play` asks the browser's `element.animate`;
//! - **glides** (`transition:move`, D-031): an element that a change of the page moved plays from
//!   where it was to where it is (FLIP), on top of its own transform.
//!
//! The projection (native.rs) says what is declared and what changed; this keeps what is running
//! and, on each frame of the phone's display (`tick`, Android's Choreographer), works out each moving
//! view's look as the projection's own properties (`style.opacity`, `style.transform`,
//! `style.background`…, and `MOVE` for a frame), sent as the same ops: the phone's applier sets them
//! as it sets any other, and Roc never runs for a frame. The timing model is the Web Animations
//! spec's (phases, fill, iterations, direction) and the easing functions CSS Easing's (`cubic-bezier`
//! solved as Chromium solves it, `steps` with its jumps, `linear()`'s points).

use crate::values::{self, Argb};
use std::collections::HashMap;

// ---- Easing ----

/// How a jump of `steps()` falls.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Jump {
    Start,
    End,
    None,
    Both,
}

/// A timing function (CSS Easing): `linear`, a cubic Bézier (`ease`, `ease-out`,
/// `cubic-bezier(…)`), `steps(n, …)`, or `linear(…)`'s points.
#[derive(Clone, Debug, PartialEq)]
pub enum Easing {
    Linear,
    Cubic([f64; 4]),
    Steps(u32, Jump),
    Points(Vec<(f64, f64)>),
}

impl Easing {
    pub const EASE: Easing = Easing::Cubic([0.25, 0.1, 0.25, 1.0]);

    /// A CSS timing function; none for what isn't one.
    pub fn parse(text: &str) -> Option<Easing> {
        let text = text.trim().to_ascii_lowercase();
        Some(match text.as_str() {
            "linear" => Easing::Linear,
            "ease" => Easing::EASE,
            "ease-in" => Easing::Cubic([0.42, 0.0, 1.0, 1.0]),
            "ease-out" => Easing::Cubic([0.0, 0.0, 0.58, 1.0]),
            "ease-in-out" => Easing::Cubic([0.42, 0.0, 0.58, 1.0]),
            "step-start" => Easing::Steps(1, Jump::Start),
            "step-end" => Easing::Steps(1, Jump::End),
            _ => {
                let open = text.find('(')?;
                let inner = text[open + 1..].strip_suffix(')')?;
                let args: Vec<&str> = inner.split(',').map(str::trim).collect();
                match &text[..open] {
                    "cubic-bezier" => {
                        let n: Vec<f64> = args.iter().filter_map(|arg| arg.parse().ok()).collect();
                        if n.len() != 4 || !(0.0..=1.0).contains(&n[0]) || !(0.0..=1.0).contains(&n[2]) {
                            return None;
                        }
                        Easing::Cubic([n[0], n[1], n[2], n[3]])
                    }
                    "steps" => {
                        let count: u32 = args.first()?.parse().ok()?;
                        let jump = match args.get(1).copied().unwrap_or("end") {
                            "start" | "jump-start" => Jump::Start,
                            "end" | "jump-end" => Jump::End,
                            "jump-none" => Jump::None,
                            "jump-both" => Jump::Both,
                            _ => return None,
                        };
                        if count == 0 || (jump == Jump::None && count < 2) {
                            return None;
                        }
                        Easing::Steps(count, jump)
                    }
                    "linear" => Easing::Points(linear_points(&args)?),
                    _ => return None,
                }
            }
        })
    }

    /// The eased progress at `x` (0 to 1; beyond, for what overshoots, a cubic's ends extended).
    pub fn at(&self, x: f64) -> f64 {
        match self {
            Easing::Linear => x,
            Easing::Cubic(points) => cubic(*points, x),
            Easing::Steps(count, jump) => {
                let count = *count as f64;
                let mut step = (x * count).floor();
                if matches!(jump, Jump::Start | Jump::Both) {
                    step += 1.0;
                }
                let jumps = match jump {
                    Jump::Start | Jump::End => count,
                    Jump::None => count - 1.0,
                    Jump::Both => count + 1.0,
                };
                if x >= 0.0 && step < 0.0 {
                    step = 0.0;
                }
                if x <= 1.0 && step > jumps {
                    step = jumps;
                }
                step / jumps
            }
            Easing::Points(points) => {
                let Some(first) = points.first() else { return x };
                if x <= first.0 {
                    return first.1;
                }
                for pair in points.windows(2) {
                    let ((x0, y0), (x1, y1)) = (pair[0], pair[1]);
                    if x <= x1 {
                        return if x1 > x0 { y0 + (y1 - y0) * (x - x0) / (x1 - x0) } else { y1 };
                    }
                }
                points.last().map(|last| last.1).unwrap_or(x)
            }
        }
    }
}

/// `linear()`'s stops, each with its place (given, or spread evenly between the given ones), as
/// CSS Easing's "canonicalize a linear() function" does.
fn linear_points(args: &[&str]) -> Option<Vec<(f64, f64)>> {
    let mut points: Vec<(Option<f64>, f64)> = Vec::new();
    for arg in args {
        let words: Vec<&str> = arg.split_whitespace().collect();
        let value: f64 = words.first()?.parse().ok()?;
        let places: Vec<f64> = words[1..].iter().filter_map(|word| word.strip_suffix('%')?.parse::<f64>().ok()).map(|p| p / 100.0).collect();
        if places.is_empty() {
            points.push((None, value));
        }
        for place in places {
            points.push((Some(place), value));
        }
    }
    if points.len() < 2 {
        return None;
    }
    if points[0].0.is_none() {
        points[0].0 = Some(0.0);
    }
    let last = points.len() - 1;
    if points[last].0.is_none() {
        points[last].0 = Some(points.iter().filter_map(|point| point.0).fold(1.0, f64::max));
    }
    // Each place no less than the one before; the ones not given spread between their neighbours.
    let mut most = 0.0f64;
    for point in points.iter_mut() {
        if let Some(place) = point.0.as_mut() {
            *place = place.max(most);
            most = *place;
        }
    }
    let mut at = 0;
    while at < points.len() {
        if points[at].0.is_some() {
            at += 1;
            continue;
        }
        let start = at - 1;
        let mut end = at;
        while points[end].0.is_none() {
            end += 1;
        }
        let (from, to) = (points[start].0.unwrap_or(0.0), points[end].0.unwrap_or(1.0));
        for each in at..end {
            points[each].0 = Some(from + (to - from) * (each - start) as f64 / (end - start) as f64);
        }
        at = end;
    }
    Some(points.into_iter().map(|(place, value)| (place.unwrap_or(0.0), value)).collect())
}

/// A cubic Bézier from (0, 0) to (1, 1) through two control points, at `x`: the curve's `t` for
/// that `x` found by Newton's method, then by bisection where that doesn't converge (Chromium's
/// `gfx::CubicBezier`); outside 0..1, the curve's tangent at its end.
fn cubic([x1, y1, x2, y2]: [f64; 4], x: f64) -> f64 {
    let (cx, cy) = (3.0 * x1, 3.0 * y1);
    let (bx, by) = (3.0 * (x2 - x1) - cx, 3.0 * (y2 - y1) - cy);
    let (ax, ay) = (1.0 - cx - bx, 1.0 - cy - by);
    let sample_x = |t: f64| ((ax * t + bx) * t + cx) * t;
    let sample_y = |t: f64| ((ay * t + by) * t + cy) * t;
    let slope_x = |t: f64| (3.0 * ax * t + 2.0 * bx) * t + cx;
    if x <= 0.0 {
        let start = if x1 > 0.0 { y1 / x1 } else if y1 == 0.0 && x2 > 0.0 { y2 / x2 } else { 0.0 };
        return start * x;
    }
    if x >= 1.0 {
        let end = if x2 < 1.0 { (y2 - 1.0) / (x2 - 1.0) } else if x2 == 1.0 && y2 == 1.0 && x1 < 1.0 { (y1 - 1.0) / (x1 - 1.0) } else { 0.0 };
        return 1.0 + end * (x - 1.0);
    }
    const EPSILON: f64 = 1e-7;
    let mut t = x;
    for _ in 0..8 {
        let error = sample_x(t) - x;
        if error.abs() < EPSILON {
            return sample_y(t);
        }
        let slope = slope_x(t);
        if slope.abs() < 1e-6 {
            break;
        }
        t -= error / slope;
    }
    let (mut low, mut high) = (0.0, 1.0);
    t = x;
    while low < high {
        let found = sample_x(t);
        if (found - x).abs() < EPSILON {
            return sample_y(t);
        }
        if x > found {
            low = t;
        } else {
            high = t;
        }
        t = (high - low) / 2.0 + low;
        if high - low < EPSILON {
            break;
        }
    }
    sample_y(t)
}

// ---- Timing ----

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Direction {
    Normal,
    Reverse,
    Alternate,
    AlternateReverse,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Fill {
    None,
    Forwards,
    Backwards,
    Both,
}

impl Fill {
    fn backwards(self) -> bool {
        matches!(self, Fill::Backwards | Fill::Both)
    }
    fn forwards(self) -> bool {
        matches!(self, Fill::Forwards | Fill::Both)
    }
}

/// An animation's timing (Web Animations' `EffectTiming`), in ms.
#[derive(Clone, Debug, PartialEq)]
pub struct Timing {
    pub duration: f64,
    pub delay: f64,
    /// How many times it runs (`f64::INFINITY`: for ever).
    pub iterations: f64,
    pub direction: Direction,
    pub fill: Fill,
    /// The whole iteration's easing (a transition's, a Roc transition's); a CSS animation's is
    /// linear, each keyframe's segment eased on its own (`Keyframe::easing`).
    pub easing: Easing,
}

impl Timing {
    pub fn once(duration: f64, delay: f64, easing: Easing, fill: Fill) -> Timing {
        Timing { duration: duration.max(0.0), delay, iterations: 1.0, direction: Direction::Normal, fill, easing }
    }

    /// When it is over: its delay and every iteration (infinite for an endless one).
    pub fn end(&self) -> f64 {
        self.delay + self.active()
    }

    fn active(&self) -> f64 {
        if self.iterations.is_infinite() { f64::INFINITY } else { self.duration * self.iterations.max(0.0) }
    }

    /// Its eased progress through an iteration at `t` ms after it started (its delay counted), or
    /// none while it has no effect (before its delay without filling backwards, after its end
    /// without filling forwards): Web Animations' "calculating the transformed progress".
    pub fn progress(&self, t: f64) -> Option<f64> {
        let active = self.active();
        let (active_time, after) = if t < self.delay {
            if !self.fill.backwards() {
                return None;
            }
            (0.0, false)
        } else if t >= self.delay + active {
            if !self.fill.forwards() {
                return None;
            }
            (active, true)
        } else {
            (t - self.delay, false)
        };
        let overall = if self.duration <= 0.0 { if after || t >= self.delay { self.iterations } else { 0.0 } } else { active_time / self.duration };
        if overall.is_infinite() {
            // An endless one is never after: unreachable, but kept sane.
            return Some(self.easing.at(1.0));
        }
        let mut simple = overall % 1.0;
        if simple == 0.0 && (after || (t >= self.delay && self.duration <= 0.0)) && self.iterations != 0.0 && overall > 0.0 {
            simple = 1.0;
        }
        let iteration = if simple == 1.0 { overall.floor() - 1.0 } else { overall.floor() };
        let forwards = match self.direction {
            Direction::Normal => true,
            Direction::Reverse => false,
            Direction::Alternate => iteration.rem_euclid(2.0) == 0.0,
            Direction::AlternateReverse => iteration.rem_euclid(2.0) != 0.0,
        };
        let directed = if forwards { simple } else { 1.0 - simple };
        Some(self.easing.at(directed))
    }
}

/// A CSS time (`150ms`, `0.2s`), in ms.
pub fn time(word: &str) -> Option<f64> {
    let word = word.trim();
    if let Some(ms) = word.strip_suffix("ms") {
        return ms.trim().parse().ok();
    }
    word.strip_suffix('s').and_then(|s| s.trim().parse::<f64>().ok()).map(|s| s * 1000.0)
}

// ---- Looks ----

/// What of a view's look moves: the projection's own properties (native.rs's `paint`), and its frame.
pub const KEYS: [&str; 7] = ["style.opacity", "style.transform", "style.background", "style.color", "style.border", "style.shadow", "style.ring"];

/// The frame's key: a view's place and size in its parent (`MOVE` while it moves, D-142).
pub const FRAME: &str = "frame";

/// One of a view's looks, as a value that moves.
#[derive(Clone, Debug, PartialEq)]
pub enum Look {
    Number(f32),
    /// `tx ty sx sy degrees`, and the origin it scales and turns about.
    Transform([f32; 5], [f32; 2]),
    Colour(Argb),
    Border([f32; 4], [Argb; 4]),
    /// `x y blur spread`, and its colour.
    Shadow([f32; 4], Argb),
    Ring(f32, Argb),
    Frame([f32; 4]),
}

impl Look {
    /// A property's value as the projection writes it (`""`: none, as the view has without it).
    /// `frame` is the view's frame, for a transform's origin when it has none.
    pub fn parse(key: &str, text: &str, frame: [f32; 4]) -> Option<Look> {
        let numbers = |text: &str| -> Vec<f32> { text.split_whitespace().filter_map(|word| word.parse().ok()).collect() };
        let colour = |word: Option<&str>| -> Argb { word.and_then(|word| u32::from_str_radix(word.trim_start_matches('#'), 16).ok()).unwrap_or(0) };
        let words: Vec<&str> = text.split_whitespace().collect();
        Some(match key {
            "style.opacity" => Look::Number(text.trim().parse().unwrap_or(1.0)),
            "style.transform" => {
                let n = numbers(text);
                if n.len() == 7 { Look::Transform([n[0], n[1], n[2], n[3], n[4]], [n[5], n[6]]) } else { Look::Transform([0.0, 0.0, 1.0, 1.0, 0.0], [frame[2] / 2.0, frame[3] / 2.0]) }
            }
            "style.background" | "style.color" => Look::Colour(if text.is_empty() { 0 } else { colour(Some(text)) }),
            "style.border" => {
                if words.len() == 8 {
                    let n = numbers(&words[..4].join(" "));
                    Look::Border([n.first().copied().unwrap_or(0.0), n.get(1).copied().unwrap_or(0.0), n.get(2).copied().unwrap_or(0.0), n.get(3).copied().unwrap_or(0.0)], [colour(words.get(4).copied()), colour(words.get(5).copied()), colour(words.get(6).copied()), colour(words.get(7).copied())])
                } else {
                    Look::Border([0.0; 4], [0; 4])
                }
            }
            "style.shadow" => {
                let n = numbers(&words.iter().take(4).copied().collect::<Vec<_>>().join(" "));
                if words.len() == 5 && n.len() == 4 { Look::Shadow([n[0], n[1], n[2], n[3]], colour(words.get(4).copied())) } else { Look::Shadow([0.0; 4], 0) }
            }
            "style.ring" => {
                if words.len() == 2 { Look::Ring(words[0].parse().unwrap_or(0.0), colour(words.get(1).copied())) } else { Look::Ring(0.0, 0) }
            }
            FRAME => {
                let n = numbers(text);
                if n.len() == 4 { Look::Frame([n[0], n[1], n[2], n[3]]) } else { Look::Frame(frame) }
            }
            _ => return None,
        })
    }

    /// As the projection writes it, for the phone's applier.
    pub fn text(&self) -> String {
        let n = |value: f32| {
            let rounded = (value * 1000.0).round() / 1000.0;
            if rounded == 0.0 { "0".to_string() } else { format!("{rounded}") }
        };
        match self {
            Look::Number(value) => n(*value),
            Look::Transform(t, origin) => format!("{} {} {} {} {} {} {}", n(t[0]), n(t[1]), n(t[2]), n(t[3]), n(t[4]), n(origin[0]), n(origin[1])),
            Look::Colour(colour) => values::argb(*colour),
            Look::Border(widths, colours) => format!("{} {} {} {} {} {} {} {}", n(widths[0]), n(widths[1]), n(widths[2]), n(widths[3]), values::argb(colours[0]), values::argb(colours[1]), values::argb(colours[2]), values::argb(colours[3])),
            Look::Shadow(s, colour) => format!("{} {} {} {} {}", n(s[0]), n(s[1]), n(s[2]), n(s[3]), values::argb(*colour)),
            Look::Ring(width, colour) => format!("{} {}", n(*width), values::argb(*colour)),
            Look::Frame(f) => format!("{} {} {} {}", f[0], f[1], f[2], f[3]),
        }
    }

    /// Between two looks of one key, `t` of the way (CSS's interpolation: numbers and lengths
    /// linearly, colours premultiplied in sRGB, a transform's parts each, its origin the end's).
    pub fn lerp(&self, other: &Look, t: f64) -> Look {
        let t = t as f32;
        let mix = |a: f32, b: f32| a + (b - a) * t;
        match (self, other) {
            (Look::Number(a), Look::Number(b)) => Look::Number(mix(*a, *b)),
            // About the end's origin, or the start's when the end is no transform at all.
            (Look::Transform(a, from), Look::Transform(b, to)) => Look::Transform(std::array::from_fn(|i| mix(a[i], b[i])), if *b == [0.0, 0.0, 1.0, 1.0, 0.0] { *from } else { *to }),
            (Look::Colour(a), Look::Colour(b)) => Look::Colour(mix_colour(*a, *b, t)),
            (Look::Border(wa, ca), Look::Border(wb, cb)) => Look::Border(std::array::from_fn(|i| mix(wa[i], wb[i])), std::array::from_fn(|i| mix_colour(ca[i], cb[i], t))),
            (Look::Shadow(a, ca), Look::Shadow(b, cb)) => Look::Shadow(std::array::from_fn(|i| mix(a[i], b[i])), mix_colour(*ca, *cb, t)),
            (Look::Ring(a, ca), Look::Ring(b, cb)) => Look::Ring(mix(*a, *b), mix_colour(*ca, *cb, t)),
            (Look::Frame(a), Look::Frame(b)) => Look::Frame(std::array::from_fn(|i| mix(a[i], b[i]))),
            // Looks of two kinds don't mix: CSS's discrete step, at half way.
            (a, b) => {
                if t < 0.5 {
                    a.clone()
                } else {
                    b.clone()
                }
            }
        }
    }
}

/// Two colours mixed, `t` of the way, premultiplied (so a colour fading from transparent keeps its
/// hue, as CSS interpolates it).
pub fn mix_colour(a: Argb, b: Argb, t: f32) -> Argb {
    let channel = |colour: Argb, shift: u32| ((colour >> shift) & 0xff) as f32;
    let (aa, ab) = (channel(a, 24) / 255.0, channel(b, 24) / 255.0);
    let alpha = aa + (ab - aa) * t;
    if alpha <= 0.0 {
        return 0;
    }
    let mut out = ((alpha * 255.0).round().clamp(0.0, 255.0) as u32) << 24;
    for shift in [16, 8, 0] {
        let (ca, cb) = (channel(a, shift) * aa, channel(b, shift) * ab);
        let value = (ca + (cb - ca) * t) / alpha;
        out |= (value.round().clamp(0.0, 255.0) as u32) << shift;
    }
    out
}

// ---- What plays ----

/// What started an animation.
#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    /// A CSS animation, by its name and place in the element's `animation-name` list.
    Css(String, usize),
    /// A CSS transition of one key.
    Transition(String),
    /// Roc's `transition:in`.
    In,
    /// Roc's `transition:out`, and what to say once it is over (the part it is in, taken away).
    Out(u64),
    /// `transition:move`: from where it was, by this much (`dx dy sx sy`), to where it is.
    Glide([f32; 4]),
    /// A page's change (D-040's view transitions): its views coming.
    Page,
}

/// A keyframe: where in the iteration (0 to 1), its value (none: the value under the animation,
/// the view's own), and how the segment after it is eased (a CSS animation's).
#[derive(Clone, Debug, PartialEq)]
pub struct Keyframe {
    pub at: f64,
    pub look: Option<String>,
    pub easing: Option<Easing>,
}

/// One key's keyframes.
#[derive(Clone, Debug, PartialEq)]
pub struct Track {
    pub key: String,
    pub frames: Vec<Keyframe>,
}

impl Track {
    /// A track from its keyframes: sorted, with a 0 and a 1 of the underlying value when none says
    /// them (CSS's implicit keyframes).
    pub fn new(key: &str, mut frames: Vec<Keyframe>) -> Track {
        frames.sort_by(|a, b| a.at.partial_cmp(&b.at).unwrap_or(std::cmp::Ordering::Equal));
        if frames.first().is_none_or(|first| first.at > 0.0) {
            let easing = frames.first().and_then(|first| first.easing.clone());
            frames.insert(0, Keyframe { at: 0.0, look: None, easing });
        }
        if frames.last().is_none_or(|last| last.at < 1.0) {
            frames.push(Keyframe { at: 1.0, look: None, easing: None });
        }
        Track { key: key.to_string(), frames }
    }

    /// Its value at eased progress `p`, over `under` (what is under it).
    fn at(&self, p: f64, under: &Look, frame: [f32; 4]) -> Look {
        let value = |keyframe: &Keyframe| keyframe.look.as_deref().and_then(|text| Look::parse(&self.key, text, frame)).unwrap_or_else(|| under.clone());
        let frames = &self.frames;
        // The segment `p` is in (the first or last one when it overshoots).
        let mut at = 0;
        while at + 2 < frames.len() && p >= frames[at + 1].at {
            at += 1;
        }
        let (from, to) = (&frames[at], &frames[at + 1]);
        // Keyframes at one place: the later one's value from there on.
        if to.at <= from.at {
            return value(if p >= to.at { to } else { from });
        }
        let local = (p - from.at) / (to.at - from.at);
        let eased = from.easing.as_ref().map(|easing| easing.at(local)).unwrap_or(local);
        value(from).lerp(&value(to), eased)
    }
}

/// An animation on a view.
#[derive(Clone, Debug)]
pub struct Animation {
    pub kind: Kind,
    pub timing: Timing,
    pub tracks: Vec<Track>,
    /// When it started on the display's clock (ms); none until the next frame, as a browser's
    /// pending animation (it shows its start until then).
    pub start: Option<f64>,
    /// Paused (`animation-play-state: paused`): its time stands still.
    pub paused_at: Option<f64>,
    /// Said over (`animationend`, an out-transition's part taken away).
    pub said: bool,
}

impl Animation {
    pub fn new(kind: Kind, timing: Timing, tracks: Vec<Track>) -> Animation {
        Animation { kind, timing, tracks, start: None, paused_at: None, said: false }
    }

    fn local(&self, now: f64) -> f64 {
        match (self.start, self.paused_at) {
            (_, Some(paused)) => paused,
            (Some(start), None) => (now - start).max(0.0),
            (None, None) => 0.0,
        }
    }

    /// Whether it is over: past its end (it may still hold its last value, filling forwards).
    pub fn over(&self, now: f64) -> bool {
        self.paused_at.is_none() && self.start.is_some() && self.local(now) >= self.timing.end()
    }

    /// The order animations stack in: transitions under animations (CSS's cascade of the two), Roc's
    /// over both, a glide on top of all.
    fn layer(&self) -> u8 {
        match self.kind {
            Kind::Transition(_) => 0,
            Kind::Css(..) => 1,
            Kind::Page => 2,
            Kind::In | Kind::Out(_) => 3,
            Kind::Glide(_) => 4,
        }
    }
}

/// What a tick (or a render) found: the ops' values to set, the out-transitions over (their
/// tokens), and the events to tell the page (`animationend`, `transitionend`).
#[derive(Default, Debug)]
pub struct Frame {
    /// `(view, key, value)`: a key's value now (`frame`'s as `x y w h`).
    pub sets: Vec<(u64, String, String)>,
    pub ended: Vec<u64>,
    pub events: Vec<(u64, &'static str, String)>,
}

/// Every animation running, by view, and what was last sent for each key they move.
#[derive(Default)]
pub struct Motion {
    /// The display's last frame's time (ms).
    pub clock: f64,
    pub running: HashMap<u64, Vec<Animation>>,
    /// What each (view, key) moved last showed: the starting point of a transition that interrupts
    /// it, and what isn't sent again.
    shown: HashMap<(u64, String), String>,
    /// Keys an animation stopped moving outside a frame (one no longer declared, one replaced):
    /// back to the view's own at the next frame or render, unless another moves them.
    released: Vec<(u64, String)>,
}

impl Motion {
    /// Whether an animation moves this key of this view (the projection sends it no value of its
    /// own then: the animation's goes, over it).
    pub fn drives(&self, view: u64, key: &str) -> bool {
        self.running.get(&view).is_some_and(|list| list.iter().any(|animation| animation.tracks.iter().any(|track| track.key == key) || (key == "style.transform" && matches!(animation.kind, Kind::Glide(_)))))
    }

    /// What is shown now of a key an animation moves (its last value sent).
    pub fn shown(&self, view: u64, key: &str) -> Option<&str> {
        self.shown.get(&(view, key.to_string())).map(String::as_str)
    }

    /// An animation started on a view (in place of one of the same kind: a transition of the same
    /// key, a glide, Roc's in or out).
    pub fn play(&mut self, view: u64, animation: Animation) {
        let list = self.running.entry(view).or_default();
        let mut released = Vec::new();
        list.retain(|running| {
            let keeps = match (&running.kind, &animation.kind) {
                (Kind::Transition(a), Kind::Transition(b)) => a != b,
                (Kind::Glide(_), Kind::Glide(_)) => false,
                (Kind::In | Kind::Out(_), Kind::In | Kind::Out(_)) => false,
                (Kind::Page, Kind::Page) => false,
                (a, b) => a != b,
            };
            if !keeps {
                released.extend(keys_moved(running).into_iter().map(|key| (view, key)));
            }
            keeps
        });
        list.push(animation);
        list.sort_by_key(Animation::layer);
        self.released.extend(released);
    }

    /// The CSS animations a view's style names now (`animation-name`, each with its timing and
    /// keyframes): one still named the same keeps running (its timing, play state and keyframes
    /// updated), one no longer named stops, a new one starts.
    pub fn declare(&mut self, view: u64, declared: Vec<Animation>) {
        let now = self.clock;
        let list = self.running.entry(view).or_default();
        let mut released = Vec::new();
        list.retain(|running| {
            let keeps = !matches!(&running.kind, Kind::Css(..)) || declared.iter().any(|wanted| wanted.kind == running.kind);
            if !keeps {
                released.extend(keys_moved(running).into_iter().map(|key| (view, key)));
            }
            keeps
        });
        self.released.extend(released);
        for mut wanted in declared {
            match list.iter_mut().find(|running| running.kind == wanted.kind) {
                Some(running) => {
                    let paused = wanted.paused_at.is_some();
                    running.tracks = wanted.tracks;
                    if running.timing != wanted.timing {
                        running.timing = wanted.timing;
                    }
                    match (paused, running.paused_at) {
                        (true, None) => running.paused_at = Some(running.local(now)),
                        (false, Some(at)) => {
                            running.paused_at = None;
                            running.start = running.start.map(|_| now - at);
                        }
                        _ => {}
                    }
                }
                None => {
                    if wanted.paused_at.is_some() {
                        wanted.paused_at = Some(0.0);
                    }
                    list.push(wanted);
                }
            }
        }
        list.sort_by_key(Animation::layer);
        if list.is_empty() {
            self.running.remove(&view);
        }
    }

    /// A view is gone: what moved it stops (an out-transition's part is said over).
    pub fn forget(&mut self, view: u64) -> Vec<u64> {
        self.shown.retain(|(id, _), _| *id != view);
        self.running.remove(&view).unwrap_or_default().into_iter().filter_map(|animation| if let Kind::Out(token) = animation.kind { Some(token) } else { None }).collect()
    }

    /// Stops what is running of a kind on a view (a glide's pair, its out-transition over at once).
    pub fn stop(&mut self, view: u64, matches: impl Fn(&Kind) -> bool) {
        if let Some(list) = self.running.get_mut(&view) {
            let mut released = Vec::new();
            list.retain(|animation| {
                let stops = matches(&animation.kind);
                if stops {
                    released.extend(keys_moved(animation).into_iter().map(|key| (view, key)));
                }
                !stops
            });
            self.released.extend(released);
        }
    }

    /// Whether anything is still to move (the display's frames are wanted).
    pub fn moving(&self) -> bool {
        let now = self.clock;
        self.running.values().flatten().any(|animation| animation.paused_at.is_none() && (animation.start.is_none() || !animation.over(now)))
    }

    /// Every moving view's looks at `now` (the display's clock), as `(view, key, value)` for what
    /// changed since last sent; each key no animation moves any more back to the view's own
    /// (`under`: its value as the projection has it, and the view's frame). With `start`, animations
    /// waiting for their first frame start now; without (a render), they show their start.
    pub fn frame(&mut self, now: f64, start: bool, under: &dyn Fn(u64, &str) -> (Option<String>, [f32; 4])) -> Frame {
        if start {
            self.clock = now;
        }
        let now = self.clock;
        let mut out = Frame::default();
        // Keys no longer moved: back to the view's own.
        for (view, key) in std::mem::take(&mut self.released) {
            if self.drives(view, &key) {
                continue;
            }
            let id = (view, key);
            if let Some(was) = self.shown.remove(&id) {
                let (own, _) = under(view, &id.1);
                let own = own.unwrap_or_default();
                if was != own {
                    out.sets.push((view, id.1, own));
                }
            }
        }
        let mut views: Vec<u64> = self.running.keys().copied().collect();
        views.sort_unstable();
        for view in views {
            let Some(list) = self.running.get_mut(&view) else { continue };
            if start {
                for animation in list.iter_mut() {
                    if animation.start.is_none() && animation.paused_at.is_none() {
                        animation.start = Some(now);
                    }
                }
            }
            // The keys these move, each composed from what is under them up.
            let mut keys: Vec<String> = Vec::new();
            for animation in list.iter() {
                for track in &animation.tracks {
                    if !keys.contains(&track.key) {
                        keys.push(track.key.clone());
                    }
                }
                if matches!(animation.kind, Kind::Glide(_)) && !keys.iter().any(|key| key == "style.transform") {
                    keys.push("style.transform".into());
                }
            }
            for key in &keys {
                let (own, frame) = under(view, key);
                let Some(mut look) = Look::parse(key, own.as_deref().unwrap_or(""), frame) else { continue };
                let mut moved = false;
                for animation in list.iter() {
                    let Some(p) = animation.timing.progress(animation.local(now)) else { continue };
                    if let Kind::Glide([dx, dy, sx, sy]) = animation.kind {
                        if let Look::Transform(t, origin) = &mut look {
                            // FLIP: from where it was (dx, dy away, sx and sy its size) to its place.
                            let (gx, gy) = (1.0 + (sx - 1.0) * (1.0 - p as f32), 1.0 + (sy - 1.0) * (1.0 - p as f32));
                            t[0] += (dx - origin[0] * (1.0 - sx)) * (1.0 - p as f32);
                            t[1] += (dy - origin[1] * (1.0 - sy)) * (1.0 - p as f32);
                            t[2] *= gx;
                            t[3] *= gy;
                            moved = true;
                        }
                        continue;
                    }
                    for track in animation.tracks.iter().filter(|track| &track.key == key) {
                        look = track.at(p, &look, frame);
                        moved = true;
                    }
                }
                let text = if moved { look.text() } else { own.clone().unwrap_or_default() };
                let id = (view, key.clone());
                if self.shown.get(&id) != Some(&text) {
                    out.sets.push((view, key.clone(), text.clone()));
                    self.shown.insert(id, text);
                }
            }
            // What is over goes (one filling forwards stays, holding its end, while it is declared
            // or until its part is taken away); the keys left unmoved go back to the view's own.
            if start {
                let mut gone_keys: Vec<String> = Vec::new();
                list.retain_mut(|animation| {
                    if !animation.over(now) {
                        return true;
                    }
                    if !animation.said {
                        animation.said = true;
                        match &animation.kind {
                            Kind::Out(token) => out.ended.push(*token),
                            Kind::Css(name, _) => out.events.push((view, "animationend", name.clone())),
                            Kind::Transition(key) => out.events.push((view, "transitionend", key.clone())),
                            _ => {}
                        }
                    }
                    let holds = animation.timing.fill.forwards() && matches!(animation.kind, Kind::Css(..) | Kind::Out(_));
                    if !holds {
                        gone_keys.extend(animation.tracks.iter().map(|track| track.key.clone()));
                        if matches!(animation.kind, Kind::Glide(_)) {
                            gone_keys.push("style.transform".into());
                        }
                    }
                    holds
                });
                for key in gone_keys {
                    let still = list.iter().any(|animation| animation.tracks.iter().any(|track| track.key == key) || (key == "style.transform" && matches!(animation.kind, Kind::Glide(_))));
                    if still {
                        continue;
                    }
                    let id = (view, key.clone());
                    let (own, _) = under(view, &key);
                    let own = own.unwrap_or_default();
                    if self.shown.remove(&id).as_ref() != Some(&own) {
                        out.sets.push((view, key, own));
                    }
                }
                if list.is_empty() {
                    self.running.remove(&view);
                }
            }
        }
        out
    }
}

/// The keys an animation moves (a glide's: the transform).
fn keys_moved(animation: &Animation) -> Vec<String> {
    let mut keys: Vec<String> = animation.tracks.iter().map(|track| track.key.clone()).collect();
    if matches!(animation.kind, Kind::Glide(_)) {
        keys.push("style.transform".into());
    }
    keys
}

// ---- What the CSS says ----

/// `transition`'s longhands (css.rs expands the shorthand into them) as each property's timing:
/// `[(property, timing)]`, the property as CSS names it (`all`, `opacity`, `background-color`…).
pub fn transitions(property: Option<&str>, duration: Option<&str>, easing: Option<&str>, delay: Option<&str>) -> Vec<(String, Timing)> {
    let list = |value: Option<&str>| -> Vec<String> { value.map(|value| values::split(value, Some(','))).unwrap_or_default() };
    let (properties, durations, easings, delays) = (list(property), list(duration), list(easing), list(delay));
    let pick = |list: &Vec<String>, at: usize| -> Option<String> { if list.is_empty() { None } else { Some(list[at % list.len()].clone()) } };
    let mut out = Vec::new();
    for (at, name) in properties.iter().enumerate() {
        let name = name.trim().to_ascii_lowercase();
        if name == "none" || name.is_empty() {
            continue;
        }
        let duration = pick(&durations, at).and_then(|d| time(&d)).unwrap_or(0.0);
        let delay = pick(&delays, at).and_then(|d| time(&d)).unwrap_or(0.0);
        if duration <= 0.0 {
            continue;
        }
        let easing = pick(&easings, at).and_then(|e| Easing::parse(&e)).unwrap_or(Easing::EASE);
        out.retain(|(have, _): &(String, Timing)| *have != name);
        out.push((name, Timing::once(duration, delay, easing, Fill::Backwards)));
    }
    out
}

/// The keys a CSS property moves (`all` every one; the box's size and place its frame).
pub fn keys_of(property: &str) -> &'static [&'static str] {
    match property {
        "all" => &["style.opacity", "style.transform", "style.background", "style.color", "style.border", "style.shadow", "style.ring", FRAME],
        "opacity" => &["style.opacity"],
        "transform" | "translate" | "scale" | "rotate" | "transform-origin" => &["style.transform"],
        "background" | "background-color" => &["style.background"],
        "color" => &["style.color"],
        "box-shadow" => &["style.shadow", "style.ring"],
        "border" | "border-color" | "border-width" | "border-top" | "border-right" | "border-bottom" | "border-left" | "border-top-color" | "border-right-color" | "border-bottom-color" | "border-left-color" | "border-top-width" | "border-right-width" | "border-bottom-width" | "border-left-width" => &["style.border"],
        "width" | "height" | "inset" | "top" | "left" | "right" | "bottom" | "min-width" | "max-width" | "min-height" | "max-height" | "flex-basis" | "inline-size" | "block-size" => &[FRAME],
        _ => &[],
    }
}

/// One CSS animation as the element's `animation-*` longhands say it, at `at` in their lists.
#[derive(Clone, Debug, PartialEq)]
pub struct Named {
    pub name: String,
    pub timing: Timing,
    /// The animation's timing function: each keyframe's segment's, unless the keyframe says its own.
    pub easing: Easing,
    pub paused: bool,
}

/// `animation`'s longhands as the animations they name, in order.
pub fn animations(get: &dyn Fn(&str) -> Option<String>) -> Vec<Named> {
    let list = |name: &str| -> Vec<String> { get(name).map(|value| values::split(&value, Some(','))).unwrap_or_default() };
    let names = list("animation-name");
    let (durations, easings, delays, counts, directions, fills, states) = (list("animation-duration"), list("animation-timing-function"), list("animation-delay"), list("animation-iteration-count"), list("animation-direction"), list("animation-fill-mode"), list("animation-play-state"));
    let pick = |list: &Vec<String>, at: usize| -> Option<String> { if list.is_empty() { None } else { Some(list[at % list.len()].trim().to_ascii_lowercase()) } };
    let mut out = Vec::new();
    for (at, name) in names.iter().enumerate() {
        let name = name.trim().trim_matches(|c| c == '"' || c == '\'');
        if name.is_empty() || name.eq_ignore_ascii_case("none") {
            continue;
        }
        let duration = pick(&durations, at).and_then(|d| time(&d)).unwrap_or(0.0);
        let delay = pick(&delays, at).and_then(|d| time(&d)).unwrap_or(0.0);
        let iterations = match pick(&counts, at).as_deref() {
            Some("infinite") => f64::INFINITY,
            Some(count) => count.parse().unwrap_or(1.0),
            None => 1.0,
        };
        let direction = match pick(&directions, at).as_deref() {
            Some("reverse") => Direction::Reverse,
            Some("alternate") => Direction::Alternate,
            Some("alternate-reverse") => Direction::AlternateReverse,
            _ => Direction::Normal,
        };
        let fill = match pick(&fills, at).as_deref() {
            Some("forwards") => Fill::Forwards,
            Some("backwards") => Fill::Backwards,
            Some("both") => Fill::Both,
            _ => Fill::None,
        };
        let easing = pick(&easings, at).and_then(|e| Easing::parse(&e)).unwrap_or(Easing::EASE);
        let paused = pick(&states, at).as_deref() == Some("paused");
        out.push(Named { name: name.to_string(), timing: Timing { duration, delay, iterations, direction, fill, easing: Easing::Linear }, easing, paused });
    }
    out
}

/// `transition` or `animation` (the shorthands) as their longhands, layer by layer, each longhand a
/// comma-separated list (css.rs's `expand`): `[(longhand, value)]`.
pub fn expand(name: &str, value: &str) -> Vec<(String, String)> {
    let animation = name == "animation";
    let longhands: &[&str] = if animation {
        &["animation-name", "animation-duration", "animation-timing-function", "animation-delay", "animation-iteration-count", "animation-direction", "animation-fill-mode", "animation-play-state"]
    } else {
        &["transition-property", "transition-duration", "transition-timing-function", "transition-delay"]
    };
    if matches!(value.trim().to_ascii_lowercase().as_str(), "inherit" | "initial" | "unset" | "revert" | "revert-layer") {
        return longhands.iter().map(|long| (long.to_string(), value.trim().to_string())).collect();
    }
    let mut columns: Vec<Vec<String>> = vec![Vec::new(); longhands.len()];
    for layer in values::split(value, Some(',')) {
        let mut times = Vec::new();
        let mut cells: Vec<Option<String>> = vec![None; longhands.len()];
        for word in values::split(&layer, None) {
            let lower = word.to_ascii_lowercase();
            if time(&lower).is_some() {
                times.push(lower);
            } else if Easing::parse(&lower).is_some() {
                cells[2] = Some(lower);
            } else if animation && (lower == "infinite" || lower.parse::<f64>().is_ok()) {
                cells[4] = Some(lower);
            } else if animation && matches!(lower.as_str(), "normal" | "reverse" | "alternate" | "alternate-reverse") && cells[5].is_none() {
                cells[5] = Some(lower);
            } else if animation && matches!(lower.as_str(), "none" | "forwards" | "backwards" | "both") && cells[6].is_none() {
                cells[6] = Some(lower);
            } else if animation && matches!(lower.as_str(), "running" | "paused") && cells[7].is_none() {
                cells[7] = Some(lower);
            } else if !animation && matches!(lower.as_str(), "allow-discrete" | "normal") {
                // `transition-behavior`'s: nothing a phone does.
            } else if cells[0].is_none() {
                // What no other longhand takes is the name (the property).
                cells[0] = Some(word.clone());
            }
        }
        cells[1] = times.first().cloned();
        cells[3] = times.get(1).cloned();
        let defaults: &[&str] = if animation { &["none", "0s", "ease", "0s", "1", "normal", "none", "running"] } else { &["all", "0s", "ease", "0s"] };
        for (at, cell) in cells.into_iter().enumerate() {
            columns[at].push(cell.unwrap_or_else(|| defaults[at].to_string()));
        }
    }
    longhands.iter().zip(columns).map(|(long, column)| (long.to_string(), column.join(", "))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-3
    }

    #[test]
    fn cubic_beziers_ease_as_browsers_do() {
        // Values from Chromium's gfx::CubicBezier (and the spec's keywords).
        let ease = Easing::parse("ease").unwrap();
        assert!(close(ease.at(0.0), 0.0) && close(ease.at(1.0), 1.0));
        assert!(close(ease.at(0.25), 0.4094), "{}", ease.at(0.25));
        assert!(close(ease.at(0.5), 0.8024), "{}", ease.at(0.5));
        let out = Easing::parse("ease-out").unwrap();
        assert!(close(out.at(0.5), 0.6847), "{}", out.at(0.5));
        let glide = Easing::parse("cubic-bezier(0.2, 0, 0, 1)").unwrap();
        assert!(close(glide.at(0.5), 0.8779), "{}", glide.at(0.5));
        // Overshooting ones go past 1.
        let back = Easing::parse("cubic-bezier(0.34, 1.56, 0.64, 1)").unwrap();
        assert!(back.at(0.6) > 1.0);
        assert_eq!(Easing::parse("cubic-bezier(2, 0, 0, 1)"), None, "x outside 0..1");
        assert!(close(Easing::Linear.at(0.3), 0.3));
    }

    #[test]
    fn steps_jump_where_css_says() {
        let end = Easing::parse("steps(4)").unwrap();
        assert_eq!([0.0, 0.24, 0.25, 0.99, 1.0].map(|x| end.at(x)), [0.0, 0.0, 0.25, 0.75, 1.0]);
        let start = Easing::parse("steps(4, jump-start)").unwrap();
        assert_eq!([0.0, 0.24, 0.25, 1.0].map(|x| start.at(x)), [0.25, 0.25, 0.5, 1.0]);
        let none = Easing::parse("steps(5, jump-none)").unwrap();
        assert_eq!([0.0, 0.2, 0.99, 1.0].map(|x| none.at(x)), [0.0, 0.25, 1.0, 1.0]);
        let both = Easing::parse("steps(3, jump-both)").unwrap();
        assert_eq!([0.0, 0.5, 1.0].map(|x| both.at(x)), [0.25, 0.5, 1.0]);
        assert_eq!(Easing::parse("step-end"), Some(Easing::Steps(1, Jump::End)));
    }

    #[test]
    fn linear_points_spread_and_interpolate() {
        let points = Easing::parse("linear(0, 0.25 25%, 1)").unwrap();
        assert!(close(points.at(0.125), 0.125) && close(points.at(0.625), 0.625));
        let even = Easing::parse("linear(0, 0.9, 1)").unwrap();
        assert!(close(even.at(0.25), 0.45) && close(even.at(0.75), 0.95));
    }

    #[test]
    fn timing_follows_web_animations() {
        let timing = Timing { duration: 1000.0, delay: 200.0, iterations: 2.0, direction: Direction::Alternate, fill: Fill::None, easing: Easing::Linear };
        assert_eq!(timing.progress(100.0), None, "before its delay, not filling backwards");
        assert!(close(timing.progress(450.0).unwrap(), 0.25));
        assert!(close(timing.progress(1450.0).unwrap(), 0.75), "the second iteration runs backwards");
        assert_eq!(timing.progress(2200.0), None, "over, not filling forwards");
        let held = Timing { fill: Fill::Both, ..timing.clone() };
        assert!(close(held.progress(0.0).unwrap(), 0.0));
        assert!(close(held.progress(5000.0).unwrap(), 0.0), "an even count of alternate iterations ends where it started");
        let once = Timing { iterations: 1.0, direction: Direction::Normal, fill: Fill::Forwards, ..timing.clone() };
        assert!(close(once.progress(1200.0).unwrap(), 1.0), "its end holds 1, not 0");
        let reverse = Timing { direction: Direction::Reverse, fill: Fill::Both, ..once.clone() };
        assert!(close(reverse.progress(0.0).unwrap(), 1.0) && close(reverse.progress(5000.0).unwrap(), 0.0));
        let endless = Timing { iterations: f64::INFINITY, delay: 0.0, ..once };
        assert!(close(endless.progress(1600.0).unwrap(), 0.6) && endless.end().is_infinite());
        let eased = Timing::once(200.0, 0.0, Easing::parse("ease-out").unwrap(), Fill::None);
        assert!(close(eased.progress(100.0).unwrap(), 0.6847));
        let instant = Timing::once(0.0, 0.0, Easing::Linear, Fill::Forwards);
        assert!(close(instant.progress(0.0).unwrap(), 1.0));
    }

    #[test]
    fn colours_mix_premultiplied() {
        // From transparent to red: red, half as opaque, not a dark red.
        assert_eq!(mix_colour(0x00000000, 0xffff0000, 0.5), 0x80ff0000);
        assert_eq!(mix_colour(0xff000000, 0xffffffff, 0.5), 0xff808080);
        let look = Look::parse("style.background", "#ff0000ff", [0.0; 4]).unwrap();
        assert_eq!(look.lerp(&Look::parse("style.background", "", [0.0; 4]).unwrap(), 0.25).text(), "#bf0000ff");
    }

    #[test]
    fn keyframes_fill_in_what_they_leave_out() {
        // `@keyframes toast-in { from { opacity: 0; translate: 0 24px } }`: to the element's own.
        let track = Track::new("style.opacity", vec![Keyframe { at: 0.0, look: Some("0".into()), easing: Some(Easing::Linear) }]);
        assert_eq!(track.frames.len(), 2);
        assert_eq!(track.at(0.25, &Look::Number(1.0), [0.0; 4]), Look::Number(0.25));
        // A transform from its keyframe to the element's own (none: identity about its middle).
        let transform = Track::new("style.transform", vec![Keyframe { at: 0.0, look: Some("0 24 1 1 0 50 20".into()), easing: None }]);
        let under = Look::parse("style.transform", "", [0.0, 0.0, 100.0, 40.0]).unwrap();
        assert_eq!(transform.at(0.5, &under, [0.0, 0.0, 100.0, 40.0]).text(), "0 12 1 1 0 50 20");
        // Each segment eased by its own keyframe's function.
        let stepped = Track::new("style.opacity", vec![Keyframe { at: 0.0, look: Some("0".into()), easing: Some(Easing::Steps(2, Jump::End)) }, Keyframe { at: 1.0, look: Some("1".into()), easing: None }]);
        assert_eq!(stepped.at(0.4, &Look::Number(1.0), [0.0; 4]), Look::Number(0.0));
        assert_eq!(stepped.at(0.6, &Look::Number(1.0), [0.0; 4]), Look::Number(0.5));
    }

    #[test]
    fn a_transition_starts_at_the_next_frame_and_ends_on_the_views_own() {
        let mut motion = Motion::default();
        let own = std::cell::RefCell::new(Some("#ff0000ff".to_string()));
        let under = |_: u64, _: &str| (own.borrow().clone(), [0.0, 0.0, 10.0, 10.0]);
        motion.clock = 1000.0;
        let track = Track::new("style.background", vec![Keyframe { at: 0.0, look: Some("#ffff0000".into()), easing: None }, Keyframe { at: 1.0, look: Some("#ff0000ff".into()), easing: None }]);
        motion.play(7, Animation::new(Kind::Transition("style.background".into()), Timing::once(100.0, 0.0, Easing::Linear, Fill::Backwards), vec![track]));
        assert!(motion.drives(7, "style.background") && motion.moving());
        // A render shows its start; the next frame starts it.
        assert_eq!(motion.frame(1005.0, false, &under).sets, vec![(7, "style.background".into(), "#ffff0000".into())]);
        assert!(motion.frame(1016.0, true, &under).sets.is_empty(), "started at this frame: still its start");
        let half = motion.frame(1066.0, true, &under);
        assert_eq!(half.sets, vec![(7, "style.background".into(), "#ff800080".into())]);
        let done = motion.frame(1120.0, true, &under);
        assert_eq!(done.sets, vec![(7, "style.background".into(), "#ff0000ff".into())]);
        assert_eq!(done.events, vec![(7, "transitionend", "style.background".into())]);
        assert!(!motion.drives(7, "style.background") && !motion.moving());
    }

    #[test]
    fn an_out_transition_holds_its_end_and_says_so() {
        let mut motion = Motion::default();
        let under = |_: u64, _: &str| (None, [0.0, 0.0, 10.0, 10.0]);
        let track = Track::new("style.opacity", vec![Keyframe { at: 0.0, look: Some("0".into()), easing: None }]);
        let timing = Timing { direction: Direction::Reverse, ..Timing::once(200.0, 0.0, Easing::Linear, Fill::Forwards) };
        motion.play(3, Animation::new(Kind::Out(42), timing, vec![track]));
        motion.frame(0.0, true, &under);
        assert_eq!(motion.frame(50.0, true, &under).sets, vec![(3, "style.opacity".into(), "0.75".into())]);
        let over = motion.frame(250.0, true, &under);
        assert_eq!(over.sets, vec![(3, "style.opacity".into(), "0".into())]);
        assert_eq!(over.ended, vec![42]);
        assert!(motion.drives(3, "style.opacity") && !motion.moving(), "held hidden until its part goes");
        assert_eq!(motion.forget(3), vec![42]);
    }

    #[test]
    fn a_glide_plays_from_where_it_was_over_its_own_transform() {
        let mut motion = Motion::default();
        let under = |_: u64, _: &str| (Some("0 0 1 1 0 50 10".to_string()), [0.0, 0.0, 100.0, 20.0]);
        motion.play(5, Animation::new(Kind::Glide([0.0, -40.0, 1.0, 1.0]), Timing::once(250.0, 0.0, Easing::Linear, Fill::Backwards), vec![]));
        assert_eq!(motion.frame(0.0, false, &under).sets, vec![(5, "style.transform".into(), "0 -40 1 1 0 50 10".into())]);
        motion.frame(0.0, true, &under);
        assert_eq!(motion.frame(125.0, true, &under).sets, vec![(5, "style.transform".into(), "0 -20 1 1 0 50 10".into())]);
        assert_eq!(motion.frame(300.0, true, &under).sets, vec![(5, "style.transform".into(), "0 0 1 1 0 50 10".into())]);
        assert!(!motion.drives(5, "style.transform"));
    }

    #[test]
    fn endless_animations_keep_frames_coming_and_pause() {
        let mut motion = Motion::default();
        let under = |_: u64, _: &str| (None, [0.0; 4]);
        let pulse = || {
            let track = Track::new("style.shadow", vec![Keyframe { at: 0.0, look: Some("0 0 0 0 #ff336699".into()), easing: None }, Keyframe { at: 1.0, look: Some("0 0 0 8 #00000000".into()), easing: None }]);
            Animation::new(Kind::Css("pulse".into(), 0), Timing { iterations: f64::INFINITY, ..Timing::once(1600.0, 0.0, Easing::Linear, Fill::None) }, vec![track])
        };
        motion.declare(1, vec![pulse()]);
        motion.frame(0.0, true, &under);
        assert_eq!(motion.frame(800.0, true, &under).sets, vec![(1, "style.shadow".into(), "0 0 0 4 #80336699".into())]);
        assert_eq!(motion.frame(2400.0, true, &under).sets.len(), 0, "half way through the second iteration: as the first's half");
        assert!(motion.moving());
        // Declared again unchanged: it keeps its start.
        motion.declare(1, vec![pulse()]);
        assert_eq!(motion.running[&1][0].start, Some(0.0));
        let mut paused = pulse();
        paused.paused_at = Some(0.0);
        motion.declare(1, vec![paused]);
        assert!(!motion.moving());
        motion.declare(1, vec![]);
        assert_eq!(motion.frame(3000.0, true, &under).sets, vec![(1, "style.shadow".into(), String::new())], "back to its own (none)");
        assert!(motion.running.is_empty());
    }

    #[test]
    fn shorthands_become_longhands() {
        let longhands: HashMap<String, String> = expand("animation", "pulse 1.6s ease-out infinite").into_iter().collect();
        assert_eq!(longhands["animation-name"], "pulse");
        assert_eq!(longhands["animation-duration"], "1.6s");
        assert_eq!(longhands["animation-iteration-count"], "infinite");
        assert_eq!(longhands["animation-timing-function"], "ease-out");
        let page: HashMap<String, String> = expand("animation", "220ms cubic-bezier(0.2, 0, 0, 1) 40ms both page-enter").into_iter().collect();
        assert_eq!(page["animation-name"], "page-enter");
        assert_eq!(page["animation-delay"], "40ms");
        assert_eq!(page["animation-fill-mode"], "both");
        assert_eq!(page["animation-timing-function"], "cubic-bezier(0.2, 0, 0, 1)");
        let get = |name: &str| page.get(name).cloned();
        let named = animations(&get);
        assert_eq!(named[0].timing.delay, 40.0);
        assert_eq!(named[0].timing.fill, Fill::Both);
        let transition: HashMap<String, String> = expand("transition", "background-color 120ms, box-shadow 0.2s ease-in 50ms").into_iter().collect();
        assert_eq!(transition["transition-property"], "background-color, box-shadow");
        assert_eq!(transition["transition-duration"], "120ms, 0.2s");
        assert_eq!(transition["transition-delay"], "0s, 50ms");
        let list = transitions(Some(&transition["transition-property"]), Some(&transition["transition-duration"]), Some(&transition["transition-timing-function"]), Some(&transition["transition-delay"]));
        assert_eq!(list.len(), 2);
        assert_eq!(list[1].1.delay, 50.0);
        assert_eq!(list[0].1.easing, Easing::EASE);
    }
}
