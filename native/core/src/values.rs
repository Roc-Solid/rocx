//! CSS values as a phone resolves them (D-137): lengths (px, rem, em, %, vw/vh and their small,
//! large and dynamic kin, vmin/vmax, ch, ex, pt, pc, in, cm, mm), `calc()`, `min()`, `max()` and
//! `clamp()`; colours (hex, `rgb()`, `hsl()`, `hwb()`, `oklab()`, `oklch()`, the named ones,
//! `transparent`, `currentColor`, `color-mix()`, `light-dark()`); gradients, shadows and
//! transforms. A length is in CSS px, which a phone's views take as dp.

use std::cell::RefCell;

/// What a length is resolved against: the element's font size (`em`), the root's (`rem`), and the
/// viewport (`vw`, `vh`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ctx {
    pub em: f32,
    pub rem: f32,
    pub vw: f32,
    pub vh: f32,
}

impl Default for Ctx {
    fn default() -> Ctx {
        Ctx { em: 16.0, rem: 16.0, vw: 412.0, vh: 915.0 }
    }
}

/// A `calc()`'s expression, kept when it has a percentage in it (resolved once its basis is
/// known: `calc(100% - 2rem)`), its other units already px.
#[derive(Clone, Debug, PartialEq)]
pub enum Calc {
    Px(f32),
    Percent(f32),
    Number(f32),
    Add(Box<Calc>, Box<Calc>),
    Sub(Box<Calc>, Box<Calc>),
    Mul(Box<Calc>, Box<Calc>),
    Div(Box<Calc>, Box<Calc>),
    Min(Vec<Calc>),
    Max(Vec<Calc>),
}

impl Calc {
    /// Its value, a percentage of `basis`.
    pub fn eval(&self, basis: f32) -> f32 {
        match self {
            Calc::Px(px) => *px,
            Calc::Percent(percent) => basis * percent / 100.0,
            Calc::Number(number) => *number,
            Calc::Add(a, b) => a.eval(basis) + b.eval(basis),
            Calc::Sub(a, b) => a.eval(basis) - b.eval(basis),
            Calc::Mul(a, b) => a.eval(basis) * b.eval(basis),
            Calc::Div(a, b) => {
                let by = b.eval(basis);
                if by == 0.0 { 0.0 } else { a.eval(basis) / by }
            }
            Calc::Min(items) => items.iter().map(|item| item.eval(basis)).fold(f32::INFINITY, f32::min),
            Calc::Max(items) => items.iter().map(|item| item.eval(basis)).fold(f32::NEG_INFINITY, f32::max),
        }
    }

    fn has_percent(&self) -> bool {
        match self {
            Calc::Percent(_) => true,
            Calc::Px(_) | Calc::Number(_) => false,
            Calc::Add(a, b) | Calc::Sub(a, b) | Calc::Mul(a, b) | Calc::Div(a, b) => a.has_percent() || b.has_percent(),
            Calc::Min(items) | Calc::Max(items) => items.iter().any(Calc::has_percent),
        }
    }
}

thread_local! {
    /// Every `calc()` with a percentage seen, kept once, so a layout style names one by its place
    /// (Taffy's calc handle).
    static CALCS: RefCell<Vec<Calc>> = const { RefCell::new(Vec::new()) };
}

/// A calc expression's handle (its place in `CALCS`, 1 up, shifted past Taffy's tag bits).
pub fn calc_handle(calc: &Calc) -> u64 {
    CALCS.with(|calcs| {
        let mut calcs = calcs.borrow_mut();
        let at = match calcs.iter().position(|known| known == calc) {
            Some(at) => at,
            None => {
                calcs.push(calc.clone());
                calcs.len() - 1
            }
        };
        ((at as u64) + 1) << 3
    })
}

/// The value of the calc expression a handle names, a percentage of `basis`.
pub fn calc_value(handle: u64, basis: f32) -> f32 {
    CALCS.with(|calcs| calcs.borrow().get(((handle >> 3) as usize).wrapping_sub(1)).map(|calc| calc.eval(basis)).unwrap_or(0.0))
}

/// A length, a percentage, a calc with one, or a keyword.
#[derive(Clone, Debug, PartialEq)]
pub enum Length {
    Px(f32),
    Percent(f32),
    Calc(Calc),
    Auto,
    /// `min-content`, `max-content`, `fit-content`, `none`, `normal`…
    Keyword(String),
}

impl Length {
    /// In px, a percentage of `basis`.
    pub fn px(&self, basis: f32) -> Option<f32> {
        match self {
            Length::Px(px) => Some(*px),
            Length::Percent(percent) => Some(basis * percent / 100.0),
            Length::Calc(calc) => Some(calc.eval(basis)),
            _ => None,
        }
    }

    /// In px, when it needs no basis.
    pub fn absolute(&self) -> Option<f32> {
        match self {
            Length::Px(px) => Some(*px),
            _ => None,
        }
    }
}

/// A length (`12px`, `1.5rem`, `50%`, `calc(100% - 2rem)`, `auto`), resolved as far as `ctx` goes.
pub fn length(value: &str, ctx: Ctx) -> Option<Length> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let lower = value.to_ascii_lowercase();
    match lower.as_str() {
        "auto" => return Some(Length::Auto),
        "min-content" | "max-content" | "fit-content" | "none" | "normal" | "stretch" | "-webkit-fill-available" => return Some(Length::Keyword(lower)),
        _ => {}
    }
    let mut parser = Parser { tokens: tokens(&lower), at: 0, ctx };
    let calc = parser.sum()?;
    if parser.at != parser.tokens.len() {
        return None;
    }
    Some(match calc {
        Calc::Px(px) => Length::Px(px),
        Calc::Number(n) if n == 0.0 => Length::Px(0.0),
        Calc::Number(_) => return None,
        Calc::Percent(percent) => Length::Percent(percent),
        calc if !calc.has_percent() => Length::Px(calc.eval(0.0)),
        calc => Length::Calc(calc),
    })
}

