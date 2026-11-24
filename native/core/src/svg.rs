//! SVG on a phone: an `<svg>` is one view (kind `svg`), drawn by the applier from a list of shapes
//! this makes (`Drawing`), sent as one property (`svg`, JSON) and sent again whenever it changes.
//!
//! The host does what a renderer would rather not: shapes (`rect`, `circle`, `ellipse`, `line`,
//! `polyline`, `polygon`) become paths, a path's data is made absolute and plain (`M`, `L`, `C`,
//! `Q`, `Z`: `H`/`V` as lines, `S`/`T` with their control points reflected, arcs as cubic curves),
//! `transform`s are multiplied down the tree into one matrix a shape, and paint is resolved: a
//! presentation attribute, then the stylesheet's rules, then the `style` attribute, inherited as SVG
//! inherits it (`fill`, `stroke`, their widths, caps, joins, dashes and opacities), `currentColor` the
//! CSS `color`, a group's `opacity` multiplied into its shapes. `<text>` is drawn at its `x`/`y`
//! with its `text-anchor`, `font-size`, `font-weight`, `text-transform` and tabular digits.
//!
//! What a phone can't draw yet (gradients and patterns, `<use>`, clipping and masks, `<image>`,
//! `<foreignObject>`) warns once and is left out, as the CSS a phone doesn't do is.

use std::fmt::Write as _;

/// An affine matrix, as SVG's `matrix(a b c d e f)`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Matrix(pub [f32; 6]);

impl Matrix {
    pub const IDENTITY: Matrix = Matrix([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);

    /// `self` then `other` inside it: `other`'s coordinates are drawn through `self`.
    pub fn then(self, other: Matrix) -> Matrix {
        let [a, b, c, d, e, f] = self.0;
        let [a2, b2, c2, d2, e2, f2] = other.0;
        Matrix([a * a2 + c * b2, b * a2 + d * b2, a * c2 + c * d2, b * c2 + d * d2, a * e2 + c * f2 + e, b * e2 + d * f2 + f])
    }

    fn translate(x: f32, y: f32) -> Matrix {
        Matrix([1.0, 0.0, 0.0, 1.0, x, y])
    }

    fn scale(x: f32, y: f32) -> Matrix {
        Matrix([x, 0.0, 0.0, y, 0.0, 0.0])
    }

    fn rotate(degrees: f32) -> Matrix {
        let (sin, cos) = degrees.to_radians().sin_cos();
        Matrix([cos, sin, -sin, cos, 0.0, 0.0])
    }
}

/// A `transform` attribute's matrix: `translate`, `scale`, `rotate` (about a point too),
/// `skewX`, `skewY` and `matrix`, in order. One it can't read is the identity.
pub fn transform(text: &str) -> Matrix {
    let mut out = Matrix::IDENTITY;
    let mut rest = text.trim();
    while let Some(open) = rest.find('(') {
        let name = rest[..open].trim().trim_start_matches(',').trim();
        let Some(close) = rest[open..].find(')').map(|close| close + open) else { break };
        let args = numbers(&rest[open + 1..close]);
        let arg = |at: usize, or: f32| args.get(at).copied().unwrap_or(or);
        let step = match name {
            "translate" => Matrix::translate(arg(0, 0.0), arg(1, 0.0)),
            "scale" => Matrix::scale(arg(0, 1.0), arg(1, arg(0, 1.0))),
            "rotate" if args.len() >= 3 => Matrix::translate(args[1], args[2]).then(Matrix::rotate(args[0])).then(Matrix::translate(-args[1], -args[2])),
            "rotate" => Matrix::rotate(arg(0, 0.0)),
            "skewX" => Matrix([1.0, 0.0, arg(0, 0.0).to_radians().tan(), 1.0, 0.0, 0.0]),
            "skewY" => Matrix([1.0, arg(0, 0.0).to_radians().tan(), 0.0, 1.0, 0.0, 0.0]),
            "matrix" if args.len() == 6 => Matrix([args[0], args[1], args[2], args[3], args[4], args[5]]),
            _ => Matrix::IDENTITY,
        };
        out = out.then(step);
        rest = &rest[close + 1..];
    }
    out
}

/// The numbers in a list (`1,2 3-4.5.5e1`), as SVG writes them.
pub fn numbers(text: &str) -> Vec<f32> {
    let mut scanner = Scanner { bytes: text.as_bytes(), at: 0 };
    let mut out = Vec::new();
    while let Some(number) = scanner.number() {
        out.push(number);
    }
    out
}

struct Scanner<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Scanner<'_> {
    fn skip(&mut self) {
        while self.at < self.bytes.len() && (self.bytes[self.at].is_ascii_whitespace() || self.bytes[self.at] == b',') {
            self.at += 1;
        }
    }

