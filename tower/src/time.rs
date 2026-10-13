//! Timestamps as Unix milliseconds, parsed from the formats `ci`, JJ, and the
//! job store write, and printed as short durations.

use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Days since 1970-01-01 for a proleptic Gregorian date.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = year - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn digits(text: &str, at: usize, len: usize) -> Option<i64> {
    let part = text.get(at..at + len)?;
    if !part.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    part.parse().ok()
}

/// Parses `YYYY-MM-DD[T ]HH:MM:SS[.fraction][Z|±HH:MM|±HHMM]` as Unix
/// milliseconds. Without an offset the time counts as UTC.
pub fn parse(text: &str) -> Option<i64> {
    let text = text.trim();
    let (year, month, day) = (
        digits(text, 0, 4)?,
        digits(text, 5, 2)?,
        digits(text, 8, 2)?,
    );
    if !matches!(text.get(10..11)?, "T" | " ") {
        return None;
    }
    let (hour, minute, second) = (
        digits(text, 11, 2)?,
        digits(text, 14, 2)?,
        digits(text, 17, 2)?,
    );
    let mut rest = &text[19..];
    let mut millis = 0;
    if let Some(fraction) = rest.strip_prefix('.') {
        let end = fraction
            .find(|c: char| !c.is_ascii_digit())
            .unwrap_or(fraction.len());
        let mut padded = fraction[..end].to_string();
        padded.truncate(3);
        while padded.len() < 3 {
            padded.push('0');
        }
        millis = padded.parse().unwrap_or(0);
        rest = &fraction[end..];
    }
    let offset_minutes = match rest {
        "" | "Z" | "z" => 0,
        _ => {
            let sign = match &rest[..1] {
                "+" => 1,
                "-" => -1,
                _ => return None,
            };
            let clock = rest[1..].replace(':', "");
            let hours = digits(&clock, 0, 2)?;
            let minutes = digits(&clock, 2, 2).unwrap_or(0);
            sign * (hours * 60 + minutes)
        }
    };
    let days = days_from_civil(year, month, day);
    let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset_minutes * 60;
    Some(seconds * 1_000 + millis)
}

/// A short span: `4s`, `2m13s`, `1h05m`, `3d04h`.
pub fn duration(ms: i64) -> String {
    let seconds = ms.max(0) / 1_000;
    match seconds {
        0..=59 => format!("{seconds}s"),
        60..=3_599 => format!("{}m{:02}s", seconds / 60, seconds % 60),
        3_600..=86_399 => format!("{}h{:02}m", seconds / 3_600, seconds % 3_600 / 60),
        _ => format!("{}d{:02}h", seconds / 86_400, seconds % 86_400 / 3_600),
    }
}

/// How long ago `then` was, coarsely: `now`, `3m`, `2h`, `5d`.
pub fn ago(then: i64, now: i64) -> String {
    let seconds = (now - then).max(0) / 1_000;
    match seconds {
        0..=44 => "now".into(),
        45..=3_599 => format!("{}m", (seconds + 30) / 60),
        3_600..=86_399 => format!("{}h", seconds / 3_600),
        86_400..=2_591_999 => format!("{}d", seconds / 86_400),
        _ => format!("{}mo", seconds / 2_592_000),
    }
}

/// `ago` for prose: `just now`, `3m ago`.
pub fn since(then: i64, now: i64) -> String {
    match ago(then, now).as_str() {
        "now" => "just now".into(),
        span => format!("{span} ago"),
    }
}

/// The local wall clock as `HH:MM:SS`.
pub fn clock(ms: i64) -> String {
    let seconds = (ms / 1_000) as libc::time_t;
    // SAFETY: localtime_r writes only into the zeroed struct it is given.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&seconds, &mut tm).is_null() {
            return String::new();
        }
        format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_formats_ci_writes() {
        // job meta.json: strftime %z
        assert_eq!(parse("2026-10-12T19:45:50-0500"), Some(1_791_852_350_000));
        // OSC 7501 records: RFC 3339 with nanoseconds
        assert_eq!(
            parse("2026-10-12T19:46:04.860517731-05:00"),
            Some(1_791_852_364_860)
        );
        assert_eq!(parse("2026-10-13T00:46:04Z"), Some(1_791_852_364_000));
        assert_eq!(parse("1970-01-01T00:00:00"), Some(0));
        assert_eq!(parse("not a time"), None);
    }

    #[test]
    fn formats_spans() {
        assert_eq!(duration(4_200), "4s");
        assert_eq!(duration(133_000), "2m13s");
        assert_eq!(duration(3_900_000), "1h05m");
        assert_eq!(duration(2 * 86_400_000 + 3_600_000), "2d01h");
        assert_eq!(ago(0, 10_000), "now");
        assert_eq!(ago(0, 600_000), "10m");
    }
}