/// A length in px that needs no basis (a percentage of none is none).
pub fn px(value: &str, ctx: Ctx) -> Option<f32> {
    length(value, ctx)?.absolute()
}

/// A plain number (`1.5`, `calc(2 * 3)`), as `opacity`, `flex-grow` and `line-height` have.
pub fn number(value: &str) -> Option<f32> {
    let value = value.trim();
    if let Ok(number) = value.parse::<f32>() {
        return Some(number);
    }
    let mut parser = Parser { tokens: tokens(&value.to_ascii_lowercase()), at: 0, ctx: Ctx::default() };
    match parser.sum()? {
        Calc::Number(number) if parser.at == parser.tokens.len() => Some(number),
        calc if parser.at == parser.tokens.len() && !calc.has_percent() && !matches!(calc, Calc::Px(_)) => Some(calc.eval(0.0)),
        _ => None,
    }
}

/// An angle in degrees (`45deg`, `0.25turn`, `1rad`, `100grad`; a bare 0).
pub fn angle(value: &str) -> Option<f32> {
    let value = value.trim().to_ascii_lowercase();
    let at = |suffix: &str| value.strip_suffix(suffix).and_then(|n| n.trim().parse::<f32>().ok());
    at("deg").or_else(|| at("grad").map(|n| n * 0.9)).or_else(|| at("rad").map(|n| n.to_degrees())).or_else(|| at("turn").map(|n| n * 360.0)).or_else(|| (value == "0").then_some(0.0))
}

#[derive(Clone, Debug, PartialEq)]
enum Token {
    Number(f32, String),
    Op(char),
    Open(String),
    Close,
    Comma,
}

fn tokens(text: &str) -> Vec<Token> {
    let mut out = Vec::new();
    let chars: Vec<char> = text.chars().collect();
    let mut at = 0;
    while at < chars.len() {
        let c = chars[at];
        if c.is_whitespace() {
            at += 1;
            continue;
        }
        let after_value = matches!(out.last(), Some(Token::Number(..)) | Some(Token::Close));
        let starts_number = c.is_ascii_digit() || (c == '.' && chars.get(at + 1).is_some_and(|n| n.is_ascii_digit())) || ((c == '-' || c == '+') && !after_value && chars.get(at + 1).is_some_and(|n| n.is_ascii_digit() || *n == '.'));
        if starts_number {
            let start = at;
            at += 1;
            while at < chars.len() && (chars[at].is_ascii_digit() || chars[at] == '.' || ((chars[at] == 'e' || chars[at] == 'E') && chars.get(at + 1).is_some_and(|n| n.is_ascii_digit() || *n == '-'))) {
                if chars[at] == 'e' || chars[at] == 'E' {
                    at += 1;
                }
                at += 1;
            }
            let number: String = chars[start..at].iter().collect();
            let unit_start = at;
            while at < chars.len() && (chars[at].is_ascii_alphabetic() || chars[at] == '%') {
                at += 1;
            }
            let unit: String = chars[unit_start..at].iter().collect();
            out.push(Token::Number(number.parse().unwrap_or(0.0), unit));
            continue;
        }
        if c.is_ascii_alphabetic() || (c == '-' && chars.get(at + 1).is_some_and(|n| n.is_ascii_alphabetic())) {
            let start = at;
            while at < chars.len() && (chars[at].is_ascii_alphanumeric() || chars[at] == '-') {
                at += 1;
            }
            let name: String = chars[start..at].iter().collect();
            if chars.get(at) == Some(&'(') {
                at += 1;
                out.push(Token::Open(name));
            } else {
                // A bare word in a calc (`infinity`, `pi`, `e`).
                let value = match name.as_str() {
                    "infinity" => f32::MAX / 4.0,
                    "-infinity" => -f32::MAX / 4.0,
                    "pi" => std::f32::consts::PI,
                    "e" => std::f32::consts::E,
                    _ => return vec![Token::Op('?')],
                };
                out.push(Token::Number(value, String::new()));
            }
            continue;
        }
        match c {
            '(' => out.push(Token::Open(String::new())),
            ')' => out.push(Token::Close),
            ',' => out.push(Token::Comma),
            '+' | '-' | '*' | '/' => out.push(Token::Op(c)),
            _ => return vec![Token::Op('?')],
        }
        at += 1;
    }
    out
}

struct Parser {
    tokens: Vec<Token>,
    at: usize,
    ctx: Ctx,
}

impl Parser {
    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.at)
    }

    fn sum(&mut self) -> Option<Calc> {
        let mut left = self.product()?;
        while let Some(Token::Op(op @ ('+' | '-'))) = self.peek().cloned() {
            self.at += 1;
            let right = self.product()?;
            left = fold(if op == '+' { Calc::Add(Box::new(left), Box::new(right)) } else { Calc::Sub(Box::new(left), Box::new(right)) });
        }
        Some(left)
    }

    fn product(&mut self) -> Option<Calc> {
        let mut left = self.unit()?;
        while let Some(Token::Op(op @ ('*' | '/'))) = self.peek().cloned() {
            self.at += 1;
            let right = self.unit()?;
            left = fold(if op == '*' { Calc::Mul(Box::new(left), Box::new(right)) } else { Calc::Div(Box::new(left), Box::new(right)) });
        }
        Some(left)
    }

    fn unit(&mut self) -> Option<Calc> {
        let token = self.peek()?.clone();
        self.at += 1;
        match token {
            Token::Number(n, unit) => Some(match unit.as_str() {
                "" => Calc::Number(n),
                "%" => Calc::Percent(n),
                unit => Calc::Px(unit_px(n, unit, self.ctx)?),
            }),
            Token::Open(name) => {
                let mut args = vec![self.sum()?];
                while self.peek() == Some(&Token::Comma) {
                    self.at += 1;
                    args.push(self.sum()?);
                }
                if self.peek() != Some(&Token::Close) {
                    return None;
                }
                self.at += 1;
                match (name.as_str(), args.len()) {
                    ("" | "calc", 1) => args.pop(),
                    ("min", _) => Some(fold(Calc::Min(args))),
                    ("max", _) => Some(fold(Calc::Max(args))),
                    ("clamp", 3) => {
                        let max = args.pop()?;
                        let value = args.pop()?;
                        let min = args.pop()?;
                        Some(fold(Calc::Max(vec![min, fold(Calc::Min(vec![value, max]))])))
                    }
                    _ => None,
                }
            }
            _ => None,
        }
    }
}

