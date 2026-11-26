//! The JSON the engine reads and writes: Roc's markup (`Html.serialize!`: nodes, their attributes,
//! a list's entries, a template's parts), and a few small answers. It reads it into a `Value` as
//! serde_json would, with less: an object is its entries in order (a node has a handful, found by
//! a look along them), a key or a short value markup always has (`"t"`, `"tag"`, `"e"`, `"class"`)
//! is borrowed from a table instead of allocated, a string with no escapes is copied in one go, and
//! a number is an integer (Roc's ids), a fraction or exponent read roughly (markup has none). No
//! float parsing, maps or error messages: in a browser this is code the page downloads.

use std::borrow::Cow;

/// Text read from JSON: one markup always has (borrowed), or the text itself.
pub type Text = Cow<'static, str>;

#[derive(Clone, Debug, Default, PartialEq)]
pub enum Value {
    #[default]
    Null,
    Bool(bool),
    Number(Number),
    String(Text),
    Array(Vec<Value>),
    Object(Vec<(Text, Value)>),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Number {
    Whole(u64),
    Negative(i64),
    Fraction(f64),
}

impl Value {
    /// An object's entry named `key`.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(entries) => entries.iter().find(|(name, _)| name == key).map(|(_, value)| value),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Value::Number(Number::Whole(number)) => Some(*number),
            Value::Number(Number::Fraction(number)) if *number >= 0.0 && number.fract() == 0.0 => Some(*number as u64),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(flag) => Some(*flag),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&Vec<Value>> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// An array's items, taken.
    pub fn into_array(self) -> Option<Vec<Value>> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    /// An array of strings, as strings (`Router.revalidate!`'s keys).
    pub fn into_strings(self) -> Option<Vec<String>> {
        self.into_array()?
            .into_iter()
            .map(|item| match item {
                Value::String(text) => Some(text.into_owned()),
                _ => None,
            })
            .collect()
    }