    fn number(&mut self) -> Option<f32> {
        self.skip();
        let start = self.at;
        let bytes = self.bytes;
        let mut at = self.at;
        if at < bytes.len() && (bytes[at] == b'-' || bytes[at] == b'+') {
            at += 1;
        }
        let mut digits = false;
        while at < bytes.len() && bytes[at].is_ascii_digit() {
            at += 1;
            digits = true;
        }
        if at < bytes.len() && bytes[at] == b'.' {
            at += 1;
            while at < bytes.len() && bytes[at].is_ascii_digit() {
                at += 1;
                digits = true;
            }
        }
        if !digits {
            return None;
        }
        if at < bytes.len() && (bytes[at] == b'e' || bytes[at] == b'E') {
            let mut exp = at + 1;
            if exp < bytes.len() && (bytes[exp] == b'-' || bytes[exp] == b'+') {
                exp += 1;
            }
            if exp < bytes.len() && bytes[exp].is_ascii_digit() {
                while exp < bytes.len() && bytes[exp].is_ascii_digit() {
                    exp += 1;
                }
                at = exp;
            }
        }
        self.at = at;
        std::str::from_utf8(&bytes[start..at]).ok()?.parse().ok()
    }

    /// An arc's flag: one `0` or `1`, which may touch the next number (`a1 1 0 01 2 2`).
    fn flag(&mut self) -> Option<bool> {
        self.skip();
        let flag = match self.bytes.get(self.at)? {
            b'0' => false,
            b'1' => true,
            _ => return None,
        };
        self.at += 1;
        Some(flag)
    }

    fn command(&mut self) -> Option<u8> {
        self.skip();
        let byte = *self.bytes.get(self.at)?;
        if byte.is_ascii_alphabetic() && byte != b'e' && byte != b'E' {
            self.at += 1;
            return Some(byte);
        }
        None
    }

    fn done(&mut self) -> bool {
        self.skip();
        self.at >= self.bytes.len()
    }
}

/// A plain path: absolute `M x y`, `L x y`, `C x1 y1 x2 y2 x y`, `Q x1 y1 x y` and `Z`.
#[derive(Default)]
pub struct Path {
    out: String,
}

impl Path {
    fn push(&mut self, command: char, points: &[f32]) {
        if !self.out.is_empty() {
            self.out.push(' ');
        }
        self.out.push(command);
        for point in points {
            let _ = write!(self.out, " {}", trim(*point));
        }
    }
    pub fn move_to(&mut self, x: f32, y: f32) {
        self.push('M', &[x, y]);
    }
    pub fn line_to(&mut self, x: f32, y: f32) {
        self.push('L', &[x, y]);
    }
    pub fn cubic_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
        self.push('C', &[x1, y1, x2, y2, x, y]);
    }
    pub fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
        self.push('Q', &[x1, y1, x, y]);
    }
    pub fn close(&mut self) {
        self.push('Z', &[]);
    }
    pub fn text(self) -> String {
        self.out
    }
}