/// What can be worked out now, worked out (`2 * 3px` is `6px`).
fn fold(calc: Calc) -> Calc {
    let plain = |calc: &Calc| !calc.has_percent();
    match &calc {
        Calc::Add(a, b) | Calc::Sub(a, b) if plain(a) && plain(b) => {
            let px = matches!(**a, Calc::Px(_)) || matches!(**b, Calc::Px(_));
            let value = calc.eval(0.0);
            if px { Calc::Px(value) } else { Calc::Number(value) }
        }
        Calc::Mul(a, b) | Calc::Div(a, b) if plain(a) && plain(b) => {
            let px = matches!(**a, Calc::Px(_)) || matches!(**b, Calc::Px(_));
            let value = calc.eval(0.0);
            if px { Calc::Px(value) } else { Calc::Number(value) }
        }
        Calc::Mul(a, b) => match (&**a, &**b) {
            (Calc::Number(n), Calc::Percent(p)) | (Calc::Percent(p), Calc::Number(n)) => Calc::Percent(n * p),
            _ => calc,
        },
        Calc::Div(a, b) => match (&**a, &**b) {
            (Calc::Percent(p), Calc::Number(n)) if *n != 0.0 => Calc::Percent(p / n),
            _ => calc,
        },
        Calc::Min(items) | Calc::Max(items) if items.iter().all(plain) => {
            let px = items.iter().any(|item| matches!(item, Calc::Px(_)));
            let value = calc.eval(0.0);
            if px { Calc::Px(value) } else { Calc::Number(value) }
        }
        _ => calc,
    }
}

/// A number in a unit, in px.
fn unit_px(n: f32, unit: &str, ctx: Ctx) -> Option<f32> {
    Some(match unit {
        "px" => n,
        "rem" => n * ctx.rem,
        "em" => n * ctx.em,
        // A font's x-height and its zero's width: about half its size, as a browser falls back to.
        "ex" | "ch" => n * ctx.em * 0.5,
        "cap" => n * ctx.em * 0.7,
        "lh" => n * ctx.em * 1.2,
        "rlh" => n * ctx.rem * 1.2,
        "vw" | "svw" | "lvw" | "dvw" | "vi" | "svi" | "lvi" | "dvi" | "cqw" | "cqi" => n * ctx.vw / 100.0,
        "vh" | "svh" | "lvh" | "dvh" | "vb" | "svb" | "lvb" | "dvb" | "cqh" | "cqb" => n * ctx.vh / 100.0,
        "vmin" | "svmin" | "lvmin" | "dvmin" | "cqmin" => n * ctx.vw.min(ctx.vh) / 100.0,
        "vmax" | "svmax" | "lvmax" | "dvmax" | "cqmax" => n * ctx.vw.max(ctx.vh) / 100.0,
        "pt" => n * 4.0 / 3.0,
        "pc" => n * 16.0,
        "in" => n * 96.0,
        "cm" => n * 96.0 / 2.54,
        "mm" => n * 96.0 / 25.4,
        "q" => n * 96.0 / 101.6,
        _ => return None,
    })
}

/// Splits a value at its top-level separators (`sep`, or whitespace), keeping what is in
/// parentheses and quotes whole: `1px solid rgb(0, 0, 0)` is three parts.
pub fn split(value: &str, sep: Option<char>) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    let mut current = String::new();
    for c in value.chars() {
        if let Some(q) = quote {
            current.push(c);
            if c == q {
                quote = None;
            }
            continue;
        }
        match c {
            '"' | '\'' => {
                quote = Some(c);
                current.push(c);
            }
            '(' => {
                depth += 1;
                current.push(c);
            }
            ')' => {
                depth -= 1;
                current.push(c);
            }
            c if depth == 0 && (sep == Some(c) || (sep.is_none() && c.is_whitespace())) => {
                if !current.trim().is_empty() || sep.is_some() {
                    out.push(current.trim().to_string());
                }
                current.clear();
            }
            c => current.push(c),
        }
    }
    if !current.trim().is_empty() {
        out.push(current.trim().to_string());
    }
    out
}

/// A function's arguments (`rgb(1 2 3 / 50%)`'s `1 2 3 / 50%`), its name lowercase.
fn function(value: &str) -> Option<(String, &str)> {
    let open = value.find('(')?;
    let inner = value[open + 1..].trim_end().strip_suffix(')')?;
    Some((value[..open].trim().to_ascii_lowercase(), inner))
}

// ---- Colours ----

/// A colour as `0xAARRGGBB`.
pub type Argb = u32;

pub fn argb(color: Argb) -> String {
    format!("#{color:08x}")
}

/// A colour (`currentColor` is `current`), or none for what isn't one.
pub fn colour(value: &str, current: Argb) -> Option<Argb> {
    let value = value.trim();
    let lower = value.to_ascii_lowercase();
    if lower == "currentcolor" {
        return Some(current);
    }
    if lower == "transparent" {
        return Some(0);
    }
    if let Some(hex) = lower.strip_prefix('#') {
        let digit = |c: u8| (c as char).to_digit(16);
        let bytes = hex.as_bytes();
        let parsed: Option<Vec<u32>> = bytes.iter().map(|&c| digit(c)).collect();
        let d = parsed?;
        let (r, g, b, a) = match d.len() {
            3 => (d[0] * 17, d[1] * 17, d[2] * 17, 255),
            4 => (d[0] * 17, d[1] * 17, d[2] * 17, d[3] * 17),
            6 => (d[0] * 16 + d[1], d[2] * 16 + d[3], d[4] * 16 + d[5], 255),
            8 => (d[0] * 16 + d[1], d[2] * 16 + d[3], d[4] * 16 + d[5], d[6] * 16 + d[7]),
            _ => return None,
        };
        return Some((a << 24) | (r << 16) | (g << 8) | b);
    }
    if let Some((name, inner)) = function(&lower) {
        return colour_function(&name, inner, current);
    }
    named(&lower).map(|rgb| 0xff00_0000 | rgb)
}