    /// A text node's markup (`{"t":"s","v":…}`).
    pub fn text_node(text: Text) -> Value {
        Value::Object(vec![(Cow::Borrowed("t"), Value::String(Cow::Borrowed("s"))), (Cow::Borrowed("v"), Value::String(text))])
    }
}

/// `text` as JSON, its whole input one value (whitespace around it aside); `None` if it isn't.
pub fn parse(text: &str) -> Option<Value> {
    let mut reader = Reader { text, bytes: text.as_bytes(), at: 0 };
    let value = reader.value()?;
    reader.space();
    (reader.at == reader.bytes.len()).then_some(value)
}

/// `text` as a JSON string, quoted and escaped, onto `out`.
pub fn quote(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                const HEX: &[u8; 16] = b"0123456789abcdef";
                out.push_str("\\u00");
                out.push(HEX[(c as usize) >> 4] as char);
                out.push(HEX[(c as usize) & 15] as char);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

struct Reader<'a> {
    text: &'a str,
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn space(&mut self) {
        while matches!(self.bytes.get(self.at), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.at += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn word(&mut self, word: &str, value: Value) -> Option<Value> {
        if self.bytes[self.at..].starts_with(word.as_bytes()) {
            self.at += word.len();
            Some(value)
        } else {
            None
        }
    }

    fn value(&mut self) -> Option<Value> {
        self.space();
        match self.peek()? {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => Some(Value::String(self.string()?)),
            b't' => self.word("true", Value::Bool(true)),
            b'f' => self.word("false", Value::Bool(false)),
            b'n' => self.word("null", Value::Null),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn array(&mut self) -> Option<Value> {
        self.at += 1;
        let mut items = Vec::new();
        self.space();
        if self.peek()? == b']' {
            self.at += 1;
            return Some(Value::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.space();
            match self.peek()? {
                b',' => self.at += 1,
                b']' => {
                    self.at += 1;
                    return Some(Value::Array(items));
                }
                _ => return None,
            }
        }
    }

    fn object(&mut self) -> Option<Value> {
        self.at += 1;
        let mut entries = Vec::new();
        self.space();
        if self.peek()? == b'}' {
            self.at += 1;
            return Some(Value::Object(entries));
        }
        loop {
            self.space();
            if self.peek()? != b'"' {
                return None;
            }
            let key = self.string()?;
            self.space();
            if self.peek()? != b':' {
                return None;
            }
            self.at += 1;
            let value = self.value()?;
            // A key twice: the last one, as serde_json's map keeps.
            match entries.iter_mut().find(|(name, _): &&mut (Text, Value)| *name == key) {
                Some(entry) => entry.1 = value,
                None => entries.push((key, value)),
            }
            self.space();
            match self.peek()? {
                b',' => self.at += 1,
                b'}' => {
                    self.at += 1;
                    return Some(Value::Object(entries));
                }
                _ => return None,
            }
        }
    }

    /// A string, from its opening quote: its text, borrowed when markup always has it.
    fn string(&mut self) -> Option<Text> {
        self.at += 1;
        let start = self.at;
        loop {
            match self.peek()? {
                b'"' => {
                    let text = &self.text[start..self.at];
                    self.at += 1;
                    return Some(match known(text) {
                        Some(known) => Cow::Borrowed(known),
                        None => Cow::Owned(text.to_string()),
                    });
                }
                b'\\' => break,
                _ => self.at += 1,
            }
        }
        // Escapes: the text before them, then each in turn, a run of plain text at a time (cut only
        // at a quote or a backslash, so at a character's edge).
        let mut out = String::from(&self.text[start..self.at]);
        loop {
            match self.peek()? {
                b'"' => {
                    self.at += 1;
                    return Some(Cow::Owned(out));
                }
                b'\\' => {
                    self.at += 1;
                    let escaped = self.peek()?;
                    self.at += 1;
                    match escaped {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => out.push(self.unicode()?),
                        _ => return None,
                    }
                }
                _ => {
                    let from = self.at;
                    while !matches!(self.peek()?, b'"' | b'\\') {
                        self.at += 1;
                    }
                    out.push_str(&self.text[from..self.at]);
                }
            }
        }
    }

    /// A `\u` escape's character, after `\u`: a pair of them for one outside the first plane.
    fn unicode(&mut self) -> Option<char> {
        let first = self.hex()?;
        if (0xD800..0xDC00).contains(&first) {
            if !self.bytes[self.at..].starts_with(b"\\u") {
                return Some('\u{FFFD}');
            }
            self.at += 2;
            let second = self.hex()?;
            if !(0xDC00..0xE000).contains(&second) {
                return Some('\u{FFFD}');
            }
            return char::from_u32(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00));
        }
        Some(char::from_u32(first).unwrap_or('\u{FFFD}'))
    }

    fn hex(&mut self) -> Option<u32> {
        let digits = self.bytes.get(self.at..self.at + 4)?;
        self.at += 4;
        digits.iter().try_fold(0u32, |value, &digit| Some(value * 16 + (digit as char).to_digit(16)?))
    }

    /// A number: a whole one exactly (Roc's ids), one with a fraction or an exponent roughly.
    fn number(&mut self) -> Option<Value> {
        let negative = self.peek() == Some(b'-');
        if negative {
            self.at += 1;
        }
        let mut whole: u64 = 0;
        let mut overflow = false;
        let mut digits = 0;
        while let Some(digit @ b'0'..=b'9') = self.peek() {
            match whole.checked_mul(10).and_then(|value| value.checked_add(u64::from(digit - b'0'))) {
                Some(value) => whole = value,
                None => overflow = true,
            }
            self.at += 1;
            digits += 1;
        }
        if digits == 0 {
            return None;
        }
        if !overflow && !matches!(self.peek(), Some(b'.' | b'e' | b'E')) {
            return Some(Value::Number(match negative {
                false => Number::Whole(whole),
                true => Number::Negative(-(whole.min(i64::MAX as u64) as i64)),
            }));
        }
        // Read again as a fraction: its digits, then its exponent.
        let mut at = self.at - digits;
        let mut mantissa = 0f64;
        let mut scale = 0i32;
        while let Some(digit @ b'0'..=b'9') = self.bytes.get(at).copied() {
            mantissa = mantissa * 10.0 + f64::from(digit - b'0');
            at += 1;
        }
        self.at = at;
        if self.peek() == Some(b'.') {
            self.at += 1;
            while let Some(digit @ b'0'..=b'9') = self.peek() {
                mantissa = mantissa * 10.0 + f64::from(digit - b'0');
                scale -= 1;
                self.at += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            let sign = match self.peek() {
                Some(b'-') => {
                    self.at += 1;
                    -1
                }
                Some(b'+') => {
                    self.at += 1;
                    1
                }
                _ => 1,
            };
            let mut exponent = 0i32;
            while let Some(digit @ b'0'..=b'9') = self.peek() {
                exponent = exponent.saturating_mul(10).saturating_add(i32::from(digit - b'0'));
                self.at += 1;
            }
            scale = scale.saturating_add(sign * exponent);
        }
        let value = mantissa * 10f64.powi(scale);
        Some(Value::Number(Number::Fraction(if negative { -value } else { value })))
    }
}

/// A short string markup always has: its keys, node kinds, attribute kinds, and common tags and
/// attribute names, kept once.
fn known(text: &str) -> Option<&'static str> {
    if text.len() > 12 {
        return None;
    }
    Some(match text {
        "" => "",
        // Keys.
        "t" => "t",
        "v" => "v",
        "r" => "r",
        "a" => "a",
        "c" => "c",
        "k" => "k",
        "s" => "s",
        "p" => "p",
        "n" => "n",
        "id" => "id",
        "tag" => "tag",
        "fallback" => "fallback",
        "with" => "with",
        // Node kinds.
        "e" => "e",
        "x" => "x",
        "h" => "h",
        "l" => "l",
        "f" => "f",
        "hx" => "hx",
        "raw" => "raw",
        "tpl" => "tpl",
        "ctx" => "ctx",
        "for" => "for",
        "show" => "show",
        "loading" => "loading",
        "errored" => "errored",
        "?" => "?",
        // Attribute kinds.
        "vo" => "vo",
        "o" => "o",
        "oo" => "oo",
        "fo" => "fo",
        "ci" => "ci",
        "co" => "co",
        "sv" => "sv",
        "so" => "so",
        "on" => "on",
        "onp" => "onp",
        "onk" => "onk",
        // Tags.
        "div" => "div",
        "span" => "span",
        "td" => "td",
        "tr" => "tr",
        "th" => "th",
        "li" => "li",
        "ul" => "ul",
        "ol" => "ol",
        "button" => "button",
        "input" => "input",
        "label" => "label",
        "form" => "form",
        "section" => "section",
        "main" => "main",
        "header" => "header",
        "footer" => "footer",
        "nav" => "nav",
        "img" => "img",
        "h1" => "h1",
        "h2" => "h2",
        "h3" => "h3",
        "table" => "table",
        "tbody" => "tbody",
        "thead" => "thead",
        "svg" => "svg",
        "path" => "path",
        "g" => "g",
        // Attribute names.
        "class" => "class",
        "href" => "href",
        "type" => "type",
        "name" => "name",
        "value" => "value",
        "style" => "style",
        "role" => "role",
        "title" => "title",
        "disabled" => "disabled",
        "checked" => "checked",
        "placeholder" => "placeholder",
        "aria-hidden" => "aria-hidden",
        "aria-label" => "aria-label",
        "click" => "click",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markup_is_read_as_serde_json_reads_it() {
        let node = parse(r#"{"t":"e","tag":"td","a":[["v","class","col-md-1"],["on","click",12]],"c":[{"t":"x","r":7}]}"#).unwrap();
        assert_eq!(node.get("t").and_then(Value::as_str), Some("e"));
        assert_eq!(node.get("tag").and_then(Value::as_str), Some("td"));
        let attrs = node.get("a").and_then(Value::as_array).unwrap();
        assert_eq!(attrs[1].as_array().unwrap()[2].as_u64(), Some(12));
        assert_eq!(node.get("c").and_then(Value::as_array).unwrap()[0].get("r").and_then(Value::as_u64), Some(7));
        assert!(matches!(node.get("t"), Some(Value::String(Cow::Borrowed(_)))), "a kind is borrowed");
        assert!(node.get("nothing").is_none());
    }

    #[test]
    fn strings_numbers_and_the_rest() {
        assert_eq!(parse(r#""a \"quote\", a \\ and a line\nand é and 😀""#).and_then(|value| value.as_str().map(str::to_string)), Some("a \"quote\", a \\ and a line\nand é and 😀".to_string()));
        assert_eq!(parse(" [ 1 , -2, 3.5, 1e3, true, false, null, {} ] "), Some(Value::Array(vec![Value::Number(Number::Whole(1)), Value::Number(Number::Negative(-2)), Value::Number(Number::Fraction(3.5)), Value::Number(Number::Fraction(1000.0)), Value::Bool(true), Value::Bool(false), Value::Null, Value::Object(Vec::new())])));
        assert_eq!(parse("18446744073709551615").and_then(|value| value.as_u64()), Some(u64::MAX));
        assert_eq!(parse(r#"["a","b"]"#).and_then(Value::into_strings), Some(vec!["a".to_string(), "b".to_string()]));
        assert_eq!(parse(r#"{"a":1,"a":2}"#).and_then(|value| value.get("a").and_then(Value::as_u64)), Some(2));
        for bad in ["", "[1,", "{\"a\" 1}", "tru", "[1] 2", "\"open", "{1:2}", "-"] {
            assert_eq!(parse(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn quoting_escapes_what_json_must() {
        let mut out = String::new();
        quote("a \"b\" \\ c\n\t\u{1}é", &mut out);
        assert_eq!(out, r#""a \"b\" \\ c\n\t\u0001é""#);
        assert_eq!(parse(&out).and_then(|value| value.as_str().map(str::to_string)), Some("a \"b\" \\ c\n\t\u{1}é".to_string()));
    }
}