/// A number as short as it can be written and still be read back the same, near enough.
fn trim(value: f32) -> String {
    if !value.is_finite() {
        return "0".into();
    }
    let rounded = (value * 1000.0).round() / 1000.0;
    let text = format!("{rounded}");
    if text == "-0" { "0".into() } else { text }
}

/// A path's `d`, plain (`Path`). What follows a command it can't read is dropped, as SVG drops it.
pub fn path_data(d: &str) -> String {
    let mut path = Path::default();
    let mut scan = Scanner { bytes: d.as_bytes(), at: 0 };
    let (mut x, mut y) = (0.0f32, 0.0f32);
    let (mut start_x, mut start_y) = (0.0f32, 0.0f32);
    // The last curve's second control point, for `S` and `T`.
    let mut last_cubic: Option<(f32, f32)> = None;
    let mut last_quad: Option<(f32, f32)> = None;
    let mut command: Option<u8> = None;
    while !scan.done() {
        if let Some(next) = scan.command() {
            command = Some(next);
        } else if command.is_none() {
            break;
        }
        let Some(current) = command else { break };
        let relative = current.is_ascii_lowercase();
        let (ox, oy) = if relative { (x, y) } else { (0.0, 0.0) };
        let upper = current.to_ascii_uppercase();
        let mut read = |count: usize| -> Option<Vec<f32>> { (0..count).map(|_| scan.number()).collect() };
        match upper {
            b'M' => {
                let Some(p) = read(2) else { break };
                x = ox + p[0];
                y = oy + p[1];
                start_x = x;
                start_y = y;
                path.move_to(x, y);
                // Pairs after a move are lines.
                command = Some(if relative { b'l' } else { b'L' });
                last_cubic = None;
                last_quad = None;
                continue;
            }
            b'L' => {
                let Some(p) = read(2) else { break };
                x = ox + p[0];
                y = oy + p[1];
                path.line_to(x, y);
            }
            b'H' => {
                let Some(p) = read(1) else { break };
                x = if relative { x + p[0] } else { p[0] };
                path.line_to(x, y);
            }
            b'V' => {
                let Some(p) = read(1) else { break };
                y = if relative { y + p[0] } else { p[0] };
                path.line_to(x, y);
            }
            b'C' => {
                let Some(p) = read(6) else { break };
                let (x1, y1, x2, y2) = (ox + p[0], oy + p[1], ox + p[2], oy + p[3]);
                x = ox + p[4];
                y = oy + p[5];
                path.cubic_to(x1, y1, x2, y2, x, y);
                last_cubic = Some((x2, y2));
                last_quad = None;
                continue;
            }
            b'S' => {
                let Some(p) = read(4) else { break };
                let (x1, y1) = last_cubic.map(|(cx, cy)| (2.0 * x - cx, 2.0 * y - cy)).unwrap_or((x, y));
                let (x2, y2) = (ox + p[0], oy + p[1]);
                x = ox + p[2];
                y = oy + p[3];
                path.cubic_to(x1, y1, x2, y2, x, y);
                last_cubic = Some((x2, y2));
                last_quad = None;
                continue;
            }
            b'Q' => {
                let Some(p) = read(4) else { break };
                let (x1, y1) = (ox + p[0], oy + p[1]);
                x = ox + p[2];
                y = oy + p[3];
                path.quad_to(x1, y1, x, y);
                last_quad = Some((x1, y1));
                last_cubic = None;
                continue;
            }
            b'T' => {
                let Some(p) = read(2) else { break };
                let (x1, y1) = last_quad.map(|(cx, cy)| (2.0 * x - cx, 2.0 * y - cy)).unwrap_or((x, y));
                x = ox + p[0];
                y = oy + p[1];
                path.quad_to(x1, y1, x, y);
                last_quad = Some((x1, y1));
                last_cubic = None;
                continue;
            }
            b'A' => {
                let (Some(rx), Some(ry), Some(rotation)) = (scan.number(), scan.number(), scan.number()) else { break };
                let (Some(large), Some(sweep)) = (scan.flag(), scan.flag()) else { break };
                let (Some(ex), Some(ey)) = (scan.number(), scan.number()) else { break };
                let (to_x, to_y) = (ox + ex, oy + ey);
                arc(&mut path, (x, y), rx, ry, rotation, large, sweep, (to_x, to_y));
                x = to_x;
                y = to_y;
            }
            b'Z' => {
                path.close();
                x = start_x;
                y = start_y;
                // A `Z` takes no numbers: the next command must be named.
                command = None;
            }
            _ => break,
        }
        last_cubic = None;
        last_quad = None;
    }
    path.text()
}