fn pack(r: f32, g: f32, b: f32, a: f32) -> Argb {
    let byte = |v: f32| (v.clamp(0.0, 255.0) + 0.5) as u32;
    (byte(a * 255.0) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b)
}

fn channels(color: Argb) -> [f32; 4] {
    [((color >> 16) & 0xff) as f32, ((color >> 8) & 0xff) as f32, (color & 0xff) as f32, ((color >> 24) & 0xff) as f32 / 255.0]
}

/// A function's arguments, commas or spaces, its alpha after `/` (or a fourth with commas).
fn colour_args(inner: &str) -> (Vec<String>, Option<String>) {
    let (main, alpha) = match inner.split_once('/') {
        Some((main, alpha)) => (main, Some(alpha.trim().to_string())),
        None => (inner, None),
    };
    let mut parts: Vec<String> = main.split([',', ' ']).map(str::trim).filter(|part| !part.is_empty()).map(str::to_string).collect();
    let alpha = alpha.or_else(|| (parts.len() == 4).then(|| parts.pop()).flatten());
    (parts, alpha)
}

fn alpha_of(alpha: Option<String>) -> f32 {
    alpha.map(|alpha| if let Some(p) = alpha.strip_suffix('%') { p.trim().parse::<f32>().unwrap_or(100.0) / 100.0 } else { alpha.parse::<f32>().unwrap_or(1.0) }).unwrap_or(1.0).clamp(0.0, 1.0)
}

/// A channel: a number, or a percentage of `full`; `none` is 0.
fn channel(part: &str, full: f32) -> f32 {
    if part == "none" {
        return 0.0;
    }
    match part.strip_suffix('%') {
        Some(p) => p.trim().parse::<f32>().unwrap_or(0.0) * full / 100.0,
        None => angle(part).filter(|_| part.ends_with("deg") || part.ends_with("turn") || part.ends_with("rad")).or_else(|| part.parse::<f32>().ok()).unwrap_or(0.0),
    }
}

fn colour_function(name: &str, inner: &str, current: Argb) -> Option<Argb> {
    match name {
        "rgb" | "rgba" => {
            let (parts, alpha) = colour_args(inner);
            if parts.len() < 3 {
                return None;
            }
            Some(pack(channel(&parts[0], 255.0), channel(&parts[1], 255.0), channel(&parts[2], 255.0), alpha_of(alpha)))
        }
        "hsl" | "hsla" => {
            let (parts, alpha) = colour_args(inner);
            if parts.len() < 3 {
                return None;
            }
            let h = channel(&parts[0], 360.0);
            let s = channel(&parts[1].trim_end_matches('%').to_string(), 100.0) / 100.0;
            let l = channel(&parts[2].trim_end_matches('%').to_string(), 100.0) / 100.0;
            let [r, g, b] = hsl_rgb(h, s, l);
            Some(pack(r * 255.0, g * 255.0, b * 255.0, alpha_of(alpha)))
        }
        "hwb" => {
            let (parts, alpha) = colour_args(inner);
            if parts.len() < 3 {
                return None;
            }
            let h = channel(&parts[0], 360.0);
            let (mut w, mut bl) = (channel(&parts[1].trim_end_matches('%').to_string(), 100.0) / 100.0, channel(&parts[2].trim_end_matches('%').to_string(), 100.0) / 100.0);
            if w + bl > 1.0 {
                let sum = w + bl;
                w /= sum;
                bl /= sum;
            }
            let [r, g, b] = hsl_rgb(h, 1.0, 0.5).map(|c| c * (1.0 - w - bl) + w);
            Some(pack(r * 255.0, g * 255.0, b * 255.0, alpha_of(alpha)))
        }
        "oklab" | "oklch" => {
            let (parts, alpha) = colour_args(inner);
            if parts.len() < 3 {
                return None;
            }
            let l = if parts[0].ends_with('%') { channel(&parts[0], 1.0) } else { channel(&parts[0], 1.0) };
            let (a, b) = if name == "oklab" {
                (channel(&parts[1], 0.4), channel(&parts[2], 0.4))
            } else {
                let c = channel(&parts[1], 0.4);
                let h = channel(&parts[2], 360.0).to_radians();
                (c * h.cos(), c * h.sin())
            };
            let [r, g, b] = oklab_srgb([l, a, b]);
            Some(pack(r * 255.0, g * 255.0, b * 255.0, alpha_of(alpha)))
        }
        "light-dark" => {
            let parts = split(inner, Some(','));
            colour(parts.first()?, current)
        }
        "color-mix" => colour_mix(inner, current),
        "color" => {
            // `color(srgb r g b / a)`: srgb and display-p3 as sRGB.
            let (parts, alpha) = colour_args(inner);
            if parts.len() < 4 {
                return None;
            }
            Some(pack(channel(&parts[1], 1.0) * 255.0, channel(&parts[2], 1.0) * 255.0, channel(&parts[3], 1.0) * 255.0, alpha_of(alpha)))
        }
        _ => None,
    }
}

fn hsl_rgb(h: f32, s: f32, l: f32) -> [f32; 3] {
    let h = h.rem_euclid(360.0);
    let f = |n: f32| {
        let k = (n + h / 30.0) % 12.0;
        let a = s * l.min(1.0 - l);
        l - a * (-1.0f32).max((k - 3.0).min((9.0 - k).min(1.0)))
    };
    [f(0.0), f(8.0), f(4.0)]
}

