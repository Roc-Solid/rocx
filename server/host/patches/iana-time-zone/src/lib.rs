//! The system's IANA time zone (`Europe/Warsaw`), as crates.io's iana-time-zone gives it, read
//! without CoreFoundation: /etc/localtime's link (macOS's points into /var/db/timezone/zoneinfo/,
//! Linux's into /usr/share/zoneinfo/), or else /etc/timezone. The server's host links no
//! CoreFoundation (Roc links an app against the C library alone), and chrono, which is all that asks
//! this, calls it only when `TZ` and /etc/localtime itself fail.

use std::fs::{read_link, read_to_string};

/// Why the time zone wasn't found.
#[derive(Debug)]
pub enum GetTimezoneError {
    /// /etc/localtime's link isn't into a zoneinfo directory.
    FailedParsingString,
    /// Neither file could be read.
    IoError(std::io::Error),
    /// Kept for crates.io's API: never given here.
    OsError,
}

impl std::error::Error for GetTimezoneError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            GetTimezoneError::IoError(error) => Some(error),
            _ => None,
        }
    }
}

impl std::fmt::Display for GetTimezoneError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GetTimezoneError::FailedParsingString => f.write_str("GetTimezoneError::FailedParsingString"),
            GetTimezoneError::IoError(error) => error.fmt(f),
            GetTimezoneError::OsError => f.write_str("OsError"),
        }
    }
}

impl From<std::io::Error> for GetTimezoneError {
    fn from(error: std::io::Error) -> Self {
        GetTimezoneError::IoError(error)
    }
}

/// The system's IANA time zone.
pub fn get_timezone() -> Result<String, GetTimezoneError> {
    localtime().or_else(|_| timezone_file())
}

/// What /etc/localtime links to, after its zoneinfo directory.
fn localtime() -> Result<String, GetTimezoneError> {
    let target = read_link("/etc/localtime")?.into_os_string().into_string().map_err(|_| GetTimezoneError::FailedParsingString)?;
    match target.rsplit_once("zoneinfo/") {
        Some((_, zone)) if !zone.is_empty() => Ok(zone.to_string()),
        _ => Err(GetTimezoneError::FailedParsingString),
    }
}

/// /etc/timezone's first line (Debian's).
fn timezone_file() -> Result<String, GetTimezoneError> {
    let text = read_to_string("/etc/timezone")?;
    let zone = text.trim();
    if zone.is_empty() { Err(GetTimezoneError::FailedParsingString) } else { Ok(zone.to_string()) }
}