/// An elliptical arc from `from` to `to` (SVG's `A`), as cubic curves of at most a quarter turn
/// each (SVG 1.1's implementation notes, F.6.5 and F.6.6).
#[allow(clippy::too_many_arguments)]
fn arc(path: &mut Path, from: (f32, f32), rx: f32, ry: f32, rotation: f32, large: bool, sweep: bool, to: (f32, f32)) {
    let (x1, y1) = (from.0 as f64, from.1 as f64);
    let (x2, y2) = (to.0 as f64, to.1 as f64);
    if (x1 - x2).abs() < 1e-9 && (y1 - y2).abs() < 1e-9 {
        return;
    }
    let (mut rx, mut ry) = ((rx as f64).abs(), (ry as f64).abs());
    if rx < 1e-9 || ry < 1e-9 {
        path.line_to(to.0, to.1);
        return;
    }
    let phi = (rotation as f64).to_radians();
    let (sin_phi, cos_phi) = phi.sin_cos();
    let (dx, dy) = ((x1 - x2) / 2.0, (y1 - y2) / 2.0);
    let x1p = cos_phi * dx + sin_phi * dy;
    let y1p = -sin_phi * dx + cos_phi * dy;
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if lambda > 1.0 {
        let grow = lambda.sqrt();
        rx *= grow;
        ry *= grow;
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    let mut factor = (numerator / denominator).max(0.0).sqrt();
    if large == sweep {
        factor = -factor;
    }
    let cxp = factor * rx * y1p / ry;
    let cyp = -factor * ry * x1p / rx;
    let cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2.0;
    let cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2.0;
    let angle = |ux: f64, uy: f64, vx: f64, vy: f64| {
        let dot = ux * vx + uy * vy;
        let len = (ux * ux + uy * uy).sqrt() * (vx * vx + vy * vy).sqrt();
        let mut a = (dot / len).clamp(-1.0, 1.0).acos();
        if ux * vy - uy * vx < 0.0 {
            a = -a;
        }
        a
    };
    let theta1 = angle(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    let mut delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    let tau = std::f64::consts::TAU;
    if !sweep && delta > 0.0 {
        delta -= tau;
    } else if sweep && delta < 0.0 {
        delta += tau;
    }
    let segments = (delta.abs() / (tau / 4.0)).ceil().max(1.0) as usize;
    let step = delta / segments as f64;
    let k = 4.0 / 3.0 * (step / 4.0).tan();
    let point = |theta: f64| {
        let (sin, cos) = theta.sin_cos();
        (cx + rx * cos * cos_phi - ry * sin * sin_phi, cy + rx * cos * sin_phi + ry * sin * cos_phi)
    };
    let derivative = |theta: f64| {
        let (sin, cos) = theta.sin_cos();
        (-rx * sin * cos_phi - ry * cos * sin_phi, -rx * sin * sin_phi + ry * cos * cos_phi)
    };
    let mut theta = theta1;
    for at in 0..segments {
        let next = theta + step;
        let (px, py) = point(theta);
        let (dx1, dy1) = derivative(theta);
        let (qx, qy) = if at + 1 == segments { (x2, y2) } else { point(next) };
        let (dx2, dy2) = derivative(next);
        path.cubic_to((px + k * dx1) as f32, (py + k * dy1) as f32, (qx - k * dx2) as f32, (qy - k * dy2) as f32, qx as f32, qy as f32);
        theta = next;
    }
}

/// An ellipse as four cubic curves, from its rightmost point, clockwise on the screen (as SVG's
/// `circle` and `ellipse` start and go, which a dash pattern follows).
pub fn ellipse(cx: f32, cy: f32, rx: f32, ry: f32) -> String {
    let mut path = Path::default();
    if rx <= 0.0 || ry <= 0.0 {
        return String::new();
    }
    let k = 0.552_284_8;
    path.move_to(cx + rx, cy);
    path.cubic_to(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry);
    path.cubic_to(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy);
    path.cubic_to(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry);
    path.cubic_to(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy);
    path.close();
    path.text()
}

/// A rectangle, its corners rounded by `rx`/`ry` (SVG's rules: one given is both; each at most
/// half the side), from its top left, clockwise.
pub fn rect(x: f32, y: f32, width: f32, height: f32, rx: Option<f32>, ry: Option<f32>) -> String {
    if width <= 0.0 || height <= 0.0 {
        return String::new();
    }
    let (rx, ry) = match (rx, ry) {
        (Some(rx), Some(ry)) => (rx, ry),
        (Some(r), None) | (None, Some(r)) => (r, r),
        (None, None) => (0.0, 0.0),
    };
    let (rx, ry) = (rx.clamp(0.0, width / 2.0), ry.clamp(0.0, height / 2.0));
    let mut path = Path::default();
    if rx == 0.0 || ry == 0.0 {
        path.move_to(x, y);
        path.line_to(x + width, y);
        path.line_to(x + width, y + height);
        path.line_to(x, y + height);
        path.close();
        return path.text();
    }
    let k = 0.552_284_8;
    path.move_to(x + rx, y);
    path.line_to(x + width - rx, y);
    path.cubic_to(x + width - rx + k * rx, y, x + width, y + ry - k * ry, x + width, y + ry);
    path.line_to(x + width, y + height - ry);
    path.cubic_to(x + width, y + height - ry + k * ry, x + width - rx + k * rx, y + height, x + width - rx, y + height);
    path.line_to(x + rx, y + height);
    path.cubic_to(x + rx - k * rx, y + height, x, y + height - ry + k * ry, x, y + height - ry);
    path.line_to(x, y + ry);
    path.cubic_to(x, y + ry - k * ry, x + rx - k * rx, y, x + rx, y);
    path.close();
    path.text()
}

/// A `polyline`'s or `polygon`'s points, closed for a polygon.
pub fn poly(points: &str, closed: bool) -> String {
    let numbers = numbers(points);
    let mut path = Path::default();
    for (at, pair) in numbers.chunks_exact(2).enumerate() {
        if at == 0 {
            path.move_to(pair[0], pair[1]);
        } else {
            path.line_to(pair[0], pair[1]);
        }
    }
    if closed && numbers.len() >= 4 {
        path.close();
    }
    path.text()
}

pub fn line(x1: f32, y1: f32, x2: f32, y2: f32) -> String {
    let mut path = Path::default();
    path.move_to(x1, y1);
    path.line_to(x2, y2);
    path.text()
}

/// A paint: a colour (Android's `#AARRGGBB`) or none.
#[derive(Clone, Debug, PartialEq)]
pub enum Paint {
    None,
    Colour(String),
    /// `currentColor`: the CSS `color` where it is used.
    Current,
}

/// What a shape is drawn with, as SVG inherits it down the tree.
#[derive(Clone, Debug)]
pub struct Style {
    pub fill: Paint,
    pub stroke: Paint,
    pub stroke_width: f32,
    pub cap: String,
    pub join: String,
    pub dash: Vec<f32>,
    pub dash_offset: f32,
    pub fill_opacity: f32,
    pub stroke_opacity: f32,
    /// A group's `opacity`s, multiplied.
    pub opacity: f32,
    pub font_size: f32,
    pub font_weight: String,
    pub anchor: String,
    pub color: String,
    /// `font-variant-numeric: tabular-nums`: a text's digits all as wide.
    pub tabular: bool,
}

impl Style {
    /// SVG's initial values: filled black, no stroke.
    pub fn initial(color: String, font_size: f32) -> Style {
        Style {
            fill: Paint::Colour("#ff000000".into()),
            stroke: Paint::None,
            stroke_width: 1.0,
            cap: "butt".into(),
            join: "miter".into(),
            dash: Vec::new(),
            dash_offset: 0.0,
            fill_opacity: 1.0,
            stroke_opacity: 1.0,
            opacity: 1.0,
            font_size,
            font_weight: "400".into(),
            anchor: "start".into(),
            color,
            tabular: false,
        }
    }

    /// One property, given as an attribute or CSS. Whether it was one of SVG's paint properties.
    pub fn set(&mut self, name: &str, value: &str, colour: impl Fn(&str) -> Option<String>) -> bool {
        let value = value.trim();
        let number = || value.trim_end_matches("px").trim().parse::<f32>().ok();
        let paint = || match value {
            "none" | "transparent" => Some(Paint::None),
            "currentColor" | "currentcolor" => Some(Paint::Current),
            _ => colour(value).map(Paint::Colour),
        };
        match name {
            "fill" => {
                if let Some(paint) = paint() {
                    self.fill = paint;
                }
            }
            "stroke" => {
                if let Some(paint) = paint() {
                    self.stroke = paint;
                }
            }
            "stroke-width" => {
                if let Some(width) = number() {
                    self.stroke_width = width.max(0.0);
                }
            }
            "stroke-linecap" => self.cap = value.to_string(),
            "stroke-linejoin" => self.join = value.to_string(),
            "stroke-dasharray" => {
                let dash: Vec<f32> = if value == "none" { Vec::new() } else { numbers(value) };
                self.dash = if dash.iter().any(|step| *step < 0.0) || dash.iter().all(|step| *step == 0.0) {
                    Vec::new()
                } else if dash.len() % 2 == 1 {
                    // An odd list is repeated to make it even, as SVG does.
                    dash.iter().chain(dash.iter()).copied().collect()
                } else {
                    dash
                };
            }
            "stroke-dashoffset" => {
                if let Some(offset) = number() {
                    self.dash_offset = offset;
                }
            }
            "fill-opacity" => {
                if let Some(opacity) = opacity(value) {
                    self.fill_opacity = opacity;
                }
            }
            "stroke-opacity" => {
                if let Some(opacity) = opacity(value) {
                    self.stroke_opacity = opacity;
                }
            }
            "font-size" => {
                if let Some(size) = number() {
                    self.font_size = size;
                }
            }
            "font-weight" => {
                self.font_weight = match value {
                    "bold" | "bolder" => "700".into(),
                    "normal" | "lighter" => "400".into(),
                    other => other.to_string(),
                }
            }
            "text-anchor" => self.anchor = value.to_string(),
            "color" => {
                if let Some(color) = colour(value) {
                    self.color = color;
                }
            }
            _ => return false,
        }
        true
    }

    /// A paint as the applier draws it: a colour with its opacities multiplied into its alpha.
    fn resolve(&self, paint: &Paint, opacity: f32) -> Option<String> {
        let colour = match paint {
            Paint::None => return None,
            Paint::Colour(colour) => colour.clone(),
            Paint::Current => self.color.clone(),
        };
        let alpha = u8::from_str_radix(colour.get(1..3)?, 16).ok()? as f32 / 255.0;
        let alpha = (alpha * opacity * self.opacity).clamp(0.0, 1.0);
        if alpha <= 0.0 {
            return None;
        }
        Some(format!("#{:02x}{}", (alpha * 255.0).round() as u8, colour.get(3..)?))
    }
}

/// An `opacity`: a number, or a percentage.
pub fn opacity(value: &str) -> Option<f32> {
    let value = value.trim();
    let number = match value.strip_suffix('%') {
        Some(percent) => percent.trim().parse::<f32>().ok()? / 100.0,
        None => value.parse::<f32>().ok()?,
    };
    Some(number.clamp(0.0, 1.0))
}

/// What one `<svg>` draws: its user space (`viewBox`), and its shapes and texts in order.
#[derive(Default)]
pub struct Drawing {
    pub view_box: Option<[f32; 4]>,
    items: Vec<String>,
}

impl Drawing {
    /// A shape: its plain path, through `matrix`, filled and stroked as `style` says.
    pub fn shape(&mut self, d: &str, matrix: Matrix, style: &Style, path_length: Option<f32>) {
        if d.is_empty() {
            return;
        }
        let fill = style.resolve(&style.fill, style.fill_opacity);
        let stroke = if style.stroke_width > 0.0 { style.resolve(&style.stroke, style.stroke_opacity) } else { None };
        if fill.is_none() && stroke.is_none() {
            return;
        }
        let mut item = format!("{{\"d\":{}", json(d));
        if let Some(fill) = fill {
            let _ = write!(item, ",\"fill\":{}", json(&fill));
        }
        if let Some(stroke) = stroke {
            let _ = write!(item, ",\"stroke\":{},\"width\":{}", json(&stroke), trim(style.stroke_width));
            if style.cap != "butt" {
                let _ = write!(item, ",\"cap\":{}", json(&style.cap));
            }
            if style.join != "miter" {
                let _ = write!(item, ",\"join\":{}", json(&style.join));
            }
            if !style.dash.is_empty() {
                let dash: Vec<String> = style.dash.iter().map(|step| trim(*step)).collect();
                let _ = write!(item, ",\"dash\":[{}],\"offset\":{}", dash.join(","), trim(style.dash_offset));
                if let Some(length) = path_length.filter(|length| *length > 0.0) {
                    let _ = write!(item, ",\"length\":{}", trim(length));
                }
            }
        }
        matrix_field(&mut item, matrix);
        item.push('}');
        self.items.push(item);
    }

    /// A `<text>`'s text at `x`, `y` (its baseline), anchored as `style` says.
    pub fn text(&mut self, text: &str, x: f32, y: f32, matrix: Matrix, style: &Style) {
        let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
        if text.is_empty() {
            return;
        }
        let Some(fill) = style.resolve(&style.fill, style.fill_opacity) else { return };
        let mut item = format!("{{\"text\":{},\"x\":{},\"y\":{},\"size\":{},\"fill\":{}", json(&text), trim(x), trim(y), trim(style.font_size), json(&fill));
        if style.anchor != "start" {
            let _ = write!(item, ",\"anchor\":{}", json(&style.anchor));
        }
        if style.font_weight != "400" {
            let _ = write!(item, ",\"weight\":{}", json(&style.font_weight));
        }
        if style.tabular {
            item.push_str(",\"tabular\":true");
        }
        matrix_field(&mut item, matrix);
        item.push('}');
        self.items.push(item);
    }

    /// The drawing as the applier reads it: `{"box":[x,y,w,h],"items":[…]}`.
    pub fn json(&self) -> String {
        let mut out = String::from("{");
        if let Some([x, y, w, h]) = self.view_box {
            let _ = write!(out, "\"box\":[{},{},{},{}],", trim(x), trim(y), trim(w), trim(h));
        }
        let _ = write!(out, "\"items\":[{}]}}", self.items.join(","));
        out
    }
}

fn matrix_field(item: &mut String, matrix: Matrix) {
    if matrix != Matrix::IDENTITY {
        let values: Vec<String> = matrix.0.iter().map(|value| trim(*value)).collect();
        let _ = write!(item, ",\"m\":[{}]", values.join(","));
    }
}

fn json(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for char in text.chars() {
        match char {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            char if (char as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", char as u32);
            }
            char => out.push(char),
        }
    }
    out.push('"');
    out
}

/// A `viewBox`'s four numbers, if it has a positive size.
pub fn view_box(text: &str) -> Option<[f32; 4]> {
    match numbers(text).as_slice() {
        [x, y, w, h] if *w > 0.0 && *h > 0.0 => Some([*x, *y, *w, *h]),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_are_made_plain() {
        assert_eq!(path_data("M10 10 h 5 v5 H0 Z"), "M 10 10 L 15 10 L 15 15 L 0 15 Z");
        assert_eq!(path_data("m1 1 2 2 3 3"), "M 1 1 L 3 3 L 6 6");
        assert_eq!(path_data("M0,0C1,1 2,2 3,3S5,5 6,6"), "M 0 0 C 1 1 2 2 3 3 C 4 4 5 5 6 6");
        assert_eq!(path_data("M0 0Q1 1 2 0T4 0"), "M 0 0 Q 1 1 2 0 Q 3 -1 4 0");
        assert_eq!(path_data("M-1.5.5e1 L2-3"), "M -1.5 5 L 2 -3");
        assert_eq!(path_data("M0 0 L 1"), "M 0 0");
    }

    #[test]
    fn arcs_are_cubic_curves() {
        // A half circle of radius 10, flags touching the numbers after them.
        let half = path_data("M0 10 a10 10 0 01 20 0");
        assert!(half.starts_with("M 0 10 C "), "{half}");
        assert_eq!(half.matches('C').count(), 2, "{half}");
        assert!(half.ends_with(" 20 10"), "{half}");
        // Its middle is at the top (sweep 1 is clockwise on the screen: up, then down).
        assert!(half.contains(" 10 0 C "), "{half}");
    }

    #[test]
    fn circles_start_at_three_o_clock_clockwise() {
        let circle = ellipse(50.0, 50.0, 40.0, 40.0);
        assert!(circle.starts_with("M 90 50 C 90 72.091 72.091 90 50 90"), "{circle}");
        assert!(circle.ends_with("Z"));
    }

    #[test]
    fn transforms_multiply() {
        assert_eq!(transform("translate(10 20)").0, [1.0, 0.0, 0.0, 1.0, 10.0, 20.0]);
        let rotated = transform("rotate(-90 50 50)").0;
        // (50, 10) turned a quarter back about the centre is (10, 50).
        let (x, y) = (rotated[0] * 50.0 + rotated[2] * 10.0 + rotated[4], rotated[1] * 50.0 + rotated[3] * 10.0 + rotated[5]);
        assert!((x - 10.0).abs() < 1e-3 && (y - 50.0).abs() < 1e-3, "{x} {y}");
        assert_eq!(transform("scale(2) translate(1,1)").0, [2.0, 0.0, 0.0, 2.0, 2.0, 2.0]);
    }

    #[test]
    fn paint_inherits_and_resolves() {
        let mut style = Style::initial("#ff112233".into(), 16.0);
        let colour = |value: &str| (value == "red").then(|| "#ffff0000".to_string());
        style.set("stroke", "currentColor", colour);
        style.set("fill", "none", colour);
        style.set("stroke-dasharray", "5", colour);
        style.set("stroke-opacity", "50%", colour);
        let mut drawing = Drawing::default();
        drawing.shape("M 0 0 L 1 1", Matrix::IDENTITY, &style, None);
        assert_eq!(drawing.json(), "{\"items\":[{\"d\":\"M 0 0 L 1 1\",\"stroke\":\"#80112233\",\"width\":1,\"dash\":[5,5],\"offset\":0}]}");
    }

    #[test]
    fn rects_round_their_corners() {
        assert_eq!(rect(0.0, 0.0, 10.0, 5.0, None, None), "M 0 0 L 10 0 L 10 5 L 0 5 Z");
        assert!(rect(0.0, 0.0, 10.0, 4.0, Some(5.0), None).starts_with("M 5 0 L 5 0 C"));
    }
}