fn to_linear(c: f32) -> f32 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn from_linear(c: f32) -> f32 {
    if c <= 0.0031308 { 12.92 * c } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

fn oklab_srgb([l, a, b]: [f32; 3]) -> [f32; 3] {
    let l_ = l + 0.396_337_78 * a + 0.215_803_76 * b;
    let m_ = l - 0.105_561_346 * a - 0.063_854_17 * b;
    let s_ = l - 0.089_484_18 * a - 1.291_485_5 * b;
    let (l3, m3, s3) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_);
    let r = 4.076_741_7 * l3 - 3.307_711_6 * m3 + 0.230_969_94 * s3;
    let g = -1.268_438 * l3 + 2.609_757_4 * m3 - 0.341_319_38 * s3;
    let bl = -0.004_196_086_3 * l3 - 0.703_418_6 * m3 + 1.707_614_7 * s3;
    [from_linear(r).clamp(0.0, 1.0), from_linear(g).clamp(0.0, 1.0), from_linear(bl).clamp(0.0, 1.0)]
}

fn srgb_oklab([r, g, b]: [f32; 3]) -> [f32; 3] {
    let (r, g, b) = (to_linear(r), to_linear(g), to_linear(b));
    let l = (0.412_221_47 * r + 0.536_332_55 * g + 0.051_445_995 * b).cbrt();
    let m = (0.211_903_5 * r + 0.680_699_5 * g + 0.107_396_96 * b).cbrt();
    let s = (0.088_302_46 * r + 0.281_718_85 * g + 0.629_978_7 * b).cbrt();
    [0.210_454_26 * l + 0.793_617_8 * m - 0.004_072_047 * s, 1.977_998_5 * l - 2.428_592_2 * m + 0.450_593_7 * s, 0.025_904_037 * l + 0.782_771_77 * m - 0.808_675_77 * s]
}

/// `color-mix(in <space>, a [p], b [q])`: mixed in sRGB, or in Oklab for the Ok spaces (and the
/// others, as an approximation), alpha premultiplied.
fn colour_mix(inner: &str, current: Argb) -> Option<Argb> {
    let parts = split(inner, Some(','));
    if parts.len() != 3 {
        return None;
    }
    let space = parts[0].trim().strip_prefix("in")?.trim().to_string();
    let item = |part: &str| -> Option<(Argb, Option<f32>)> {
        let words = split(part, None);
        let (mut colour_text, mut percent) = (Vec::new(), None);
        for word in words {
            match word.strip_suffix('%').and_then(|p| p.trim().parse::<f32>().ok()) {
                Some(p) if !word.contains('(') => percent = Some(p),
                // A worked-out share (`calc(var(--strength) * 100%)`, a heatmap's cells, D-141).
                _ if word.to_ascii_lowercase().starts_with("calc(") && matches!(length(&word, Ctx::default()), Some(Length::Percent(_))) => {
                    if let Some(Length::Percent(p)) = length(&word, Ctx::default()) {
                        percent = Some(p.clamp(0.0, 100.0));
                    }
                }
                _ => colour_text.push(word),
            }
        }
        Some((colour(&colour_text.join(" "), current)?, percent))
    };
    let (a, pa) = item(&parts[1])?;
    let (b, pb) = item(&parts[2])?;
    let (pa, pb) = match (pa, pb) {
        (None, None) => (50.0, 50.0),
        (Some(p), None) => (p, 100.0 - p),
        (None, Some(q)) => (100.0 - q, q),
        (Some(p), Some(q)) => (p, q),
    };
    let sum = pa + pb;
    if sum <= 0.0 {
        return Some(0);
    }
    let (wa, wb, scale) = (pa / sum, pb / sum, (sum / 100.0).min(1.0));
    let [ra, ga, ba, aa] = channels(a);
    let [rb, gb, bb, ab] = channels(b);
    let alpha = aa * wa + ab * wb;
    if alpha <= 0.0 {
        return Some(0);
    }
    let rgb = if space.starts_with("srgb") || space == "hsl" || space == "hwb" {
        [(ra * aa * wa + rb * ab * wb) / alpha, (ga * aa * wa + gb * ab * wb) / alpha, (ba * aa * wa + bb * ab * wb) / alpha]
    } else {
        let la = srgb_oklab([ra / 255.0, ga / 255.0, ba / 255.0]);
        let lb = srgb_oklab([rb / 255.0, gb / 255.0, bb / 255.0]);
        let mixed = [0, 1, 2].map(|i| (la[i] * aa * wa + lb[i] * ab * wb) / alpha);
        oklab_srgb(mixed).map(|c| c * 255.0)
    };
    Some(pack(rgb[0], rgb[1], rgb[2], alpha * scale))
}

/// CSS's named colours, as `0xRRGGBB`.
fn named(name: &str) -> Option<u32> {
    const NAMES: &str = "aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32 canvas ffffff canvastext 000000 buttonface efefef buttontext 000000 field ffffff fieldtext 000000 graytext 6d6d6d linktext 0000ee highlight 3390ff highlighttext ffffff";
    let mut words = NAMES.split(' ');
    while let (Some(known), Some(hex)) = (words.next(), words.next()) {
        if known == name {
            return u32::from_str_radix(hex, 16).ok();
        }
    }
    None
}

// ---- Gradients, shadows, transforms ----

