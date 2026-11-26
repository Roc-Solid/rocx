//! The settings in a file, put in the process's environment as the server starts (D-088, D-098), so
//! `Env.var!` reads them, and with it every plugin that reads its keys at start (`ANTHROPIC_API_KEY`,
//! `STRIPE_SECRET_KEY`, `SMTP_URL`), as do the server's own (`DATABASE_URL`, `PORT`). Only the file
//! `--env-file` names is read, and it must be there: a `.env` beside the server is read when asked
//! for (`rocx dev` asks for the one where it runs), never by itself, so a server started by a test,
//! by CI or in production has only the environment it was given. A variable the environment has
//! already keeps its value: the file is the default, the environment says otherwise.
//!
//! The file's lines, as dotenv writes them: `NAME=value`, `export NAME=value`, blank lines and
//! `# comments`. A value is as written, its spaces around trimmed, a ` #` and what follows it a
//! comment; or in single quotes, as it is; or in double quotes, where `\n`, `\r`, `\t`, `\"` and `\\` are
//! escapes; quoted values may run over several lines. `${NAME}` is kept as it is (no expansion).
//!
//! Read in `main`, before the log's thread or any other starts: changing the environment is only
//! sound while one thread runs. What it did is logged once the server listens, in the app's log
//! format (`noted`, `read`): the names it set and kept, never their values.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// What was read, kept until the log's format is the app's (`read`).
static READ: Mutex<Option<(String, String, String)>> = Mutex::new(None);

/// Keeps what reading the file did (its path, the names set, the names kept), for `read`.
pub fn noted(file: &Path, set: &[String], kept: &[String]) {
    if set.is_empty() && kept.is_empty() {
        return;
    }
    if let Ok(mut read) = READ.lock() {
        *read = Some((shown(file), set.join(", "), kept.join(", ")));
    }
}

/// What reading the file did (its path, the names set, the names kept), once: for the log, as the
/// server listens, when the log's format is the app's (`http::serve`).
pub fn read() -> Option<(String, String, String)> {
    READ.lock().ok().and_then(|mut read| read.take())
}

/// What reading the file came to, for the log.
pub enum Loaded {
    /// No file named.
    Nothing,
    /// The file, the names it set, and the names the environment already had.
    Read { file: PathBuf, set: Vec<String>, kept: Vec<String> },
    /// A line that isn't a setting (its number and why); the lines before it were read.
    Failed { file: PathBuf, why: String },
}

/// The file `--env-file <path>` names (`--env-file=<path>` too), if the arguments have one. A flag
/// and not a variable: a variable would reach every server started under it, a test's too (D-098).
pub fn named(args: &[String]) -> Option<String> {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--env-file" {
            return iter.next().cloned();
        }
        if let Some(path) = arg.strip_prefix("--env-file=") {
            return Some(path.to_string());
        }
    }
    None
}

/// Reads the file named into the environment; nothing when none is. Call it only while the process
/// has one thread.
pub fn load(named: Option<&str>) -> Loaded {
    let Some(path) = named else {
        return Loaded::Nothing;
    };
    let file = PathBuf::from(path);
    let text = match std::fs::read_to_string(&file) {
        Ok(text) => text,
        Err(error) => return Loaded::Failed { file, why: format!("can't be read: {error}") },
    };
    let (pairs, failure) = parse(&text);
    let mut set = Vec::new();
    let mut kept = Vec::new();
    for (name, value) in pairs {
        if std::env::var_os(&name).is_some() {
            kept.push(name);
        } else {
            // Sound: `main` calls this before any other thread starts.
            unsafe { std::env::set_var(&name, value) };
            set.push(name);
        }
    }
    match failure {
        Some(why) => Loaded::Failed { file, why },
        None => Loaded::Read { file, set, kept },
    }
}

/// The settings in a file's text, in order (a name given twice: its last value), and why the first
/// line that isn't one isn't (the lines after it aren't read).
pub fn parse(text: &str) -> (Vec<(String, String)>, Option<String>) {
    let mut pairs: Vec<(String, String)> = Vec::new();
    let chars: Vec<char> = text.chars().collect();
    let mut at = 0;
    let mut line = 1;
    while at < chars.len() {
        // A line's start: blank lines and comments are skipped.
        let start_line = line;
        let end = line_end(&chars, at);
        let trimmed: String = chars[at..end].iter().collect::<String>().trim().to_string();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            at = end + 1;
            line += 1;
            continue;
        }
        let body = trimmed.strip_prefix("export ").map(str::trim_start).unwrap_or(&trimmed);
        let Some(equals) = body.find('=') else {
            return (pairs, Some(format!("line {start_line} isn't NAME=value")));
        };
        let name = body[..equals].trim().to_string();
        if !valid_name(&name) {
            return (pairs, Some(format!("line {start_line}: {name:?} isn't a variable's name (letters, digits and _, not first a digit)")));
        }
        // The value starts after the `=` in the original text, so a quoted one can run on.
        let skipped = chars[at..end].iter().position(|c| *c == '=').map(|index| at + index + 1).unwrap_or(end);
        let mut from = skipped;
        while from < end && (chars[from] == ' ' || chars[from] == '\t') {
            from += 1;
        }
        let (value, next) = match chars.get(from) {
            Some('"') | Some('\'') => {
                let quote = chars[from];
                match quoted(&chars, from + 1, quote) {
                    Some((value, close)) => {
                        line += chars[from..close].iter().filter(|c| **c == '\n').count();
                        (value, line_end(&chars, close) + 1)
                    }
                    None => return (pairs, Some(format!("line {start_line}: a {quote} that never closes"))),
                }
            }
            _ => {
                let raw: String = chars[from..end].iter().collect();
                (unquoted(&raw), end + 1)
            }
        };
        pairs.retain(|(existing, _)| *existing != name);
        pairs.push((name, value));
        at = next;
        line += 1;
    }
    (pairs, None)
}