/// A gradient as the applier draws it: `linear <deg>`, `radial`, or `conic <deg>`, then each stop
/// as `#AARRGGBB@<0..1>`, its position worked out as CSS does for one not given.
pub fn gradient(value: &str, current: Argb, ctx: Ctx) -> Option<String> {
    let (name, inner) = function(value.trim())?;
    let name = name.trim_start_matches("-webkit-").trim_start_matches("repeating-").to_string();
    let parts = split(inner, Some(','));
    let mut stops: Vec<(Argb, Option<f32>)> = Vec::new();
    let mut head = String::new();
    let mut angle_deg = 180.0;
    for (at, part) in parts.iter().enumerate() {
        let words = split(part, None);
        let first_colour = words.first().and_then(|word| colour(word, current)).or_else(|| words.last().and_then(|word| colour(word, current)).filter(|_| words.len() > 1 && at > 0));
        if at == 0 && first_colour.is_none() {
            head = part.clone();
            continue;
        }
        let Some(color) = first_colour else { continue };
        let positions: Vec<f32> = words[1..].iter().filter_map(|word| stop_position(word, ctx)).collect();
        if positions.is_empty() {
            stops.push((color, None));
        }
        for position in positions {
            stops.push((color, Some(position)));
        }
    }
    if stops.is_empty() {
        return None;
    }
    if stops.len() == 1 {
        stops.push(stops[0]);
    }
    if name == "linear-gradient" && !head.is_empty() {
        let head = head.trim().to_ascii_lowercase();
        angle_deg = if let Some(side) = head.strip_prefix("to ") {
            let has = |word: &str| side.split_whitespace().any(|each| each == word);
            match (has("top"), has("bottom"), has("left"), has("right")) {
                (true, _, true, _) => 315.0,
                (true, _, _, true) => 45.0,
                (_, true, true, _) => 225.0,
                (_, true, _, true) => 135.0,
                (true, _, _, _) => 0.0,
                (_, true, _, _) => 180.0,
                (_, _, true, _) => 270.0,
                _ => 90.0,
            }
        } else {
            angle(&head).unwrap_or(180.0)
        };
    } else if name == "conic-gradient" {
        angle_deg = head.trim().strip_prefix("from").and_then(|rest| angle(rest.split(" at ").next().unwrap_or(""))).unwrap_or(0.0);
    }
    // Positions not given: the first 0, the last 1, the rest spread between those around them.
    let count = stops.len();
    if stops[0].1.is_none() {
        stops[0].1 = Some(0.0);
    }
    if stops[count - 1].1.is_none() {
        stops[count - 1].1 = Some(1.0);
    }
    let mut at = 0;
    while at < count {
        if stops[at].1.is_some() {
            at += 1;
            continue;
        }
        let start = at - 1;
        let mut end = at;
        while stops[end].1.is_none() {
            end += 1;
        }
        let (from, to) = (stops[start].1.unwrap_or(0.0), stops[end].1.unwrap_or(1.0));
        for (step, stop) in stops.iter_mut().enumerate().take(end).skip(at) {
            stop.1 = Some(from + (to - from) * (step - start) as f32 / (end - start) as f32);
        }
        at = end;
    }
    let mut last = 0.0f32;
    let mut out = match name.as_str() {
        "linear-gradient" => format!("linear {angle_deg}"),
        "radial-gradient" => format!("radial {}", radial_geometry(&head, ctx)),
        "conic-gradient" => format!("conic {angle_deg}"),
        _ => return None,
    };
    for (color, position) in stops {
        let position = position.unwrap_or(last).max(last);
        last = position;
        out.push_str(&format!(" {}@{position:.4}", argb(color)));
    }
    Some(out)
}

/// A radial gradient's centre and radii: `cx cy rx ry`, the centre as shares of the box, each
/// radius `<n>%` (of the box's side), `<n>px`, or a keyword (`fc` farthest-corner, `fs`
/// farthest-side, `cc` closest-corner, `cs` closest-side); a circle's `ry` is `=`.
fn radial_geometry(head: &str, ctx: Ctx) -> String {
    let head = head.trim().to_ascii_lowercase();
    let (shape, position) = match head.split_once("at ") {
        Some((shape, position)) => (shape.trim().to_string(), position.trim().to_string()),
        None if head.starts_with("at") => (String::new(), head.trim_start_matches("at").trim().to_string()),
        None => (head.clone(), String::new()),
    };
    let share = |word: &str, horizontal: bool| -> f32 {
        match word {
            "left" | "top" => 0.0,
            "right" | "bottom" => 1.0,
            "center" => 0.5,
            other => other.strip_suffix('%').and_then(|p| p.trim().parse::<f32>().ok()).map(|p| p / 100.0).unwrap_or_else(|| if horizontal { 0.5 } else { 0.5 }),
        }
    };
    let words: Vec<&str> = position.split_whitespace().collect();
    let (mut cx, mut cy) = (0.5, 0.5);
    match words.as_slice() {
        [one] => {
            if matches!(*one, "top" | "bottom") {
                cy = share(one, false);
            } else {
                cx = share(one, true);
            }
        }
        [a, b, ..] => {
            let swapped = matches!(*a, "top" | "bottom") || matches!(*b, "left" | "right");
            if swapped {
                cx = share(b, true);
                cy = share(a, false);
            } else {
                cx = share(a, true);
                cy = share(b, false);
            }
        }
        [] => {}
    }
    let circle = shape.split_whitespace().any(|w| w == "circle");
    let mut radii: Vec<String> = Vec::new();
    for word in shape.split_whitespace() {
        let keyword = match word {
            "farthest-corner" => Some("fc"),
            "farthest-side" => Some("fs"),
            "closest-corner" => Some("cc"),
            "closest-side" => Some("cs"),
            _ => None,
        };
        if let Some(keyword) = keyword {
            radii.push(keyword.to_string());
        } else if word.ends_with('%') {
            radii.push(word.to_string());
        } else if let Some(px) = px(word, ctx) {
            radii.push(format!("{px}px"));
        }
    }
    let rx = radii.first().cloned().unwrap_or_else(|| "fc".into());
    let ry = if circle || radii.len() < 2 { if circle { "=".to_string() } else { radii.first().cloned().unwrap_or_else(|| "fc".into()) } } else { radii[1].clone() };
    format!("{cx} {cy} {rx} {ry}")
}

fn stop_position(word: &str, ctx: Ctx) -> Option<f32> {
    if let Some(percent) = word.strip_suffix('%') {
        return percent.trim().parse::<f32>().ok().map(|p| p / 100.0);
    }
    // A length along a gradient: taken as a share of a 400 px line (rare in an app's CSS).
    px(word, ctx).map(|px| px / 400.0).or_else(|| angle(word).map(|deg| deg / 360.0))
}

/// The first outer shadow of a `box-shadow`: `x y blur spread #AARRGGBB`.
pub fn shadow(value: &str, current: Argb, ctx: Ctx) -> Option<String> {
    if value.trim().eq_ignore_ascii_case("none") {
        return None;
    }
    for layer in split(value, Some(',')) {
        let words = split(&layer, None);
        if words.iter().any(|word| word.eq_ignore_ascii_case("inset")) {
            continue;
        }
        let mut lengths = Vec::new();
        let mut color = 0x40000000u32 | (current & 0x00ffffff);
        for word in &words {
            match px(word, ctx) {
                Some(px) => lengths.push(px),
                None => {
                    if let Some(found) = colour(word, current) {
                        color = found;
                    }
                }
            }
        }
        if lengths.len() < 2 {
            continue;
        }
        let at = |i: usize| lengths.get(i).copied().unwrap_or(0.0);
        if color >> 24 == 0 {
            continue;
        }
        return Some(format!("{:.1} {:.1} {:.1} {:.1} {}", at(0), at(1), at(2), at(3), argb(color)));
    }
    None
}

/// The first inset shadow of a `box-shadow`, as a ring inside the box (a border drawn with a
/// shadow, `inset 0 0 0 2px`): `width #AARRGGBB`, its width the spread (or half its blur).
pub fn inset_shadow(value: &str, current: Argb, ctx: Ctx) -> Option<String> {
    for layer in split(value, Some(',')) {
        let words = split(&layer, None);
        if !words.iter().any(|word| word.eq_ignore_ascii_case("inset")) {
            continue;
        }
        let mut lengths = Vec::new();
        let mut color = 0x40000000u32 | (current & 0x00ffffff);
        for word in words.iter().filter(|word| !word.eq_ignore_ascii_case("inset")) {
            match px(word, ctx) {
                Some(px) => lengths.push(px),
                None => {
                    if let Some(found) = colour(word, current) {
                        color = found;
                    }
                }
            }
        }
        let at = |i: usize| lengths.get(i).copied().unwrap_or(0.0);
        let width = if at(3) > 0.0 { at(3) } else { at(2) / 2.0 };
        if width > 0.0 && color >> 24 != 0 {
            return Some(format!("{width:.1} {}", argb(color)));
        }
    }
    None
}

/// A transform, as the parts a view's properties can show: a translation (lengths, or
/// percentages of the box's own size), a scale and a rotation.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Transform {
    pub tx: Option<Length>,
    pub ty: Option<Length>,
    pub sx: f32,
    pub sy: f32,
    pub rotate: f32,
}

impl Transform {
    pub fn identity() -> Transform {
        Transform { tx: None, ty: None, sx: 1.0, sy: 1.0, rotate: 0.0 }
    }

    pub fn is_identity(&self) -> bool {
        self.tx.as_ref().is_none_or(|tx| tx.px(1.0) == Some(0.0)) && self.ty.as_ref().is_none_or(|ty| ty.px(1.0) == Some(0.0)) && self.sx == 1.0 && self.sy == 1.0 && self.rotate == 0.0
    }

    /// In px for a box of `w` by `h`: `tx ty sx sy degrees`.
    pub fn resolve(&self, w: f32, h: f32) -> [f32; 5] {
        let tx = self.tx.as_ref().and_then(|tx| tx.px(w)).unwrap_or(0.0);
        let ty = self.ty.as_ref().and_then(|ty| ty.px(h)).unwrap_or(0.0);
        [tx, ty, self.sx, self.sy, self.rotate]
    }

    fn add_translate(&mut self, x: Option<Length>, y: Option<Length>) {
        let add = |a: Option<Length>, b: Option<Length>| match (a, b) {
            (None, b) => b,
            (a, None) => a,
            (Some(a), Some(b)) => match (a, b) {
                (Length::Px(a), Length::Px(b)) => Some(Length::Px(a + b)),
                (Length::Percent(a), Length::Percent(b)) => Some(Length::Percent(a + b)),
                (a, b) => Some(Length::Calc(Calc::Add(Box::new(as_calc(a)), Box::new(as_calc(b))))),
            },
        };
        self.tx = add(self.tx.take(), x);
        self.ty = add(self.ty.take(), y);
    }
}

fn as_calc(length: Length) -> Calc {
    match length {
        Length::Px(px) => Calc::Px(px),
        Length::Percent(p) => Calc::Percent(p),
        Length::Calc(calc) => calc,
        _ => Calc::Px(0.0),
    }
}

/// `transform`, with `translate`, `scale` and `rotate` (the properties) after it, as CSS applies
/// them: translate, rotate, scale, then the transform's own functions.
pub fn transform(transform: Option<&str>, translate: Option<&str>, scale: Option<&str>, rotate: Option<&str>, ctx: Ctx) -> Transform {
    let mut out = Transform::identity();
    if let Some(translate) = translate.filter(|t| *t != "none") {
        let parts = split(translate, None);
        out.add_translate(parts.first().and_then(|x| length(x, ctx)), parts.get(1).and_then(|y| length(y, ctx)));
    }
    if let Some(rotate) = rotate.filter(|r| *r != "none") {
        out.rotate += angle(split(rotate, None).last().map(String::as_str).unwrap_or("")).unwrap_or(0.0);
    }
    if let Some(scale) = scale.filter(|s| *s != "none") {
        let parts: Vec<f32> = split(scale, None).iter().filter_map(|part| scale_number(part)).collect();
        if let Some(&x) = parts.first() {
            out.sx *= x;
            out.sy *= parts.get(1).copied().unwrap_or(x);
        }
    }
    let Some(transform) = transform.filter(|t| *t != "none") else { return out };
    for item in split(transform, None) {
        let Some((name, inner)) = function(&item) else { continue };
        let args = split(inner, Some(','));
        let args: Vec<String> = if args.len() == 1 { split(&args[0], None) } else { args };
        let len = |at: usize| args.get(at).and_then(|arg| length(arg, ctx));
        match name.as_str() {
            "translate" => out.add_translate(len(0), len(1)),
            "translatex" => out.add_translate(len(0), None),
            "translatey" => out.add_translate(None, len(0)),
            "translate3d" => out.add_translate(len(0), len(1)),
            "scale" | "scale3d" => {
                let x = args.first().and_then(|a| scale_number(a)).unwrap_or(1.0);
                out.sx *= x;
                out.sy *= args.get(1).and_then(|a| scale_number(a)).unwrap_or(x);
            }
            "scalex" => out.sx *= args.first().and_then(|a| scale_number(a)).unwrap_or(1.0),
            "scaley" => out.sy *= args.first().and_then(|a| scale_number(a)).unwrap_or(1.0),
            "rotate" | "rotatez" => out.rotate += args.first().and_then(|a| angle(a)).unwrap_or(0.0),
            _ => {}
        }
    }
    out
}