/// Where the line starting at `at` ends (its `\n`, or the text's end).
fn line_end(chars: &[char], at: usize) -> usize {
    chars[at.min(chars.len())..].iter().position(|c| *c == '\n').map(|index| at + index).unwrap_or(chars.len())
}

/// A name as a shell takes it: letters, digits and `_`, not first a digit (dots too, as some tools
/// write them).
fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() || first == '_' => chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.'),
        _ => false,
    }
}

/// An unquoted value: up to a ` #` comment, its spaces trimmed (and a `\r` a Windows line leaves).
fn unquoted(raw: &str) -> String {
    let cut = raw.char_indices().find(|(index, c)| *c == '#' && *index > 0 && raw[..*index].ends_with([' ', '\t'])).map(|(index, _)| index).unwrap_or(raw.len());
    raw[..cut].trim().to_string()
}

/// A quoted value from `from` (after its opening quote) to its closing one: the value, and where
/// the closing quote is. Double quotes take `\n`, `\t`, `\r`, `\"` and `\\`; single quotes nothing.
fn quoted(chars: &[char], from: usize, quote: char) -> Option<(String, usize)> {
    let mut value = String::new();
    let mut at = from;
    while at < chars.len() {
        let c = chars[at];
        if c == quote {
            return Some((value, at));
        }
        if quote == '"' && c == '\\' && at + 1 < chars.len() {
            at += 1;
            match chars[at] {
                'n' => value.push('\n'),
                't' => value.push('\t'),
                'r' => value.push('\r'),
                other => value.push(other),
            }
        } else if c != '\r' {
            value.push(c);
        }
        at += 1;
    }
    None
}

/// The file's path as the log says it.
pub fn shown(file: &Path) -> String {
    file.display().to_string()
}

#[cfg(test)]
mod tests {
    use super::parse;

    fn pairs(text: &str) -> Vec<(String, String)> {
        let (pairs, failure) = parse(text);
        assert_eq!(failure, None);
        pairs
    }

    fn pair(name: &str, value: &str) -> (String, String) {
        (name.to_string(), value.to_string())
    }

    #[test]
    fn plain_lines_comments_and_export() {
        assert_eq!(
            pairs("# keys\nANTHROPIC_API_KEY=sk-ant-1\n\nexport PORT = 8090 \nEMPTY=\n"),
            vec![pair("ANTHROPIC_API_KEY", "sk-ant-1"), pair("PORT", "8090"), pair("EMPTY", "")]
        );
    }

    #[test]
    fn comments_after_values_and_hashes_inside() {
        assert_eq!(pairs("A=one # a comment\nB=no#comment\nC=\"quoted # kept\"\n"), vec![pair("A", "one"), pair("B", "no#comment"), pair("C", "quoted # kept")]);
    }

    #[test]
    fn quotes_escapes_and_lines() {
        assert_eq!(
            pairs("D=\"a\\nb \\\"c\\\"\"\nS='raw \\n $X'\nM=\"line one\nline two\"\nAFTER=yes\n"),
            vec![pair("D", "a\nb \"c\""), pair("S", "raw \\n $X"), pair("M", "line one\nline two"), pair("AFTER", "yes")]
        );
    }

    #[test]
    fn windows_line_ends_and_a_name_given_twice() {
        assert_eq!(pairs("A=1\r\nB=\"two\"\r\nA=3\r\n"), vec![pair("B", "two"), pair("A", "3")]);
    }

    #[test]
    fn what_isnt_a_setting() {
        assert_eq!(parse("A=1\nnot a setting\nB=2\n"), (vec![pair("A", "1")], Some("line 2 isn't NAME=value".to_string())));
        assert_eq!(parse("1A=x\n").1, Some("line 1: \"1A\" isn't a variable's name (letters, digits and _, not first a digit)".to_string()));
        assert_eq!(parse("Q=\"open\n").1, Some("line 1: a \" that never closes".to_string()));
    }
}