fn scale_number(text: &str) -> Option<f32> {
    match text.trim().strip_suffix('%') {
        Some(p) => p.trim().parse::<f32>().ok().map(|p| p / 100.0),
        None => number(text),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lengths_resolve() {
        let ctx = Ctx { em: 20.0, rem: 16.0, vw: 400.0, vh: 800.0 };
        assert_eq!(length("1.5rem", ctx), Some(Length::Px(24.0)));
        assert_eq!(length("2em", ctx), Some(Length::Px(40.0)));
        assert_eq!(length("50vw", ctx), Some(Length::Px(200.0)));
        assert_eq!(length("100svh", ctx), Some(Length::Px(800.0)));
        assert_eq!(length("25%", ctx), Some(Length::Percent(25.0)));
        assert_eq!(length("calc(1rem + 4px)", ctx), Some(Length::Px(20.0)));
        assert_eq!(length("clamp(1rem, 10vw, 2rem)", ctx), Some(Length::Px(32.0)));
        assert_eq!(length("min(560px, calc(100vw - 32px))", ctx), Some(Length::Px(368.0)));
        let Some(Length::Calc(calc)) = length("calc(100% - 2rem)", ctx) else { panic!("a calc with a percentage") };
        assert_eq!(calc.eval(300.0), 268.0);
        let Some(Length::Calc(calc)) = length("calc(3 * ((100% - 32px) / 5 + 8px))", ctx) else { panic!() };
        assert!((calc.eval(332.0) - 204.0).abs() < 0.01);
        assert_eq!(length("calc((18px - 40px) / 2 - 2px)", ctx), Some(Length::Px(-13.0)));
        assert_eq!(length("-4px", ctx), Some(Length::Px(-4.0)));
        assert_eq!(length("0", ctx), Some(Length::Px(0.0)));
        assert_eq!(length("12", ctx), None);
        assert_eq!(length("auto", ctx), Some(Length::Auto));
    }

    #[test]
    fn colours_parse() {
        assert_eq!(colour("#fff", 0), Some(0xffffffff));
        assert_eq!(colour("#11223380", 0), Some(0x80112233));
        assert_eq!(colour("rgb(255 0 0 / 50%)", 0), Some(0x80ff0000));
        assert_eq!(colour("rgba(0, 0, 255, 0.25)", 0), Some(0x400000ff));
        assert_eq!(colour("hsl(120, 100%, 50%)", 0), Some(0xff00ff00));
        assert_eq!(colour("rebeccapurple", 0), Some(0xff663399));
        assert_eq!(colour("currentColor", 0xff123456), Some(0xff123456));
        assert_eq!(colour("transparent", 0), Some(0));
        assert_eq!(colour("color-mix(in srgb, #ff0000 50%, #0000ff)", 0), Some(0xff800080));
        assert_eq!(colour("color-mix(in srgb, currentColor 12%, transparent)", 0xff000000), Some(0x1f000000));
        assert_eq!(colour("color-mix(in srgb, #ff0000 calc(0.5 * 100%), #0000ff)", 0), Some(0xff800080), "a share worked out by calc()");
        assert_eq!(colour("color-mix(in oklab, #ff0000 calc(1 * 100%), #0000ff)", 0), Some(0xffff0000));
        let white = colour("oklch(1 0 0)", 0).unwrap();
        assert!(white & 0xffffff >= 0xfefefe, "{white:x}");
        assert_eq!(colour("light-dark(#fff, #000)", 0), Some(0xffffffff));
        assert_eq!(colour("nonsense", 0), None);
    }

    #[test]
    fn gradients_shadows_transforms() {
        let ctx = Ctx::default();
        assert_eq!(gradient("linear-gradient(to right, #000, #fff)", 0, ctx).as_deref(), Some("linear 90 #ff000000@0.0000 #ffffffff@1.0000"));
        assert_eq!(gradient("linear-gradient(135deg, red 10%, blue, lime)", 0, ctx).as_deref(), Some("linear 135 #ffff0000@0.1000 #ff0000ff@0.5500 #ff00ff00@1.0000"));
        assert_eq!(shadow("0 1px 2px rgb(0 0 0 / 10%), 0 8px 24px #0003", 0, ctx).as_deref(), Some("0.0 1.0 2.0 0.0 #1a000000"));
        assert_eq!(shadow("inset 0 0 0 1px red", 0, ctx), None);
        let t = transform(Some("translate(-50%, 4px) scale(1.04) rotate(45deg)"), None, None, None, ctx);
        assert_eq!(t.resolve(200.0, 100.0), [-100.0, 4.0, 1.04, 1.04, 45.0]);
        assert!(transform(Some("none"), None, None, None, ctx).is_identity());
        assert_eq!(transform(None, Some("10px 20px"), Some("2"), None, ctx).resolve(0.0, 0.0), [10.0, 20.0, 2.0, 2.0, 0.0]);
    }

    #[test]
    fn calc_handles_name_one_expression() {
        let calc = Calc::Sub(Box::new(Calc::Percent(100.0)), Box::new(Calc::Px(10.0)));
        let handle = calc_handle(&calc);
        assert_eq!(handle & 7, 0);
        assert_eq!(calc_handle(&calc), handle);
        assert_eq!(calc_value(handle, 50.0), 40.0);
    }
}
